// Package s3conformance checks that an S3 implementation behaves the way Relay needs before Relay is
// allowed to use it (P0-06). The suite lives in the package's tests:
//
//	go test ./conformance/s3 -endpoint=http://localhost:8333 -bucket=relay-conformance -target=seaweedfs
//
// Without -endpoint the conformance cases are skipped and only the harness's own unit tests run.
// See README.md for the cases, which of them are required, and how to run against a managed S3.
package s3conformance
