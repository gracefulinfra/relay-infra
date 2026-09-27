package s3conformance

import (
	"bytes"
	"context"
	"crypto/md5" //nolint:gosec // G501: S3 single-part ETags are MD5; used only to describe them.
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"golang.org/x/sync/errgroup"
)

// cases is the suite, in report order. The IDs follow the numbering in the P0-06 prompt; 12 is added
// from the shared conventions (origins must reject anonymous reads and listing). README.md explains
// each level.
var cases = []caseDef{
	{"01a", "Multipart: parts uploaded out of order, list parts, complete", Hard, multipartComplete},
	{"01b", "Multipart: abort", Hard, multipartAbort},
	{"01c", "Multipart: find and clean up incomplete uploads", Hard, multipartCleanup},
	{"02a", "Presigned PUT", Hard, presignedPut},
	{"02b", "Presigned GET", Hard, presignedGet},
	{"02c", "Presigned URL expiry is enforced", Hard, presignedExpiry},
	{"03a", "Range bytes=0-0", Hard, rangeCase("bytes=0-0", 0, 0)},
	{"03b", "Range bytes=100- (open-ended)", Hard, rangeCase("bytes=100-", 100, rangeObjectSize-1)},
	{"03c", "Range bytes=-500 (suffix)", Hard, rangeCase("bytes=-500", rangeObjectSize-500, rangeObjectSize-1)},
	{"03d", "Range with several ranges (behaviour recorded)", Soft, rangeMulti},
	{"03e", "Range past the end returns 416", Soft, rangeUnsatisfiable},
	{"04", "HEAD returns Content-Length, Content-Type, ETag, Last-Modified", Hard, headObject},
	{"05a", "Content-Type audio/mpeg", Hard, contentType("audio/mpeg")},
	{"05b", "Content-Type audio/mp4", Hard, contentType("audio/mp4")},
	{"05c", "Content-Type video/mp4", Hard, contentType("video/mp4")},
	{"05d", "Content-Type application/vnd.apple.mpegurl", Hard, contentType("application/vnd.apple.mpegurl")},
	{"05e", "Content-Type video/iso.segment", Hard, contentType("video/iso.segment")},
	{"05f", "Content-Type text/vtt", Hard, contentType("text/vtt")},
	{"05g", "Content-Type application/json+chapters", Hard, contentType("application/json+chapters")},
	{"05h", "Content-Type application/rss+xml", Hard, contentType("application/rss+xml")},
	{"06a", "Cache-Control round-trip", Hard, headerRoundTrip("Cache-Control", "public, max-age=31536000, immutable")},
	{"06b", "Content-Disposition round-trip", Hard, headerRoundTrip("Content-Disposition", `attachment; filename="episode-042.mp3"; filename*=UTF-8''%C3%A9pisode-042.mp3`)},
	{"07a", "If-None-Match returns 304", Hard, ifNoneMatch},
	{"07b", "If-Modified-Since returns 304", Hard, ifModifiedSince},
	{"08a", "ListObjectsV2 pagination over 1,000 objects", Hard, listPagination},
	{"08b", "ListObjectsV2 prefix and delimiter", Hard, listDelimiter},
	{"09a", "Lifecycle: expire a prefix", Soft, lifecycleCase(lifecycleExpire)},
	{"09b", "Lifecycle: abort incomplete multipart uploads", Soft, lifecycleCase(lifecycleAbortMultipart)},
	{"10a", "Server-side copy (CopyObject)", Hard, copyObject},
	{"10b", "Server-side copy of parts (UploadPartCopy)", Soft, uploadPartCopy},
	{"10c", "x-amz-checksum-sha256 is verified and returned", Soft, checksumSHA256},
	{"11", "Access-log export", Soft, accessLogs},
	{"12", "Anonymous requests are denied", Hard, anonymousDenied},
}

const (
	partSize        = 5 << 20 // the S3 minimum for every part but the last
	rangeObjectSize = 10_000
)

// --- 01 multipart ------------------------------------------------------------------------------------

func multipartComplete(c *C) {
	key := c.Key("master.mp3")
	parts := [][]byte{randomBytes(partSize), randomBytes(partSize), randomBytes(512 << 10)}
	whole := bytes.Join(parts, nil)

	created, err := c.s.s3.CreateMultipartUpload(c.ctx, &s3.CreateMultipartUploadInput{
		Bucket: &c.s.bucket, Key: &key, ContentType: aws.String("audio/mpeg"),
	})
	c.Must(err, "CreateMultipartUpload")
	etags := map[int32]string{}
	for _, n := range []int32{3, 1, 2} { // deliberately out of order
		out, err := c.s.s3.UploadPart(c.ctx, &s3.UploadPartInput{
			Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId, PartNumber: aws.Int32(n),
			Body: bytes.NewReader(parts[n-1]), ContentLength: aws.Int64(int64(len(parts[n-1]))),
		})
		c.Must(err, fmt.Sprintf("UploadPart %d", n))
		etags[n] = aws.ToString(out.ETag)
	}
	c.Notef("uploaded parts in the order 3, 1, 2")

	listed, err := c.s.s3.ListParts(c.ctx, &s3.ListPartsInput{Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId})
	c.Must(err, "ListParts")
	if len(listed.Parts) != 3 {
		c.Fatalf("ListParts returned %d parts, want 3", len(listed.Parts))
	}
	completed := make([]types.CompletedPart, 0, 3)
	for i, p := range listed.Parts {
		n := int32(i + 1)
		if aws.ToInt32(p.PartNumber) != n {
			c.Errorf("ListParts entry %d has PartNumber %d, want %d (ascending)", i, aws.ToInt32(p.PartNumber), n)
		}
		if aws.ToInt64(p.Size) != int64(len(parts[n-1])) {
			c.Errorf("part %d size %d, want %d", n, aws.ToInt64(p.Size), len(parts[n-1]))
		}
		if trimQuotes(aws.ToString(p.ETag)) != trimQuotes(etags[n]) {
			c.Errorf("part %d ETag %s from ListParts differs from UploadPart's %s", n, aws.ToString(p.ETag), etags[n])
		}
		completed = append(completed, types.CompletedPart{PartNumber: aws.Int32(n), ETag: aws.String(etags[n])})
	}

	done, err := c.s.s3.CompleteMultipartUpload(c.ctx, &s3.CompleteMultipartUploadInput{
		Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId,
		MultipartUpload: &types.CompletedMultipartUpload{Parts: completed},
	})
	c.Must(err, "CompleteMultipartUpload")
	c.Notef("multipart ETag is %s (Relay uses its own SHA-256, never the ETag, as a checksum)", aws.ToString(done.ETag))

	head, err := c.s.s3.HeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &key})
	c.Must(err, "HeadObject")
	if got := aws.ToInt64(head.ContentLength); got != int64(len(whole)) {
		c.Errorf("Content-Length %d, want %d", got, len(whole))
	}
	if got := aws.ToString(head.ContentType); got != "audio/mpeg" {
		c.Errorf("Content-Type %q, want the audio/mpeg set at CreateMultipartUpload", got)
	}
	resp, body := c.raw(http.MethodGet, key, nil)
	if resp.StatusCode != http.StatusOK || sha256Hex(body) != sha256Hex(whole) {
		c.Errorf("GET after complete: status %d, SHA-256 %s, want 200 and %s", resp.StatusCode, sha256Hex(body), sha256Hex(whole))
	}
}

