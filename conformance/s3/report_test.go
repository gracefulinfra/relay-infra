package s3conformance

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"time"
)

// writeReport writes reports/<target>-<date>.md and returns its path. It writes nothing when
// -report-dir or -target is empty.
func (s *suite) writeReport(setupErr error) (string, error) {
	if *flagReportDir == "" || *flagTarget == "" {
		return "", nil
	}
	if err := os.MkdirAll(*flagReportDir, 0o750); err != nil {
		return "", err
	}
	path := filepath.Join(*flagReportDir, fmt.Sprintf("%s-%s.md", *flagTarget, s.started.UTC().Format("2006-01-02")))
	return path, os.WriteFile(path, []byte(s.render(setupErr)), 0o600)
}

func (s *suite) render(setupErr error) string {
	byID := map[string]*result{}
	for _, r := range s.results {
		byID[r.ID] = r
	}
	all := make([]*result, 0, len(cases))
	for _, def := range cases {
		if r, ok := byID[def.ID]; ok {
			all = append(all, r)
		} else {
			all = append(all, &result{caseDef: def, Status: NotRun})
		}
	}

	var hardFail, softFail, notRun int
	var total time.Duration
	counts := map[Status]int{}
	for _, r := range all {
		counts[r.Status]++
		total += r.Duration
		switch {
		case r.Status == NotRun || (r.Status == Skipped && r.Level == Hard):
			notRun++
		case r.Level == Hard && (r.Status == Fail || r.Status == Unsupported):
			hardFail++
		case r.Level == Soft && (r.Status == Fail || r.Status == Unsupported):
			softFail++
		}
	}
	verdict := "**ACCEPTED**: every hard case passes."
	switch {
	case setupErr != nil:
		verdict = "**INCOMPLETE**: the suite could not start: " + s.redactor.text(setupErr.Error())
	case hardFail > 0:
		verdict = fmt.Sprintf("**REJECTED**: %d hard case(s) fail. Relay must not use this target until they pass.", hardFail)
	case notRun > 0:
		verdict = fmt.Sprintf("**INCOMPLETE**: %d hard case(s) did not run, so this report cannot accept the target.", notRun)
	}
	if setupErr == nil && hardFail == 0 && softFail > 0 {
		verdict += fmt.Sprintf(" %d soft case(s) fail or are unsupported; Relay uses the documented workaround for each.", softFail)
	}

	var b strings.Builder
	w := func(format string, args ...any) { fmt.Fprintf(&b, format, args...) }
	w("# S3 conformance report: %s\n\n", *flagTarget)
	w("%s\n\n", verdict)
	w("| | |\n| --- | --- |\n")
	w("| Target | `%s` |\n", *flagTarget)
	w("| Run at | %s |\n", s.started.UTC().Format(time.RFC3339))
	w("| Endpoint | `%s://%s` (%s addressing) |\n", s.endpoint.Scheme, s.redactor.text(s.endpoint.Host), addressing())
	w("| HTTP | %s |\n", httpMode(s.endpoint.Scheme))
	w("| Bucket | `%s` |\n", s.bucket)
	w("| Region | `%s` |\n", *flagRegion)
	w("| SDK request checksums | `%s` |\n", s.checksumMode)
	w("| Bucket-config cases | %s |\n", enabled(*flagAllowBucketConfig))
	w("| Suite revision | `%s` |\n", suiteRevision())
	w("| Go / SDK | %s |\n", toolVersions())
	w("| Results | %d pass, %d fail, %d unsupported, %d skipped, %d not run; total time %s |\n\n",
		counts[Pass], counts[Fail], counts[Unsupported], counts[Skipped], counts[NotRun], total.Round(time.Millisecond))

	w("| ID | Case | Level | Result | Time |\n| --- | --- | --- | --- | ---: |\n")
	for _, r := range all {
		w("| %s | %s | %s | %s | %s |\n", r.ID, r.Name, r.Level, badge(r), duration(r))
	}

	w("\n## Observations\n\n")
	w("Notes and failure messages recorded by each case. The sanitized HTTP traces for failures are in the `go test -v` output.\n")
	for _, r := range all {
		if len(r.Notes) == 0 && len(r.Errors) == 0 {
			continue
		}
		w("\n### %s %s\n\n", r.ID, r.Name)
		for _, e := range r.Errors {
			w("- **Error:** %s\n", oneLine(s.redactor.text(e)))
		}
		for _, n := range r.Notes {
			w("- %s\n", oneLine(s.redactor.text(n)))
		}
	}
	return b.String()
}

func badge(r *result) string {
	switch r.Status {
	case Pass:
		return "pass"
	case Fail:
		return "**FAIL**"
	case Unsupported:
		if r.Level == Hard {
			return "**UNSUPPORTED**"
		}
		return "unsupported"
	}
	return string(r.Status)
}

func duration(r *result) string {
	if r.Status == NotRun {
		return ""
	}
	if r.Duration < time.Second {
		return fmt.Sprintf("%d ms", r.Duration.Milliseconds())
	}
	return fmt.Sprintf("%.2f s", r.Duration.Seconds())
}

func addressing() string {
	if *flagPathStyle {
		return "path-style"
	}
	return "virtual-hosted"
}

func enabled(b bool) string {
	if b {
		return "enabled (`-allow-bucket-config`)"
	}
	return "disabled"
}

func oneLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, "\n"); i >= 0 {
		s = s[:i] + " …"
	}
	return strings.ReplaceAll(s, "|", `\|`)
}

func suiteRevision() string {
	out, err := exec.Command("git", "describe", "--always", "--dirty", "--abbrev=12").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}

func toolVersions() string {
	parts := []string{runtime.Version()}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			switch dep.Path {
			case "github.com/aws/aws-sdk-go-v2", "github.com/aws/aws-sdk-go-v2/service/s3":
				parts = append(parts, fmt.Sprintf("`%s` %s", strings.TrimPrefix(dep.Path, "github.com/aws/"), dep.Version))
			}
		}
	}
	return strings.Join(parts, ", ")
}

// httpMode describes the protocol the suite's clients used.
func httpMode(scheme string) string {
	switch {
	case *flagHTTP1:
		return "HTTP/1.1 only (`-http1`)"
	case scheme == "https":
		return "HTTP/2 when the server offers it (ALPN), as the AWS SDK's default transport does"
	default:
		return "HTTP/1.1 (plain HTTP)"
	}
}
