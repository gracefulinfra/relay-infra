package s3conformance

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"runtime/debug"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

var (
	flagEndpoint          = flag.String("endpoint", "", "S3 endpoint URL, for example http://localhost:8333. Empty skips the conformance cases")
	flagBucket            = flag.String("bucket", "", "bucket to test in; the suite only writes under -prefix")
	flagRegion            = flag.String("region", "us-east-1", "signing region")
	flagPathStyle         = flag.Bool("path-style", true, "path-style addressing; false uses virtual-hosted style")
	flagTarget            = flag.String("target", "", "target name for the report file, for example seaweedfs-4.47")
	flagReportDir         = flag.String("report-dir", "reports", "directory for the Markdown report; empty disables the report")
	flagPrefix            = flag.String("prefix", "", "key prefix for test objects (default relay-conformance/<run id>/)")
	flagCreateBucket      = flag.Bool("create-bucket", false, "create -bucket if it does not exist, and delete it afterwards if the suite created it")
	flagAllowBucketConfig = flag.Bool("allow-bucket-config", false, "run cases that change bucket-level configuration (lifecycle rules); use a scratch bucket")
	flagKeep              = flag.Bool("keep", false, "keep the test objects instead of deleting them")
	flagListObjects       = flag.Int("list-objects", 1100, "objects to create for the listing cases (must be more than 1000)")
	flagAccessLogNote     = flag.String("access-log-note", "", "how download logs are obtained on this target; recorded in the report for case 11")
	flagChecksums         = flag.String("sdk-checksums", "when_supported", "SDK request checksum mode: when_supported (the SDK default) or when_required")
	flagStrict            = flag.Bool("strict", false, "fail the run on soft failures too")
	flagHTTP1             = flag.Bool("http1", false, "use HTTP/1.1 only; by default an https endpoint may negotiate HTTP/2, as the AWS SDK does")
	flagCAFile            = flag.String("ca-file", "", "PEM file with extra CA certificates to trust for an https endpoint with a private CA")
	flagAccessLogWait     = flag.Duration("access-log-wait", 30*time.Second, "how long case 11 waits for a server access log object to appear")
)

// baseTransport is http.DefaultTransport, trusting the certificates in caFile as well when it is set,
// and limited to HTTP/1.1 when http1 is set.
func baseTransport(caFile string, http1 bool) (http.RoundTripper, error) {
	if caFile == "" && !http1 {
		return http.DefaultTransport, nil
	}
	t := http.DefaultTransport.(*http.Transport).Clone()
	if caFile != "" {
		pem, err := os.ReadFile(caFile) // #nosec G304 -- the operator names the CA file on the command line
		if err != nil {
			return nil, fmt.Errorf("-ca-file: %w", err)
		}
		pool, err := x509.SystemCertPool()
		if err != nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("-ca-file %s: no PEM certificates", caFile)
		}
		t.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	if http1 {
		t.ForceAttemptHTTP2 = false
		t.Protocols = new(http.Protocols)
		t.Protocols.SetHTTP1(true)
	}
	return t, nil
}

// Level says whether Relay refuses a target that fails the case (hard) or works around it (soft).
type Level string

const (
	Hard Level = "hard"
	Soft Level = "soft"
)

// Status is a case outcome as written to the report.
type Status string

const (
	Pass        Status = "pass"
	Fail        Status = "fail"
	Unsupported Status = "unsupported"
	Skipped     Status = "skipped"
	NotRun      Status = "not run"
)

type caseDef struct {
	ID    string
	Name  string
	Level Level
	Run   func(c *C)
}

type result struct {
	caseDef
	Status   Status
	Duration time.Duration
	Notes    []string
	Errors   []string
}

// abort unwinds a case from Fatalf, Unsupported, and Skip. The runner recovers it.
type abort struct{}

// C is the handle a case gets. It records into the report instead of failing the Go test directly,
// so soft cases can fail without failing the run and every failure carries a sanitized trace.
type C struct {
	s        *suite
	ctx      context.Context
	res      *result
	rec      *recorder
	cleanups []func(context.Context) error
}

func (c *C) Ctx() context.Context { return c.ctx }

// Notef records an observation in the report, whatever the outcome.
func (c *C) Notef(format string, args ...any) {
	c.res.Notes = append(c.res.Notes, fmt.Sprintf(format, args...))
}

// Errorf records a failure and lets the case continue.
func (c *C) Errorf(format string, args ...any) {
	c.res.Errors = append(c.res.Errors, fmt.Sprintf(format, args...))
}