func multipartAbort(c *C) {
	key := c.Key("aborted.mp3")
	created, err := c.s.s3.CreateMultipartUpload(c.ctx, &s3.CreateMultipartUploadInput{Bucket: &c.s.bucket, Key: &key})
	c.Must(err, "CreateMultipartUpload")
	part := randomBytes(partSize)
	_, err = c.s.s3.UploadPart(c.ctx, &s3.UploadPartInput{
		Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId, PartNumber: aws.Int32(1),
		Body: bytes.NewReader(part), ContentLength: aws.Int64(int64(len(part))),
	})
	c.Must(err, "UploadPart")
	_, err = c.s.s3.AbortMultipartUpload(c.ctx, &s3.AbortMultipartUploadInput{Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId})
	c.Must(err, "AbortMultipartUpload")

	listed, err := c.s.s3.ListParts(c.ctx, &s3.ListPartsInput{Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId})
	switch {
	case err == nil && len(listed.Parts) > 0:
		c.Errorf("ListParts after abort still returns %d part(s)", len(listed.Parts))
	case err == nil:
		c.Notef("ListParts after abort succeeds with no parts (AWS returns NoSuchUpload)")
	case errorCode(err) == "NoSuchUpload" || httpStatus(err) == http.StatusNotFound:
		c.Notef("ListParts after abort: %s", describeErr(err))
	default:
		c.Errorf("ListParts after abort: unexpected error %s", describeErr(err))
	}
	if _, err := c.s.s3.HeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &key}); httpStatus(err) != http.StatusNotFound {
		c.Errorf("HEAD of the aborted key: want 404, got %s", describeErr(err))
	}
}

func multipartCleanup(c *C) {
	prefix := c.Key("incomplete/")
	want := map[string]bool{}
	for i := range 3 {
		key := fmt.Sprintf("%supload-%d", prefix, i)
		created, err := c.s.s3.CreateMultipartUpload(c.ctx, &s3.CreateMultipartUploadInput{Bucket: &c.s.bucket, Key: &key})
		c.Must(err, "CreateMultipartUpload")
		want[aws.ToString(created.UploadId)] = true
		if i == 0 {
			part := randomBytes(1024)
			_, err := c.s.s3.UploadPart(c.ctx, &s3.UploadPartInput{
				Bucket: &c.s.bucket, Key: &key, UploadId: created.UploadId, PartNumber: aws.Int32(1),
				Body: bytes.NewReader(part), ContentLength: aws.Int64(int64(len(part))),
			})
			c.Must(err, "UploadPart")
		}
	}

	// The cleanup job's algorithm: page through the prefix one upload at a time, abort each.
	found, pages := 0, 0
	in := &s3.ListMultipartUploadsInput{Bucket: &c.s.bucket, Prefix: &prefix, MaxUploads: aws.Int32(1)}
	for {
		page, err := c.s.s3.ListMultipartUploads(c.ctx, in)
		c.Must(err, "ListMultipartUploads")
		pages++
		if len(page.Uploads) > 1 {
			c.Errorf("MaxUploads=1 returned %d uploads", len(page.Uploads))
		}
		for _, u := range page.Uploads {
			if want[aws.ToString(u.UploadId)] {
				found++
			}
			_, err := c.s.s3.AbortMultipartUpload(c.ctx, &s3.AbortMultipartUploadInput{Bucket: &c.s.bucket, Key: u.Key, UploadId: u.UploadId})
			c.Must(err, "AbortMultipartUpload")
		}
		if !aws.ToBool(page.IsTruncated) || pages > 10 {
			break
		}
		in.KeyMarker, in.UploadIdMarker = page.NextKeyMarker, page.NextUploadIdMarker
	}
	if found != len(want) {
		c.Errorf("ListMultipartUploads found %d of the %d incomplete uploads (in %d pages)", found, len(want), pages)
	}
	c.Notef("listed and aborted %d incomplete uploads in %d pages with MaxUploads=1", found, pages)

	after, err := c.s.s3.ListMultipartUploads(c.ctx, &s3.ListMultipartUploadsInput{Bucket: &c.s.bucket, Prefix: &prefix})
	c.Must(err, "ListMultipartUploads after cleanup")
	if len(after.Uploads) != 0 {
		c.Errorf("%d incomplete uploads remain after cleanup", len(after.Uploads))
	}
}

// --- 02 presigned URLs -------------------------------------------------------------------------------

func presignedPut(c *C) {
	key := c.Key("upload.mp3")
	body := randomBytes(64 << 10)
	p, err := c.s.presign.PresignPutObject(c.ctx, &s3.PutObjectInput{
		Bucket: &c.s.bucket, Key: &key, ContentType: aws.String("audio/mpeg"),
	}, s3.WithPresignExpires(15*time.Minute))
	c.Must(err, "PresignPutObject")

	// A client that ignores the signed Content-Type must be refused.
	wrong, _ := http.NewRequestWithContext(c.ctx, http.MethodPut, p.URL, bytes.NewReader(body))
	wrong.Header.Set("Content-Type", "text/html")
	if resp, _ := c.do(wrong); resp.StatusCode != http.StatusForbidden {
		c.Errorf("PUT with a Content-Type other than the signed one: status %d, want 403", resp.StatusCode)
	}

	req, _ := http.NewRequestWithContext(c.ctx, http.MethodPut, p.URL, bytes.NewReader(body))
	for name, values := range p.SignedHeader {
		if !strings.EqualFold(name, "host") {
			req.Header[name] = values
		}
	}
	resp, _ := c.do(req)
	if resp.StatusCode != http.StatusOK {
		c.Fatalf("presigned PUT: status %d, want 200", resp.StatusCode)
	}
	head, err := c.s.s3.HeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &key})
	c.Must(err, "HeadObject")
	if aws.ToInt64(head.ContentLength) != int64(len(body)) || aws.ToString(head.ContentType) != "audio/mpeg" {
		c.Errorf("after presigned PUT: length %d type %q, want %d audio/mpeg", aws.ToInt64(head.ContentLength), aws.ToString(head.ContentType), len(body))
	}
	c.Notef("signed headers: %s", strings.Join(sortedKeys(p.SignedHeader), ", "))
}

