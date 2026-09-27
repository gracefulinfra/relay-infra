package s3conformance

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// These tests cover the harness itself and need no S3 endpoint.

// Fake credentials in the documented AWS example format; they only exercise the redactor.
const (
	testAccessKey = "AKIDEXAMPLERELAY01"
	testSecret    = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" // #nosec G101 -- fake
	testToken     = "FwoGZXIvYXdzEXAMPLESESSIONTOKEN"          // #nosec G101 -- fake
)

func TestRedactorHeader(t *testing.T) {
	r := &redactor{}
	r.add(testAccessKey, testSecret, testToken)
	tests := []struct {
		name, header, value, want string
	}{
		{"sigv4 authorization keeps only the structure", "Authorization",
			"AWS4-HMAC-SHA256 Credential=" + testAccessKey + "/20260927/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=0123abcdef",
			"AWS4-HMAC-SHA256 Credential=REDACTED, SignedHeaders=host;x-amz-date, Signature=REDACTED"},
		{"other authorization schemes are dropped", "authorization", "Bearer eyJhbGciOi", "REDACTED"},
		{"session token", "X-Amz-Security-Token", testToken, "REDACTED"},
		{"cookie", "Cookie", "session=abc", "REDACTED"},
		{"set-cookie", "Set-Cookie", "session=abc; HttpOnly", "REDACTED"},
		{"SSE-C key", "X-Amz-Server-Side-Encryption-Customer-Key", "c2VjcmV0", "REDACTED"},
		{"secret anywhere else", "X-Debug", "echo " + testSecret, "echo REDACTED"},
		{"ordinary header untouched", "Content-Type", "audio/mpeg", "audio/mpeg"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := r.header(tt.header, tt.value); got != tt.want {
				t.Errorf("header(%q) = %q, want %q", tt.header, got, tt.want)
			}
		})
	}
}

func TestRedactorURL(t *testing.T) {
	r := &redactor{}
	r.add(testAccessKey, testSecret, testToken)
	u, _ := url.Parse("https://user:pass@s3.example.test/bucket/key.mp3?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
		"&X-Amz-Credential=" + url.QueryEscape(testAccessKey+"/20260927/us-east-1/s3/aws4_request") +
		"&X-Amz-Date=20260927T000000Z&X-Amz-Expires=900&X-Amz-Security-Token=" + url.QueryEscape(testToken) +
		"&X-Amz-SignedHeaders=host&X-Amz-Signature=0123abcdef&token=private-feed-token")
	got := r.url(u)
	for _, leak := range []string{testAccessKey, testToken, "0123abcdef", "private-feed-token", "pass"} {
		if strings.Contains(got, leak) {
			t.Errorf("url() leaks %q: %s", leak, got)
		}
	}
	for _, keep := range []string{"s3.example.test/bucket/key.mp3", "X-Amz-Expires=900", "X-Amz-SignedHeaders=host"} {
		if !strings.Contains(got, keep) {
			t.Errorf("url() dropped %q: %s", keep, got)
		}
	}
}

func TestRedactorErrorBody(t *testing.T) {
	r := &redactor{}
	r.add(testAccessKey, testSecret)
	body := `<?xml version="1.0"?><Error><Code>SignatureDoesNotMatch</Code><AWSAccessKeyId>` + testAccessKey +
		`</AWSAccessKeyId><StringToSign>AWS4-HMAC-SHA256
20260927T000000Z</StringToSign><SignatureProvided>0123abcdef</SignatureProvided>` +
		`<CanonicalRequest>GET /bucket/key</CanonicalRequest><RequestId>tx01</RequestId></Error>`
	got := r.text(body)
	for _, leak := range []string{testAccessKey, "20260927T000000Z", "0123abcdef", "GET /bucket/key"} {
		if strings.Contains(got, leak) {
			t.Errorf("text() leaks %q: %s", leak, got)
		}
	}
	if !strings.Contains(got, "<Code>SignatureDoesNotMatch</Code>") || !strings.Contains(got, "<RequestId>tx01</RequestId>") {
		t.Errorf("text() dropped the diagnosable parts: %s", got)
	}
}

func TestRedactorIgnoresShortValues(t *testing.T) {
	r := &redactor{}
	r.add("", "abc")
	if got := r.text("abc def"); got != "abc def" {
		t.Errorf("short values must not be treated as secrets, got %q", got)
	}
}