// Fatalf records a failure and stops the case.
func (c *C) Fatalf(format string, args ...any) {
	c.Errorf(format, args...)
	panic(abort{})
}

// Unsupported marks the case as not implemented by the target and stops it.
func (c *C) Unsupported(format string, args ...any) {
	c.res.Status = Unsupported
	c.Notef(format, args...)
	panic(abort{})
}

// Skip marks the case as deliberately not run (for example, it needs a flag) and stops it.
func (c *C) Skip(format string, args ...any) {
	c.res.Status = Skipped
	c.Notef(format, args...)
	panic(abort{})
}

// Must stops the case if err is not nil.
func (c *C) Must(err error, what string) {
	if err != nil {
		c.Fatalf("%s: %s", what, describeErr(err))
	}
}

// Cleanup registers work to run after the case, outside its timing.
func (c *C) Cleanup(fn func(context.Context) error) { c.cleanups = append(c.cleanups, fn) }

// Key returns a key unique to this run and case.
func (c *C) Key(name string) string { return c.s.prefix + c.res.ID + "/" + name }

type suite struct {
	endpoint     *url.URL
	bucket       string
	prefix       string
	s3           *s3.Client
	presign      *s3.PresignClient
	http         *http.Client // recording, unsigned; used for presigned URLs and anonymous requests
	redactor     *redactor
	started      time.Time
	results      []*result
	createdBkt   bool
	listFixture  *listFixture
	checksumMode string
}

var (
	current  *suite
	setupErr error
)