func presignedGet(c *C) {
	key := c.Key("episode.mp3")
	body := randomBytes(64 << 10)
	c.put(key, body, s3.PutObjectInput{ContentType: aws.String("audio/mpeg")})
	resp, got := c.raw(http.MethodGet, key, nil)
	if resp.StatusCode != http.StatusOK {
		c.Fatalf("presigned GET: status %d, want 200", resp.StatusCode)
	}
	if sha256Hex(got) != sha256Hex(body) {
		c.Errorf("presigned GET body SHA-256 differs from the uploaded object")
	}

	// A tampered signature must be refused.
	p, err := c.s.presign.PresignGetObject(c.ctx, &s3.GetObjectInput{Bucket: &c.s.bucket, Key: &key})
	c.Must(err, "PresignGetObject")
	u, _ := url.Parse(p.URL)
	q := u.Query()
	sig := q.Get("X-Amz-Signature")
	q.Set("X-Amz-Signature", flipHex(sig))
	u.RawQuery = q.Encode()
	req, _ := http.NewRequestWithContext(c.ctx, http.MethodGet, u.String(), nil)
	if resp, _ := c.do(req); resp.StatusCode != http.StatusForbidden {
		c.Errorf("GET with a tampered signature: status %d, want 403", resp.StatusCode)
	}
}

func presignedExpiry(c *C) {
	key := c.Key("expiring.mp3")
	c.put(key, randomBytes(1024), s3.PutObjectInput{})
	const ttl = 2 * time.Second
	get, err := c.s.presign.PresignGetObject(c.ctx, &s3.GetObjectInput{Bucket: &c.s.bucket, Key: &key}, s3.WithPresignExpires(ttl))
	c.Must(err, "PresignGetObject")
	putKey := c.Key("expiring-put.mp3")
	put, err := c.s.presign.PresignPutObject(c.ctx, &s3.PutObjectInput{Bucket: &c.s.bucket, Key: &putKey}, s3.WithPresignExpires(ttl))
	c.Must(err, "PresignPutObject")

	req, _ := http.NewRequestWithContext(c.ctx, http.MethodGet, get.URL, nil)
	if resp, _ := c.do(req); resp.StatusCode != http.StatusOK {
		c.Fatalf("GET before expiry: status %d, want 200", resp.StatusCode)
	}
	time.Sleep(ttl + 3*time.Second)
	req, _ = http.NewRequestWithContext(c.ctx, http.MethodGet, get.URL, nil)
	if resp, _ := c.do(req); resp.StatusCode != http.StatusForbidden {
		c.Errorf("GET %s after expiry: status %d, want 403", ttl+3*time.Second, resp.StatusCode)
	}
	req, _ = http.NewRequestWithContext(c.ctx, http.MethodPut, put.URL, bytes.NewReader([]byte("late")))
	if resp, _ := c.do(req); resp.StatusCode != http.StatusForbidden {
		c.Errorf("PUT %s after expiry: status %d, want 403", ttl+3*time.Second, resp.StatusCode)
	}
	c.Notef("URLs signed for %s were refused %s later", ttl, ttl+3*time.Second)
}

// --- 03 range requests -------------------------------------------------------------------------------

var (
	rangeOnce sync.Once
	rangeKey  string
	rangeBody []byte
	rangeErr  string
)

// rangeObject uploads one shared 10,000-byte object for the range cases.
func rangeObject(c *C) (string, []byte) {
	rangeOnce.Do(func() {
		rangeKey = c.s.prefix + "03/ranges.mp3"
		rangeBody = randomBytes(rangeObjectSize)
		_, err := c.s.s3.PutObject(c.ctx, &s3.PutObjectInput{
			Bucket: &c.s.bucket, Key: &rangeKey, Body: bytes.NewReader(rangeBody),
			ContentLength: aws.Int64(rangeObjectSize), ContentType: aws.String("audio/mpeg"),
		})
		if err != nil {
			rangeErr = describeErr(err)
		}
	})
	if rangeErr != "" {
		c.Fatalf("upload the range object: %s", rangeErr)
	}
	return rangeKey, rangeBody
}

func rangeCase(header string, first, last int) func(*C) {
	return func(c *C) {
		key, body := rangeObject(c)
		resp, got := c.raw(http.MethodGet, key, map[string]string{"Range": header})
		if resp.StatusCode != http.StatusPartialContent {
			c.Fatalf("Range %s: status %d, want 206", header, resp.StatusCode)
		}
		wantCR := fmt.Sprintf("bytes %d-%d/%d", first, last, len(body))
		if cr := resp.Header.Get("Content-Range"); cr != wantCR {
			c.Errorf("Content-Range %q, want %q", cr, wantCR)
		}
		if ar := resp.Header.Get("Accept-Ranges"); ar != "bytes" {
			c.Errorf("Accept-Ranges %q on the 206, want \"bytes\"", ar)
		}
		if cl := resp.Header.Get("Content-Length"); cl != strconv.Itoa(last-first+1) {
			c.Errorf("Content-Length %s, want %d", cl, last-first+1)
		}
		if !bytes.Equal(got, body[first:last+1]) {
			c.Errorf("body is not bytes %d-%d of the object (%d bytes received)", first, last, len(got))
		}
		if header == "bytes=0-0" {
			full, _ := c.raw(http.MethodGet, key, nil)
			if ar := full.Header.Get("Accept-Ranges"); ar != "bytes" {
				c.Errorf("Accept-Ranges %q on a full 200 GET, want \"bytes\"", ar)
			}
		}
	}
}

