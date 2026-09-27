package s3conformance

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync"
)

// The recording transport keeps a sanitized copy of every request and response a case makes, and
// prints it when the case fails. Nothing secret reaches the log: credentials, signatures, tokens, and
// cookies are redacted, and object payloads are never printed (only their length). Error bodies from
// the server are printed, truncated, after redacting the signing details that S3 echoes back.

const (
	maxExchanges = 12   // per case, most recent kept
	maxErrorBody = 2048 // bytes of an error response body to show
)

type recorderKey struct{}

func withRecorder(ctx context.Context, r *recorder) context.Context {
	return context.WithValue(ctx, recorderKey{}, r)
}

type recorder struct {
	mu      sync.Mutex
	entries []string
	dropped int
}

func (r *recorder) add(entry string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entries = append(r.entries, entry)
	if len(r.entries) > maxExchanges {
		r.entries = r.entries[1:]
		r.dropped++
	}
}

func (r *recorder) dump() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.entries) == 0 {
		return "  (no HTTP exchanges)"
	}
	var b strings.Builder
	if r.dropped > 0 {
		fmt.Fprintf(&b, "  (%d earlier exchanges omitted)\n", r.dropped)
	}
	b.WriteString(strings.Join(r.entries, "\n"))
	return b.String()
}

type recordingTransport struct {
	base     http.RoundTripper
	redactor *redactor
}

func (t *recordingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	rec, _ := req.Context().Value(recorderKey{}).(*recorder)
	resp, err := t.base.RoundTrip(req)
	if rec == nil {
		return resp, err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  > %s %s\n", req.Method, t.redactor.url(req.URL))
	writeHeaders(&b, "  > ", req.Header, t.redactor)
	fmt.Fprintf(&b, "  > [body: %s]\n", bodySize(req.ContentLength))
	if err != nil {
		fmt.Fprintf(&b, "  < transport error: %s", t.redactor.text(err.Error()))
		rec.add(b.String())
		return resp, err
	}
	fmt.Fprintf(&b, "  < %s\n", resp.Status)
	writeHeaders(&b, "  < ", resp.Header, t.redactor)
	if req.Method != http.MethodHead && resp.StatusCode >= 300 && isTextual(resp.Header.Get("Content-Type"), resp.ContentLength) {
		head, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
		resp.Body = struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(head), resp.Body), resp.Body}
		fmt.Fprintf(&b, "  < [body, first %d bytes, redacted]: %s", len(head), t.redactor.text(string(head)))
	} else if req.Method == http.MethodHead {
		b.WriteString("  < [no body: HEAD]")
	} else {
		fmt.Fprintf(&b, "  < [body: %s]", bodySize(resp.ContentLength))
	}
	rec.add(b.String())
	return resp, nil
}

func bodySize(n int64) string {
	if n < 0 {
		return "unknown length, not shown"
	}
	return fmt.Sprintf("%d bytes, not shown", n)
}

func isTextual(contentType string, length int64) bool {
	if length == 0 {
		return false
	}
	ct := strings.ToLower(contentType)
	return ct == "" || strings.Contains(ct, "xml") || strings.Contains(ct, "json") || strings.HasPrefix(ct, "text/")
}

func writeHeaders(b *strings.Builder, prefix string, h http.Header, r *redactor) {
	names := make([]string, 0, len(h))
	for name := range h {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		for _, v := range h[name] {
			fmt.Fprintf(b, "%s%s: %s\n", prefix, name, r.header(name, v))
		}
	}
}

// redactor removes secrets from anything the suite prints or writes to the report.
type redactor struct {
	mu      sync.Mutex
	secrets []string
}

const redacted = "REDACTED"

func (r *redactor) add(values ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, v := range values {
		// Very short values would redact ordinary text; real keys are far longer.
		if len(v) >= 8 {
			r.secrets = append(r.secrets, v)
		}
	}
}

var (
	sigV4Credential = regexp.MustCompile(`Credential=[^,\s]+`)
	sigV4Signature  = regexp.MustCompile(`Signature=[0-9A-Fa-f]+`)
	// Elements S3 echoes back in SignatureDoesNotMatch and similar errors.
	sensitiveXML   = regexp.MustCompile(`(?s)<(AWSAccessKeyId|StringToSign|StringToSignBytes|CanonicalRequest|CanonicalRequestBytes|SignatureProvided)>.*?</(AWSAccessKeyId|StringToSign|StringToSignBytes|CanonicalRequest|CanonicalRequestBytes|SignatureProvided)>`)
	sensitiveQuery = []string{
		"x-amz-credential", "x-amz-signature", "x-amz-security-token", "signature", "awsaccesskeyid",
		"x-amz-server-side-encryption-customer-key", "token",
	}
	sensitiveHeaders = map[string]bool{
		"cookie": true, "set-cookie": true, "proxy-authorization": true, "x-amz-security-token": true,
		"x-amz-server-side-encryption-customer-key":             true,
		"x-amz-server-side-encryption-customer-key-md5":         true,
		"x-amz-copy-source-server-side-encryption-customer-key": true,
	}
)

func (r *redactor) header(name, value string) string {
	switch n := strings.ToLower(name); {
	case n == "authorization":
		if !strings.HasPrefix(value, "AWS4-") {
			return redacted
		}
		value = sigV4Credential.ReplaceAllString(value, "Credential="+redacted)
		value = sigV4Signature.ReplaceAllString(value, "Signature="+redacted)
		return r.text(value)
	case sensitiveHeaders[n]:
		return redacted
	}
	return r.text(value)
}

func (r *redactor) url(u *url.URL) string {
	c := *u
	c.User = nil
	q := c.Query()
	for name := range q {
		if slices.Contains(sensitiveQuery, strings.ToLower(name)) {
			q.Set(name, redacted)
		}
	}
	c.RawQuery = q.Encode()
	return r.text(c.String())
}

func (r *redactor) text(s string) string {
	s = sensitiveXML.ReplaceAllString(s, "<$1>"+redacted+"</$1>")
	s = sigV4Signature.ReplaceAllString(s, "Signature="+redacted)
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, secret := range r.secrets {
		s = strings.ReplaceAll(s, secret, redacted)
		s = strings.ReplaceAll(s, url.QueryEscape(secret), redacted)
	}
	return s
}