var targetName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,62}$`)

func newSuite(ctx context.Context) (*suite, *recorder, error) {
	ep, err := url.Parse(*flagEndpoint)
	if err != nil || ep.Host == "" || (ep.Scheme != "http" && ep.Scheme != "https") {
		return nil, nil, fmt.Errorf("-endpoint must be an http(s) URL, got %q", *flagEndpoint)
	}
	if *flagBucket == "" {
		return nil, nil, errors.New("-bucket is required")
	}
	if *flagTarget != "" && !targetName.MatchString(*flagTarget) {
		return nil, nil, fmt.Errorf("-target must match %s", targetName)
	}
	if *flagListObjects <= 1000 {
		return nil, nil, errors.New("-list-objects must be more than 1000")
	}
	var checksum aws.RequestChecksumCalculation
	switch *flagChecksums {
	case "when_supported":
		checksum = aws.RequestChecksumCalculationWhenSupported
	case "when_required":
		checksum = aws.RequestChecksumCalculationWhenRequired
	default:
		return nil, nil, fmt.Errorf("-sdk-checksums must be when_supported or when_required, got %q", *flagChecksums)
	}

	// Credentials come from the standard AWS chain (environment, shared config/profile), never from flags,
	// so they do not end up in shell history or CI logs.
	rd := &redactor{}
	base, err := baseTransport(*flagCAFile, *flagHTTP1)
	if err != nil {
		return nil, nil, err
	}
	httpClient := &http.Client{
		Transport: &recordingTransport{base: base, redactor: rd},
		Timeout:   2 * time.Minute,
	}
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(*flagRegion), config.WithHTTPClient(httpClient))
	if err != nil {
		return nil, nil, fmt.Errorf("load AWS config: %w", err)
	}
	creds, err := cfg.Credentials.Retrieve(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("no S3 credentials (set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or AWS_PROFILE): %w", err)
	}
	rd.add(creds.AccessKeyID, creds.SecretAccessKey, creds.SessionToken)

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(strings.TrimRight(ep.String(), "/"))
		o.UsePathStyle = *flagPathStyle
		o.RequestChecksumCalculation = checksum
		o.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
	})
	prefix := *flagPrefix
	if prefix == "" {
		prefix = "relay-conformance/" + time.Now().UTC().Format("20060102T150405Z") + "-" + randomHex(3) + "/"
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	s := &suite{
		endpoint: ep, bucket: *flagBucket, prefix: prefix, s3: client, presign: s3.NewPresignClient(client),
		http: httpClient, redactor: rd, started: time.Now(), checksumMode: *flagChecksums,
	}

	rec := &recorder{}
	ctx = withRecorder(ctx, rec)
	if _, err := client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: &s.bucket}); err != nil {
		if httpStatus(err) != http.StatusNotFound || !*flagCreateBucket {
			return s, rec, fmt.Errorf("bucket %q is not usable: %s", s.bucket, describeErr(err))
		}
		if _, err := client.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: &s.bucket}); err != nil {
			return s, rec, fmt.Errorf("create bucket %q: %s", s.bucket, describeErr(err))
		}
		s.createdBkt = true
	}
	return s, rec, nil
}

// TestS3Conformance runs every case against -endpoint, in the order of the cases table.
func TestS3Conformance(t *testing.T) {
	if *flagEndpoint == "" {
		t.Skip("no -endpoint: skipping the S3 conformance cases (see conformance/s3/README.md)")
	}
	ctx := context.Background()
	s, rec, err := newSuite(ctx)
	current, setupErr = s, err
	if err != nil {
		if rec != nil {
			t.Log(rec.dump())
		}
		t.Fatal(err)
	}
	for _, def := range cases {
		t.Run(def.ID+"_"+slug(def.Name), func(t *testing.T) { s.run(t, def) })
	}
}

func (s *suite) run(t *testing.T, def caseDef) {
	res := &result{caseDef: def}
	s.results = append(s.results, res)
	rec := &recorder{}
	ctx, cancel := context.WithTimeout(withRecorder(context.Background(), rec), 5*time.Minute)
	defer cancel()
	c := &C{s: s, ctx: ctx, res: res, rec: rec}

	start := time.Now()
	func() {
		defer func() {
			if r := recover(); r != nil {
				if _, ok := r.(abort); !ok {
					c.Errorf("panic: %v\n%s", r, debug.Stack())
				}
			}
		}()
		def.Run(c)
	}()
	res.Duration = time.Since(start)

	cleanupCtx, cancelCleanup := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancelCleanup()
	for i := len(c.cleanups) - 1; i >= 0; i-- {
		if err := c.cleanups[i](cleanupCtx); err != nil {
			t.Logf("cleanup: %s", describeErr(err))
		}
	}

	if len(res.Errors) > 0 {
		res.Status = Fail
	} else if res.Status == "" {
		res.Status = Pass
	}
	for _, n := range res.Notes {
		t.Logf("note: %s", n)
	}
	switch res.Status {
	case Fail, Unsupported:
		t.Logf("sanitized requests and responses for %s (%s):\n%s", def.ID, res.Status, rec.dump())
		for _, e := range res.Errors {
			t.Logf("error: %s", s.redactor.text(e))
		}
		if def.Level == Hard || *flagStrict {
			t.Errorf("%s %s: %s", strings.ToUpper(string(def.Level)), strings.ToUpper(string(res.Status)), def.Name)
		} else {
			t.Logf("SOFT %s (does not fail the run): %s", strings.ToUpper(string(res.Status)), def.Name)
		}
	case Skipped:
		t.Skip(strings.Join(res.Notes, "; "))
	}
}

// sweep deletes everything under the run prefix and aborts leftover multipart uploads.
func (s *suite) sweep(ctx context.Context) error {
	if *flagKeep {
		return nil
	}
	var errs []error
	uploads := s3.NewListMultipartUploadsPaginator(s.s3, &s3.ListMultipartUploadsInput{Bucket: &s.bucket, Prefix: &s.prefix})
	for uploads.HasMorePages() {
		page, err := uploads.NextPage(ctx)
		if err != nil {
			errs = append(errs, err)
			break
		}
		for _, u := range page.Uploads {
			if _, err := s.s3.AbortMultipartUpload(ctx, &s3.AbortMultipartUploadInput{Bucket: &s.bucket, Key: u.Key, UploadId: u.UploadId}); err != nil {
				errs = append(errs, err)
			}
		}
	}
	if err := s.deletePrefix(ctx, s.prefix); err != nil {
		errs = append(errs, err)
	}
	if s.createdBkt && len(errs) == 0 {
		if _, err := s.s3.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: &s.bucket}); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (s *suite) deletePrefix(ctx context.Context, prefix string) error {
	pages := s3.NewListObjectsV2Paginator(s.s3, &s3.ListObjectsV2Input{Bucket: &s.bucket, Prefix: &prefix})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return err
		}
		if len(page.Contents) == 0 {
			continue
		}
		ids := make([]types.ObjectIdentifier, 0, len(page.Contents))
		for _, o := range page.Contents {
			ids = append(ids, types.ObjectIdentifier{Key: o.Key})
		}
		out, err := s.s3.DeleteObjects(ctx, &s3.DeleteObjectsInput{Bucket: &s.bucket, Delete: &types.Delete{Objects: ids, Quiet: aws.Bool(true)}})
		if err == nil && len(out.Errors) == 0 {
			continue
		}
		// Fall back to one DELETE per object.
		for _, id := range ids {
			if _, err := s.s3.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &s.bucket, Key: id.Key}); err != nil {
				return err
			}
		}
	}
	return nil
}

func TestMain(m *testing.M) {
	flag.Parse()
	code := m.Run()
	if s := current; s != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		if err := s.sweep(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "cleanup of %s failed: %s\n", s.prefix, s.redactor.text(describeErr(err)))
		}
		cancel()
		if path, err := s.writeReport(setupErr); err != nil {
			fmt.Fprintf(os.Stderr, "report: %v\n", err)
			code = 1
		} else if path != "" {
			fmt.Printf("report written to %s\n", path)
		}
	}
	os.Exit(code)
}

// --- helpers shared by the cases ---------------------------------------------------------------------

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func randomHex(n int) string { return hex.EncodeToString(randomBytes(n)) }

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func slug(s string) string {
	s = strings.ToLower(s)
	s = regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(s, "-")
	return strings.Trim(s, "-")
}

// put uploads body with the SDK. Objects are removed by the final sweep.
func (c *C) put(key string, body []byte, in s3.PutObjectInput) *s3.PutObjectOutput {
	in.Bucket, in.Key = &c.s.bucket, &key
	in.Body = bytes.NewReader(body)
	in.ContentLength = aws.Int64(int64(len(body)))
	out, err := c.s.s3.PutObject(c.ctx, &in)
	c.Must(err, "PutObject "+key)
	return out
}

// raw sends a presigned GET or HEAD with extra (unsigned) headers so the case sees the raw status and
// headers, as an HTTP client of the storage origin would.
func (c *C) raw(method, key string, hdr map[string]string) (*http.Response, []byte) {
	in := &s3.GetObjectInput{Bucket: &c.s.bucket, Key: &key}
	var (
		req *http.Request
		err error
	)
	switch method {
	case http.MethodGet:
		p, perr := c.s.presign.PresignGetObject(c.ctx, in, s3.WithPresignExpires(15*time.Minute))
		c.Must(perr, "presign GET")
		req, err = http.NewRequestWithContext(c.ctx, method, p.URL, nil)
	case http.MethodHead:
		p, perr := c.s.presign.PresignHeadObject(c.ctx, &s3.HeadObjectInput{Bucket: &c.s.bucket, Key: &key}, s3.WithPresignExpires(15*time.Minute))
		c.Must(perr, "presign HEAD")
		req, err = http.NewRequestWithContext(c.ctx, method, p.URL, nil)
	default:
		c.Fatalf("raw: unsupported method %s", method)
	}
	c.Must(err, "build request")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	return c.do(req)
}

func (c *C) do(req *http.Request) (*http.Response, []byte) {
	resp, err := c.s.http.Do(req)
	c.Must(err, req.Method+" request")
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	c.Must(err, "read body")
	return resp, body
}

// objectURL is the unsigned URL of key, in the configured addressing style.
func (s *suite) objectURL(key string) string {
	u := *s.endpoint
	if *flagPathStyle {
		u.Path = strings.TrimRight(u.Path, "/") + "/" + s.bucket + "/" + key
	} else {
		u.Host = s.bucket + "." + u.Host
		u.Path = strings.TrimRight(u.Path, "/") + "/" + key
	}
	return u.String()
}

func httpStatus(err error) int {
	var re *awshttp.ResponseError
	if errors.As(err, &re) {
		return re.HTTPStatusCode()
	}
	return 0
}

func errorCode(err error) string {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		return ae.ErrorCode()
	}
	return ""
}

// isNotImplemented reports whether err says the target does not implement an API.
func isNotImplemented(err error) bool {
	switch errorCode(err) {
	case "NotImplemented", "NotSupported", "UnsupportedOperation", "MethodNotAllowed", "XNotImplemented":
		return true
	}
	switch httpStatus(err) {
	case http.StatusNotImplemented, http.StatusMethodNotAllowed:
		return true
	}
	return false
}

func describeErr(err error) string {
	if err == nil {
		return ""
	}
	var ae smithy.APIError
	if errors.As(err, &ae) {
		return fmt.Sprintf("HTTP %d %s: %s", httpStatus(err), ae.ErrorCode(), ae.ErrorMessage())
	}
	return err.Error()
}

func trimQuotes(s string) string { return strings.Trim(s, `"`) }