func rangeMulti(c *C) {
	key, body := rangeObject(c)
	resp, got := c.raw(http.MethodGet, key, map[string]string{"Range": "bytes=0-9,20-29"})
	ct := resp.Header.Get("Content-Type")
	mediaType, params, _ := mime.ParseMediaType(ct)
	switch {
	case resp.StatusCode == http.StatusOK:
		c.Notef("ignores multiple ranges: 200 with the whole object (allowed by RFC 9110)")
		if !bytes.Equal(got, body) {
			c.Errorf("200 body is not the whole object")
		}
	case resp.StatusCode == http.StatusPartialContent && mediaType == "multipart/byteranges":
		mr := multipart.NewReader(bytes.NewReader(got), params["boundary"])
		for i, r := range [][2]int{{0, 9}, {20, 29}} {
			part, err := mr.NextPart()
			if err != nil {
				c.Fatalf("multipart/byteranges part %d: %v", i+1, err)
			}
			data, _ := io.ReadAll(part)
			if !bytes.Equal(data, body[r[0]:r[1]+1]) {
				c.Errorf("multipart/byteranges part %d (%s) is not bytes %d-%d", i+1, part.Header.Get("Content-Range"), r[0], r[1])
			}
		}
		c.Notef("returns 206 multipart/byteranges with both ranges")
	case resp.StatusCode == http.StatusPartialContent:
		cr := resp.Header.Get("Content-Range")
		c.Notef("returns a single range: 206 with Content-Range %q", cr)
		var first, last, size int
		if _, err := fmt.Sscanf(cr, "bytes %d-%d/%d", &first, &last, &size); err != nil || last >= len(body) || !bytes.Equal(got, body[first:last+1]) {
			c.Errorf("the 206 body does not match its Content-Range %q", cr)
		}
	default:
		c.Notef("rejects multiple ranges with status %d", resp.StatusCode)
		if resp.StatusCode != http.StatusRequestedRangeNotSatisfiable && resp.StatusCode != http.StatusBadRequest {
			c.Errorf("unexpected status %d", resp.StatusCode)
		}
	}
	c.Notef("Relay players and the edge only send single ranges; multi-range behaviour is recorded, not required")
}

func rangeUnsatisfiable(c *C) {
	key, body := rangeObject(c)
	resp, _ := c.raw(http.MethodGet, key, map[string]string{"Range": fmt.Sprintf("bytes=%d-", len(body)+100)})
	c.Notef("Range past the end: status %d, Content-Range %q", resp.StatusCode, resp.Header.Get("Content-Range"))
	if resp.StatusCode != http.StatusRequestedRangeNotSatisfiable {
		c.Errorf("status %d, want 416", resp.StatusCode)
	}
}

// --- 04 HEAD ------------------------------------------------------------------------------------------