// TestRecordingTransportDump checks the trace printed for a failing case: signed request details,
// payloads, and echoed credentials are gone, and the status, headers, and error code remain.
func TestRecordingTransportDump(t *testing.T) {
	const payload = "PRIVATE-MASTER-AUDIO-BYTES"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/bucket/ok.mp3" {
			w.Header().Set("Content-Type", "audio/mpeg")
			_, _ = io.WriteString(w, payload)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		w.Header().Set("Set-Cookie", "srv=1")
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, `<Error><Code>AccessDenied</Code><AWSAccessKeyId>`+testAccessKey+`</AWSAccessKeyId></Error>`)
	}))
	defer srv.Close()

	rd := &redactor{}
	rd.add(testAccessKey, testSecret, testToken)
	client := &http.Client{Transport: &recordingTransport{base: http.DefaultTransport, redactor: rd}}
	rec := &recorder{}
	ctx := withRecorder(context.Background(), rec)

	send := func(method, path, body string) {
		t.Helper()
		req, _ := http.NewRequestWithContext(ctx, method, srv.URL+path+"?X-Amz-Signature=deadbeef&X-Amz-Credential="+testAccessKey, strings.NewReader(body))
		req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+testAccessKey+"/x, SignedHeaders=host, Signature=cafe01")
		req.Header.Set("X-Amz-Security-Token", testToken)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if path == "/bucket/ok.mp3" && string(got) != payload {
			t.Fatalf("the transport altered the response body: %q", got)
		}
		if resp.StatusCode == http.StatusForbidden && !strings.Contains(string(got), "AccessDenied") {
			t.Fatalf("the transport consumed the error body: %q", got)
		}
	}
	send(http.MethodPut, "/bucket/ok.mp3", payload)
	send(http.MethodGet, "/bucket/ok.mp3", "")
	send(http.MethodGet, "/bucket/denied.mp3", "")

	dump := rec.dump()
	for _, leak := range []string{testAccessKey, testSecret, testToken, "deadbeef", "cafe01", payload, "srv=1"} {
		if strings.Contains(dump, leak) {
			t.Errorf("dump leaks %q:\n%s", leak, dump)
		}
	}
	for _, want := range []string{"> PUT ", "[body: 26 bytes, not shown]", "< 403 Forbidden", "<Code>AccessDenied</Code>", "Content-Type: audio/mpeg"} {
		if !strings.Contains(dump, want) {
			t.Errorf("dump is missing %q:\n%s", want, dump)
		}
	}
}

func TestRecorderKeepsRecentExchanges(t *testing.T) {
	rec := &recorder{}
	for i := range maxExchanges + 3 {
		rec.add(strings.Repeat("x", i+1))
	}
	dump := rec.dump()
	if !strings.Contains(dump, "3 earlier exchanges omitted") || strings.Contains(dump, "\nx\n") {
		t.Errorf("unexpected dump:\n%s", dump)
	}
}

func TestReportVerdict(t *testing.T) {
	defs := cases
	t.Cleanup(func() { cases = defs })
	cases = []caseDef{{ID: "01", Name: "hard case", Level: Hard}, {ID: "02", Name: "soft case", Level: Soft}}
	ep, _ := url.Parse("http://127.0.0.1:8333")
	rd := &redactor{}
	rd.add(testSecret)

	tests := []struct {
		name     string
		results  []*result
		setupErr error
		want     []string
	}{
		{"all pass", []*result{{caseDef: cases[0], Status: Pass}, {caseDef: cases[1], Status: Pass}}, nil,
			[]string{"**ACCEPTED**", "| 01 | hard case | hard | pass |"}},
		{"soft failure still accepts", []*result{{caseDef: cases[0], Status: Pass}, {caseDef: cases[1], Status: Unsupported, Notes: []string{"no API"}}}, nil,
			[]string{"**ACCEPTED**", "1 soft case(s) fail or are unsupported", "| 02 | soft case | soft | unsupported |", "- no API"}},
		{"hard failure rejects", []*result{{caseDef: cases[0], Status: Fail, Errors: []string{"status 200, want 206"}}, {caseDef: cases[1], Status: Pass}}, nil,
			[]string{"**REJECTED**", "**FAIL**", "- **Error:** status 200, want 206"}},
		{"hard unsupported rejects", []*result{{caseDef: cases[0], Status: Unsupported}, {caseDef: cases[1], Status: Pass}}, nil,
			[]string{"**REJECTED**", "**UNSUPPORTED**"}},
		{"missing hard case is incomplete", []*result{{caseDef: cases[1], Status: Pass}}, nil,
			[]string{"**INCOMPLETE**", "| 01 | hard case | hard | not run |"}},
		{"setup failure is incomplete and redacted", nil, errors.New("bad credentials " + testSecret),
			[]string{"**INCOMPLETE**: the suite could not start: bad credentials REDACTED"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &suite{endpoint: ep, bucket: "b", redactor: rd, results: tt.results, started: time.Now(), checksumMode: "when_supported"}
			got := s.render(tt.setupErr)
			for _, w := range tt.want {
				if !strings.Contains(got, w) {
					t.Errorf("report is missing %q:\n%s", w, got)
				}
			}
			if strings.Contains(got, testSecret) {
				t.Errorf("report leaks the secret")
			}
		})
	}
}

func TestCaseIDsAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range cases {
		if seen[c.ID] {
			t.Errorf("duplicate case ID %s", c.ID)
		}
		seen[c.ID] = true
		if c.Level != Hard && c.Level != Soft {
			t.Errorf("case %s has level %q", c.ID, c.Level)
		}
	}
}