func headObject(c *C) {
	key := c.Key("head.mp3")
	body := randomBytes(4321)
	before := time.Now()
	c.put(key, body, s3.PutObjectInput{ContentType: aws.String("audio/mpeg")})

	resp, got := c.raw(http.MethodHead, key, nil)
	if resp.StatusCode != http.StatusOK {
		c.Fatalf("HEAD: status %d, want 200", resp.StatusCode)
	}
	if len(got) != 0 {
		c.Errorf("HEAD returned a %d-byte body", len(got))
	}
	if cl := resp.Header.Get("Content-Length"); cl != "4321" {
		c.Errorf("Content-Length %q, want 4321", cl)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "audio/mpeg" {
		c.Errorf("Content-Type %q, want audio/mpeg", ct)
	}
	etag := resp.Header.Get("ETag")
	switch {
	case etag == "":
		c.Errorf("no ETag")
	case !strings.HasPrefix(etag, `"`) || !strings.HasSuffix(etag, `"`):
		c.Errorf("ETag %s is not a quoted entity tag", etag)
	}
	sum := md5.Sum(body) //nolint:gosec // G401: describing the ETag, not securing anything.
	c.Notef("single-part ETag %s the MD5 of the body", map[bool]string{true: "is", false: "is not"}[trimQuotes(etag) == hex.EncodeToString(sum[:])])
	lm, err := http.ParseTime(resp.Header.Get("Last-Modified"))
	if err != nil {
		c.Errorf("Last-Modified %q is not an HTTP date", resp.Header.Get("Last-Modified"))
	} else if skew := lm.Sub(before.Truncate(time.Second)); skew < -5*time.Minute || skew > 5*time.Minute {
		c.Errorf("Last-Modified %s is %s from the upload time (clock skew?)", lm.UTC(), skew)
	}
	c.Notef("Accept-Ranges on HEAD: %q", resp.Header.Get("Accept-Ranges"))
}

// --- 05 and 06 metadata ------------------------------------------------------------------------------

func contentType(ct string) func(*C) {
	return func(c *C) {
		key := c.Key("object")
		c.put(key, []byte("relay"), s3.PutObjectInput{ContentType: aws.String(ct)})
		for _, method := range []string{http.MethodHead, http.MethodGet} {
			resp, _ := c.raw(method, key, nil)
			if got := resp.Header.Get("Content-Type"); got != ct {
				c.Errorf("%s Content-Type %q, want %q", method, got, ct)
			}
		}
	}
}

func headerRoundTrip(name, value string) func(*C) {
	return func(c *C) {
		key := c.Key("object.mp3")
		in := s3.PutObjectInput{ContentType: aws.String("audio/mpeg")}
		switch name {
		case "Cache-Control":
			in.CacheControl = aws.String(value)
		case "Content-Disposition":
			in.ContentDisposition = aws.String(value)
		}
		c.put(key, []byte("relay"), in)
		for _, method := range []string{http.MethodHead, http.MethodGet} {
			resp, _ := c.raw(method, key, nil)
			if got := resp.Header.Get(name); got != value {
				c.Errorf("%s %s %q, want %q", method, name, got, value)
			}
		}
	}
}

// --- 07 conditional requests -------------------------------------------------------------------------

func ifNoneMatch(c *C) {
	key := c.Key("feed.xml")
	c.put(key, []byte("<rss/>"), s3.PutObjectInput{ContentType: aws.String("application/rss+xml")})
	head, _ := c.raw(http.MethodHead, key, nil)
	etag := head.Header.Get("ETag")
	if etag == "" {
		c.Fatalf("no ETag to condition on")
	}
	resp, body := c.raw(http.MethodGet, key, map[string]string{"If-None-Match": etag})
	if resp.StatusCode != http.StatusNotModified {
		c.Errorf("If-None-Match with the current ETag: status %d, want 304", resp.StatusCode)
	}
	if len(body) != 0 {
		c.Errorf("304 carried a %d-byte body", len(body))
	}
	if resp.StatusCode == http.StatusNotModified && resp.Header.Get("ETag") == "" {
		c.Notef("the 304 has no ETag header (RFC 9110 says it should)")
	}
	if resp, _ := c.raw(http.MethodGet, key, map[string]string{"If-None-Match": `"not-the-etag"`}); resp.StatusCode != http.StatusOK {
		c.Errorf("If-None-Match with another ETag: status %d, want 200", resp.StatusCode)
	}
	if resp, _ := c.raw(http.MethodGet, key, map[string]string{"If-None-Match": "*"}); resp.StatusCode != http.StatusNotModified {
		c.Notef("If-None-Match: * returned %d (RFC 9110: 304)", resp.StatusCode)
	}
}

func ifModifiedSince(c *C) {
	key := c.Key("feed.xml")
	c.put(key, []byte("<rss/>"), s3.PutObjectInput{ContentType: aws.String("application/rss+xml")})
	head, _ := c.raw(http.MethodHead, key, nil)
	lm := head.Header.Get("Last-Modified")
	lmTime, err := http.ParseTime(lm)
	if err != nil {
		c.Fatalf("Last-Modified %q is not an HTTP date", lm)
	}
	if resp, _ := c.raw(http.MethodGet, key, map[string]string{"If-Modified-Since": lm}); resp.StatusCode != http.StatusNotModified {
		c.Errorf("If-Modified-Since equal to Last-Modified: status %d, want 304", resp.StatusCode)
	}
	earlier := lmTime.Add(-time.Hour).UTC().Format(http.TimeFormat)
	if resp, _ := c.raw(http.MethodGet, key, map[string]string{"If-Modified-Since": earlier}); resp.StatusCode != http.StatusOK {
		c.Errorf("If-Modified-Since an hour earlier: status %d, want 200", resp.StatusCode)
	}
	// RFC 9110 §13.2.2: If-None-Match takes precedence over If-Modified-Since.
	resp, _ := c.raw(http.MethodGet, key, map[string]string{"If-None-Match": `"not-the-etag"`, "If-Modified-Since": lm})
	c.Notef("If-None-Match (no match) with If-Modified-Since (not modified): status %d (RFC 9110: 200)", resp.StatusCode)
}

// --- 08 listing ---------------------------------------------------------------------------------------

type listFixture struct {
	flat []string // sorted
	dirs []string // common prefixes under tree/, sorted
	root string
	err  string
}

const treeDirs = 30

var listOnce sync.Once

// fixture creates -list-objects objects under 08/flat/ and one object in each of 30 directories under
// 08/tree/, once for both listing cases.
func (s *suite) fixture(c *C) *listFixture {
	listOnce.Do(func() {
		f := &listFixture{root: s.prefix + "08/"}
		for i := range *flagListObjects {
			f.flat = append(f.flat, fmt.Sprintf("%sflat/obj-%05d", f.root, i))
		}
		for i := range treeDirs {
			f.dirs = append(f.dirs, fmt.Sprintf("%stree/d%02d/", f.root, i))
		}
		keys := slices.Concat(f.flat, mapSlice(f.dirs, func(d string) string { return d + "item" }))
		g, ctx := errgroup.WithContext(c.ctx)
		g.SetLimit(32)
		for _, k := range keys {
			g.Go(func() error {
				_, err := s.s3.PutObject(ctx, &s3.PutObjectInput{Bucket: &s.bucket, Key: aws.String(k), Body: strings.NewReader("x"), ContentLength: aws.Int64(1)})
				return err
			})
		}
		if err := g.Wait(); err != nil {
			f.err = describeErr(err)
		}
		s.listFixture = f
	})
	if s.listFixture.err != "" {
		c.Fatalf("create the listing fixture: %s", s.listFixture.err)
	}
	return s.listFixture
}

func listPagination(c *C) {
	f := c.s.fixture(c)
	prefix := f.root + "flat/"
	c.Notef("%d objects under the prefix", len(f.flat))

	// Default page size, then an explicit one.
	for _, maxKeys := range []int32{0, 300} {
		in := &s3.ListObjectsV2Input{Bucket: &c.s.bucket, Prefix: &prefix}
		if maxKeys > 0 {
			in.MaxKeys = aws.Int32(maxKeys)
		}
		var keys []string
		pages := 0
		for {
			page, err := c.s.s3.ListObjectsV2(c.ctx, in)
			c.Must(err, "ListObjectsV2")
			pages++
			limit := 1000
			if maxKeys > 0 {
				limit = int(maxKeys)
			}
			if len(page.Contents) > limit {
				c.Errorf("page %d has %d keys, over the limit of %d", pages, len(page.Contents), limit)
			}
			if page.KeyCount != nil && int(*page.KeyCount) != len(page.Contents) {
				c.Errorf("page %d KeyCount %d, but %d keys", pages, *page.KeyCount, len(page.Contents))
			}
			for _, o := range page.Contents {
				keys = append(keys, aws.ToString(o.Key))
			}
			if !aws.ToBool(page.IsTruncated) {
				break
			}
			if page.NextContinuationToken == nil {
				c.Fatalf("page %d is truncated but has no NextContinuationToken", pages)
			}
			if pages > len(f.flat) {
				c.Fatalf("pagination does not terminate")
			}
			in.ContinuationToken = page.NextContinuationToken
		}
		label := "default MaxKeys"
		if maxKeys > 0 {
			label = fmt.Sprintf("MaxKeys=%d", maxKeys)
		}
		c.Notef("%s: %d keys in %d pages", label, len(keys), pages)
		if pages < 2 {
			c.Errorf("%s: all %d keys came in one page; want continuation tokens", label, len(keys))
		}
		if !slices.Equal(keys, f.flat) {
			c.Errorf("%s: listed %d keys, want exactly the %d uploaded, in ascending order", label, len(keys), len(f.flat))
		}
	}

	// StartAfter skips to a key.
	after := f.flat[len(f.flat)-51]
	page, err := c.s.s3.ListObjectsV2(c.ctx, &s3.ListObjectsV2Input{Bucket: &c.s.bucket, Prefix: &prefix, StartAfter: &after})
	c.Must(err, "ListObjectsV2 StartAfter")
	if len(page.Contents) != 50 || aws.ToString(page.Contents[0].Key) != f.flat[len(f.flat)-50] {
		c.Errorf("StartAfter: %d keys, want the last 50", len(page.Contents))
	}
}

func listDelimiter(c *C) {
	f := c.s.fixture(c)

	// At the root, 1,100+ objects collapse into two common prefixes and no truncation.
	root, err := c.s.s3.ListObjectsV2(c.ctx, &s3.ListObjectsV2Input{Bucket: &c.s.bucket, Prefix: &f.root, Delimiter: aws.String("/")})
	c.Must(err, "ListObjectsV2 root")
	got := mapSlice(root.CommonPrefixes, func(p types.CommonPrefix) string { return aws.ToString(p.Prefix) })
	if want := []string{f.root + "flat/", f.root + "tree/"}; !slices.Equal(got, want) || len(root.Contents) != 0 || aws.ToBool(root.IsTruncated) {
		c.Errorf("root: common prefixes %v, %d objects, truncated=%v; want %v, 0, false", got, len(root.Contents), aws.ToBool(root.IsTruncated), want)
	}

	// Common prefixes paginate too.
	tree := f.root + "tree/"
	in := &s3.ListObjectsV2Input{Bucket: &c.s.bucket, Prefix: &tree, Delimiter: aws.String("/"), MaxKeys: aws.Int32(7)}
	var prefixes []string
	pages := 0
	for {
		page, err := c.s.s3.ListObjectsV2(c.ctx, in)
		c.Must(err, "ListObjectsV2 tree")
		pages++
		if len(page.Contents) != 0 {
			c.Errorf("tree page %d returned %d objects, want only common prefixes", pages, len(page.Contents))
		}
		if len(page.CommonPrefixes) > 7 {
			c.Errorf("tree page %d returned %d common prefixes with MaxKeys=7", pages, len(page.CommonPrefixes))
		}
		for _, p := range page.CommonPrefixes {
			prefixes = append(prefixes, aws.ToString(p.Prefix))
		}
		if !aws.ToBool(page.IsTruncated) || pages > treeDirs {
			break
		}
		in.ContinuationToken = page.NextContinuationToken
	}
	c.Notef("%d common prefixes in %d pages with MaxKeys=7", len(prefixes), pages)
	if !slices.Equal(prefixes, f.dirs) {
		c.Errorf("tree: %d common prefixes, want the %d directories exactly once each, in order", len(prefixes), len(f.dirs))
	}
}

// --- 09 lifecycle -------------------------------------------------------------------------------------

func lifecycleExpire(prefix string) types.LifecycleRule {
	return types.LifecycleRule{
		ID: aws.String("relay-conformance-expire"), Status: types.ExpirationStatusEnabled,
		Filter:     &types.LifecycleRuleFilter{Prefix: aws.String(prefix + "expire/")},
		Expiration: &types.LifecycleExpiration{Days: aws.Int32(1)},
	}
}

func lifecycleAbortMultipart(prefix string) types.LifecycleRule {
	return types.LifecycleRule{
		ID: aws.String("relay-conformance-abort-mpu"), Status: types.ExpirationStatusEnabled,
		Filter:                         &types.LifecycleRuleFilter{Prefix: aws.String(prefix + "incoming/")},
		AbortIncompleteMultipartUpload: &types.AbortIncompleteMultipartUpload{DaysAfterInitiation: aws.Int32(1)},
	}
}

func lifecycleCase(rule func(prefix string) types.LifecycleRule) func(*C) {
	return func(c *C) {
		if !*flagAllowBucketConfig {
			c.Skip("changes the bucket's lifecycle configuration; rerun with -allow-bucket-config on a scratch bucket")
		}
		bucket := &c.s.bucket
		existing, err := c.s.s3.GetBucketLifecycleConfiguration(c.ctx, &s3.GetBucketLifecycleConfigurationInput{Bucket: bucket})
		var previous []types.LifecycleRule
		switch {
		case err == nil:
			previous = existing.Rules
		case errorCode(err) == "NoSuchLifecycleConfiguration":
		case isNotImplemented(err):
			c.Unsupported("GetBucketLifecycleConfiguration: %s", describeErr(err))
		default:
			c.Fatalf("GetBucketLifecycleConfiguration: %s", describeErr(err))
		}

		// PUT replaces the whole configuration, so add to the existing rules and restore them afterwards.
		r := rule(c.Key(""))
		_, err = c.s.s3.PutBucketLifecycleConfiguration(c.ctx, &s3.PutBucketLifecycleConfigurationInput{
			Bucket: bucket, LifecycleConfiguration: &types.BucketLifecycleConfiguration{Rules: append(slices.Clone(previous), r)},
		})
		c.Cleanup(func(ctx context.Context) error {
			if len(previous) == 0 {
				_, err := c.s.s3.DeleteBucketLifecycle(ctx, &s3.DeleteBucketLifecycleInput{Bucket: bucket})
				return err
			}
			_, err := c.s.s3.PutBucketLifecycleConfiguration(ctx, &s3.PutBucketLifecycleConfigurationInput{
				Bucket: bucket, LifecycleConfiguration: &types.BucketLifecycleConfiguration{Rules: previous},
			})
			return err
		})
		if err != nil {
			if isNotImplemented(err) || errorCode(err) == "MalformedXML" || errorCode(err) == "InvalidRequest" {
				c.Unsupported("PutBucketLifecycleConfiguration: %s", describeErr(err))
			}
			c.Fatalf("PutBucketLifecycleConfiguration: %s", describeErr(err))
		}

		got, err := c.s.s3.GetBucketLifecycleConfiguration(c.ctx, &s3.GetBucketLifecycleConfigurationInput{Bucket: bucket})
		c.Must(err, "GetBucketLifecycleConfiguration after PUT")
		i := slices.IndexFunc(got.Rules, func(g types.LifecycleRule) bool { return aws.ToString(g.ID) == aws.ToString(r.ID) })
		if i < 0 {
			c.Fatalf("the rule %s was accepted but is not in the configuration read back", aws.ToString(r.ID))
		}
		g := got.Rules[i]
		if g.Filter == nil || aws.ToString(g.Filter.Prefix) != aws.ToString(r.Filter.Prefix) {
			c.Errorf("rule prefix read back as %v, want %s", g.Filter, aws.ToString(r.Filter.Prefix))
		}
		if r.Expiration != nil && (g.Expiration == nil || aws.ToInt32(g.Expiration.Days) != 1) {
			c.Errorf("expiration read back as %+v, want 1 day", g.Expiration)
		}
		if r.AbortIncompleteMultipartUpload != nil && (g.AbortIncompleteMultipartUpload == nil || aws.ToInt32(g.AbortIncompleteMultipartUpload.DaysAfterInitiation) != 1) {
			c.Errorf("abort-incomplete-multipart read back as %+v, want 1 day", g.AbortIncompleteMultipartUpload)
		}
		c.Notef("rule accepted and read back; enforcement is not observed because the shortest period is one day")
	}
}

// --- 10 copy and checksums -----------------------------------------------------------------------------

func copyObject(c *C) {
	src, dst := c.Key("masters/master.mp4"), c.Key("delivery/v2/episode.mp4")
	body := randomBytes(256 << 10)
	sum := sha256Hex(body)
	c.put(src, body, s3.PutObjectInput{
		ContentType: aws.String("video/mp4"), CacheControl: aws.String("private, no-store"),
		ContentDisposition: aws.String(`attachment; filename="master.mp4"`), Metadata: map[string]string{"sha256": sum},
	})

	_, err := c.s.s3.CopyObject(c.ctx, &s3.CopyObjectInput{Bucket: &c.s.bucket, Key: &dst, CopySource: aws.String(copySource(c.s.bucket, src))})
	c.Must(err, "CopyObject (metadata COPY)")
	head, err := c.s.s3.HeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &dst})
	c.Must(err, "HeadObject copy")
	if aws.ToString(head.ContentType) != "video/mp4" || aws.ToString(head.CacheControl) != "private, no-store" ||
		aws.ToString(head.ContentDisposition) != `attachment; filename="master.mp4"` || head.Metadata["sha256"] != sum {
		c.Errorf("copy did not keep the metadata: type %q, cache %q, disposition %q, x-amz-meta-sha256 %q",
			aws.ToString(head.ContentType), aws.ToString(head.CacheControl), aws.ToString(head.ContentDisposition), head.Metadata["sha256"])
	}
	if _, got := c.raw(http.MethodGet, dst, nil); sha256Hex(got) != sum {
		c.Errorf("copied body SHA-256 differs from the source")
	}

	// Promotion to a public delivery version replaces the metadata.
	_, err = c.s.s3.CopyObject(c.ctx, &s3.CopyObjectInput{
		Bucket: &c.s.bucket, Key: &dst, CopySource: aws.String(copySource(c.s.bucket, src)),
		MetadataDirective: types.MetadataDirectiveReplace, ContentType: aws.String("video/mp4"),
		CacheControl: aws.String("public, max-age=31536000, immutable"), Metadata: map[string]string{"sha256": sum, "version": "2"},
	})
	c.Must(err, "CopyObject (metadata REPLACE)")
	head, err = c.s.s3.HeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &dst})
	c.Must(err, "HeadObject replaced copy")
	if aws.ToString(head.CacheControl) != "public, max-age=31536000, immutable" || head.Metadata["version"] != "2" {
		c.Errorf("REPLACE directive not applied: cache %q, x-amz-meta-version %q", aws.ToString(head.CacheControl), head.Metadata["version"])
	}
}

func uploadPartCopy(c *C) {
	src, dst := c.Key("masters/large.mov"), c.Key("delivery/large.mov")
	body := randomBytes(partSize + 256<<10)
	c.put(src, body, s3.PutObjectInput{ContentType: aws.String("video/quicktime")})
	created, err := c.s.s3.CreateMultipartUpload(c.ctx, &s3.CreateMultipartUploadInput{Bucket: &c.s.bucket, Key: &dst, ContentType: aws.String("video/quicktime")})
	c.Must(err, "CreateMultipartUpload")
	var parts []types.CompletedPart
	for i, r := range [][2]int{{0, partSize - 1}, {partSize, len(body) - 1}} {
		out, err := c.s.s3.UploadPartCopy(c.ctx, &s3.UploadPartCopyInput{
			Bucket: &c.s.bucket, Key: &dst, UploadId: created.UploadId, PartNumber: aws.Int32(int32(i + 1)),
			CopySource: aws.String(copySource(c.s.bucket, src)), CopySourceRange: aws.String(fmt.Sprintf("bytes=%d-%d", r[0], r[1])),
		})
		if err != nil && isNotImplemented(err) {
			c.Unsupported("UploadPartCopy: %s", describeErr(err))
		}
		c.Must(err, fmt.Sprintf("UploadPartCopy part %d", i+1))
		if out.CopyPartResult == nil {
			c.Fatalf("UploadPartCopy part %d returned no CopyPartResult", i+1)
		}
		parts = append(parts, types.CompletedPart{PartNumber: aws.Int32(int32(i + 1)), ETag: out.CopyPartResult.ETag})
	}
	_, err = c.s.s3.CompleteMultipartUpload(c.ctx, &s3.CompleteMultipartUploadInput{
		Bucket: &c.s.bucket, Key: &dst, UploadId: created.UploadId, MultipartUpload: &types.CompletedMultipartUpload{Parts: parts},
	})
	c.Must(err, "CompleteMultipartUpload")
	if _, got := c.raw(http.MethodGet, dst, nil); sha256Hex(got) != sha256Hex(body) {
		c.Errorf("the part-copied object's SHA-256 differs from the source")
	}
	c.Notef("needed only for copies over 5 GiB on targets that enforce AWS's CopyObject size limit")
}

func checksumSHA256(c *C) {
	key := c.Key("checksummed.mp3")
	body := randomBytes(32 << 10)
	sum := sha256.Sum256(body)
	good := base64.StdEncoding.EncodeToString(sum[:])

	_, err := c.s.s3.PutObject(c.ctx, &s3.PutObjectInput{
		Bucket: &c.s.bucket, Key: &key, Body: bytes.NewReader(body), ContentLength: aws.Int64(int64(len(body))),
		ChecksumAlgorithm: types.ChecksumAlgorithmSha256, ChecksumSHA256: aws.String(good),
	})
	if err != nil && isNotImplemented(err) {
		c.Unsupported("PutObject with x-amz-checksum-sha256: %s", describeErr(err))
	}
	c.Must(err, "PutObject with the correct x-amz-checksum-sha256")
	head, err := c.s.s3.HeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &key, ChecksumMode: types.ChecksumModeEnabled})
	c.Must(err, "HeadObject ChecksumMode=ENABLED")
	returned := aws.ToString(head.ChecksumSHA256)

	badKey := c.Key("bad-checksum.mp3")
	wrong := sha256.Sum256([]byte("not the body"))
	_, badErr := c.s.s3.PutObject(c.ctx, &s3.PutObjectInput{
		Bucket: &c.s.bucket, Key: &badKey, Body: bytes.NewReader(body), ContentLength: aws.Int64(int64(len(body))),
		ChecksumAlgorithm: types.ChecksumAlgorithmSha256, ChecksumSHA256: aws.String(base64.StdEncoding.EncodeToString(wrong[:])),
	})
	rejected := badErr != nil
	c.Notef("stored checksum returned on HEAD: %q; wrong checksum rejected: %v (%s)", returned, rejected, describeErr(badErr))

	switch {
	case returned == good && rejected:
		// Verified and returned.
	case returned == "" && !rejected:
		c.Unsupported("the target ignores x-amz-checksum-sha256: it neither verifies nor returns it. Relay verifies its own SHA-256 after upload instead")
	case !rejected:
		c.Errorf("a PUT with a wrong x-amz-checksum-sha256 was accepted")
	default:
		c.Errorf("HEAD returned checksum %q, want %q", returned, good)
	}
}

// --- 11 access logs ------------------------------------------------------------------------------------

func accessLogs(c *C) {
	if *flagAccessLogNote != "" {
		c.Notef("how to get download logs on this target: %s", *flagAccessLogNote)
	}
	bucket := &c.s.bucket
	existing, err := c.s.s3.GetBucketLogging(c.ctx, &s3.GetBucketLoggingInput{Bucket: bucket})
	switch {
	case err != nil && isNotImplemented(err):
		c.Unsupported("GetBucketLogging is not implemented (%s)", describeErr(err))
	case err != nil:
		c.Fatalf("GetBucketLogging: %s", describeErr(err))
	case existing.LoggingEnabled != nil:
		c.Notef("S3 server access logging is already on, delivering to %s/%s",
			aws.ToString(existing.LoggingEnabled.TargetBucket), aws.ToString(existing.LoggingEnabled.TargetPrefix))
		return
	}
	// A GET that answers "off" proves little (some targets stub it), so turn logging on and read it back.
	if !*flagAllowBucketConfig {
		c.Skip("logging is off; enabling it changes the bucket's configuration, so rerun with -allow-bucket-config on a scratch bucket")
	}
	target := c.Key("access-logs/")
	_, err = c.s.s3.PutBucketLogging(c.ctx, &s3.PutBucketLoggingInput{Bucket: bucket, BucketLoggingStatus: &types.BucketLoggingStatus{
		LoggingEnabled: &types.LoggingEnabled{TargetBucket: bucket, TargetPrefix: &target},
	}})
	c.Cleanup(func(ctx context.Context) error {
		_, err := c.s.s3.PutBucketLogging(ctx, &s3.PutBucketLoggingInput{Bucket: bucket, BucketLoggingStatus: &types.BucketLoggingStatus{}})
		if err != nil && errorCode(err) == "BucketAlreadyOwnedByYou" {
			return nil // the PUT never reached a logging handler, so there is nothing to undo
		}
		return err
	})
	if err != nil {
		c.Unsupported("PutBucketLogging is refused, so S3 server access logs cannot be enabled: %s", describeErr(err))
	}
	got, err := c.s.s3.GetBucketLogging(c.ctx, &s3.GetBucketLoggingInput{Bucket: bucket})
	c.Must(err, "GetBucketLogging after PUT")
	if got.LoggingEnabled == nil || aws.ToString(got.LoggingEnabled.TargetPrefix) != target {
		c.Unsupported("PutBucketLogging succeeded but GetBucketLogging does not return the configuration: the API is a stub")
	}

	// Make a download, then look for a log object. AWS delivers within hours, so absence is only noted.
	key := c.Key("logged.mp3")
	c.put(key, []byte("relay"), s3.PutObjectInput{ContentType: aws.String("audio/mpeg")})
	c.raw(http.MethodGet, key, nil)
	deadline := time.Now().Add(*flagAccessLogWait)
	for {
		out, err := c.s.s3.ListObjectsV2(c.ctx, &s3.ListObjectsV2Input{Bucket: bucket, Prefix: &target, MaxKeys: aws.Int32(1)})
		c.Must(err, "ListObjectsV2 of the log prefix")
		if len(out.Contents) > 0 {
			c.Notef("a log object appeared under the target prefix: %s", aws.ToString(out.Contents[0].Key))
			return
		}
		if time.Now().After(deadline) {
			c.Notef("logging is configured, but no log object appeared within %s (delivery is asynchronous; check later)", *flagAccessLogWait)
			return
		}
		time.Sleep(2 * time.Second)
	}
}

// --- 12 anonymous access ------------------------------------------------------------------------------

func anonymousDenied(c *C) {
	key := c.Key("private.mp3")
	c.put(key, []byte("private"), s3.PutObjectInput{ContentType: aws.String("audio/mpeg")})
	objURL := c.s.objectURL(key)
	bucketURL := strings.TrimSuffix(c.s.objectURL(""), "/")
	checks := []struct {
		name, method, url string
	}{
		{"GET object", http.MethodGet, objURL},
		{"HEAD object", http.MethodHead, objURL},
		{"list bucket (ListObjectsV2)", http.MethodGet, bucketURL + "?list-type=2"},
		{"list bucket (ListObjects v1)", http.MethodGet, bucketURL + "/"},
		{"PUT object", http.MethodPut, c.s.objectURL(c.Key("anonymous-write"))},
	}
	for _, chk := range checks {
		var body *bytes.Reader
		if chk.method == http.MethodPut {
			body = bytes.NewReader([]byte("anonymous"))
		} else {
			body = bytes.NewReader(nil)
		}
		req, _ := http.NewRequestWithContext(c.ctx, chk.method, chk.url, body)
		resp, _ := c.do(req)
		if resp.StatusCode != http.StatusForbidden && resp.StatusCode != http.StatusUnauthorized {
			c.Errorf("anonymous %s: status %d, want 403", chk.name, resp.StatusCode)
		}
	}
}

// --- small helpers ------------------------------------------------------------------------------------

func copySource(bucket, key string) string {
	segments := strings.Split(key, "/")
	for i, s := range segments {
		segments[i] = url.PathEscape(s)
	}
	return bucket + "/" + strings.Join(segments, "/")
}

func flipHex(s string) string {
	if s == "" {
		return "0"
	}
	last := s[len(s)-1]
	repl := byte('0')
	if last == '0' {
		repl = '1'
	}
	return s[:len(s)-1] + string(repl)
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func mapSlice[T, U any](in []T, f func(T) U) []U {
	out := make([]U, len(in))
	for i, v := range in {
		out[i] = f(v)
	}
	return out
}
