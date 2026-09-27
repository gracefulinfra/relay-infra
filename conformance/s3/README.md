# S3 conformance suite

An "S3-compatible" label is not enough (pitch §6). This suite checks the specific S3 behaviour Relay
depends on. Run it against **every storage target before Relay may use it**, and again before any
infrastructure change that touches storage: a new SeaweedFS version, a new provider, or a gateway or
proxy in front of the bucket. Introduced by P0-06.

It is a Go test package that uses the AWS SDK for Go v2 with a configurable endpoint, so it talks to
the target the same way `relay-api` and the media workers will.

## Quick start

```bash
make conformance-s3                                   # SeaweedFS in Docker, the version platform/seaweedfs deploys
make conformance-s3 ARGS="-target=seaweedfs-4.47"     # ...and write reports/seaweedfs-4.47-<date>.md
make conformance-s3-cluster                           # the SeaweedFS in the k3d cluster (after make up)
make conformance-s3 ARGS="-run=TestS3Conformance/03"  # only the range cases
```

`make conformance-s3` starts `$SEAWEEDFS_IMAGE` (pinned by digest in the `Makefile`) with random
per-run credentials, runs the suite, and removes the container. CI runs the same target in the
`s3-conformance` job on every PR and every push to `main`. The job summary shows the report, and the
`s3-conformance` artifact holds the report and the full `go test -v` log.

## Cases and what Relay requires

**Hard** cases are requirements: if one fails, Relay refuses the target, and the run fails.
**Soft** cases are preferences: a failure or `unsupported` is reported but does not fail the run,
because Relay has a workaround (below). Pass `-strict` to fail on soft cases too. The owner set the
split on 2026-09-27 (P0-06).

| ID | Case | Level | Why Relay needs it | Workaround if a soft case fails |
| --- | --- | --- | --- | --- |
| 01a | Multipart upload: parts out of order, ListParts, complete | hard | Resumable uploads (tus, A17) of multi-GB masters; the ETag and size of each part are checked | |
| 01b | Multipart abort | hard | Cancelled uploads must not leave objects behind | |
| 01c | Find and clean up incomplete uploads (ListMultipartUploads, paged) | hard | The cleanup job that replaces lifecycle rules where they are missing (09b) | |
| 02a | Presigned PUT, with the signed Content-Type enforced | hard | Browser uploads without proxying bytes through the API | |
| 02b | Presigned GET, and a tampered signature is refused | hard | Private previews and downloads | |
| 02c | Presigned URL expiry is enforced for GET and PUT | hard | Short-lived URLs are the access control for private media | |
| 03a–c | `Range` `bytes=0-0`, `bytes=100-`, `bytes=-500`: `206`, `Content-Range`, `Content-Length`, `Accept-Ranges: bytes` on 206 and 200 | hard | Apple and every podcast app seek with byte ranges ([Apple requirements](https://podcasters.apple.com/support/823-podcast-requirements)) | |
| 03d | Several ranges in one request (behaviour recorded) | soft | Not needed: players and the edge send single ranges | The edge forwards only single ranges |
| 03e | A range past the end returns `416` | soft | Correct errors for bad seeks | The edge answers `416` itself from the known length |
| 04 | `HEAD`: `Content-Length`, `Content-Type`, quoted `ETag`, `Last-Modified` (HTTP date, sane clock) | hard | Feed enclosure length and type, and cache validation | |
| 05a–h | `Content-Type` preserved exactly on HEAD and GET for `audio/mpeg`, `audio/mp4`, `video/mp4`, `application/vnd.apple.mpegurl`, `video/iso.segment`, `text/vtt`, `application/json+chapters`, `application/rss+xml` | hard | Apps and browsers trust the served type | |
| 06a–b | `Cache-Control` and `Content-Disposition` (including RFC 5987 `filename*`) round-trip | hard | Immutable versioned media, and download file names | |
| 07a–b | `If-None-Match` and `If-Modified-Since` return `304` | hard | Feed polling and edge revalidation | |
| 08a–b | ListObjectsV2 over more than 1,000 objects: default and explicit `MaxKeys`, continuation tokens, `StartAfter`, prefix and delimiter, paged common prefixes | hard | Inventory, export (P1-20), and cleanup jobs | |
| 09a | Lifecycle rule that expires a prefix | soft | Drafts, previews, and temporary renditions age out | A River periodic job lists the prefix and deletes by age |
| 09b | Lifecycle rule that aborts incomplete multipart uploads | soft | Abandoned uploads stop costing storage | The same periodic job runs the 01c algorithm |
| 10a | Server-side copy, with metadata `COPY` and `REPLACE` | hard | Versioned promotion from masters to delivery keys without re-uploading | |
| 10b | Server-side copy of parts (`UploadPartCopy`) | soft | Copies larger than 5 GiB on targets that enforce AWS's `CopyObject` limit | Stream-copy through a media worker |
| 10c | `x-amz-checksum-sha256` is verified on PUT and returned by HEAD | soft | Storage-side integrity check | Relay computes SHA-256 itself and verifies after upload (rule 5) |
| 11 | Access-log export | soft | Origin-side download evidence | Edge access logs are the download-analytics source (P1-17) |
| 12 | Anonymous GET, HEAD, PUT, and bucket listing are refused | hard | Origins reject anonymous reads and listing; only the edge serves public media (conventions) | |

Case 12 is not in the P0-06 prompt. It comes from the shared conventions ("origins reject anonymous
reads and bucket listing... Test direct-origin and guessed-path access").

What the suite does **not** prove: that lifecycle rules are *enforced* (the shortest period is one
day, so 09 checks only that a rule is accepted and read back), that access logs are *delivered*
(case 11 waits `-access-log-wait`, 30 s by default, and records what it saw), throughput or
durability, or anything about virtual-hosted addressing unless you run it with `-path-style=false`.

## Results and the report

Each case ends as `pass`, `fail`, `unsupported` (the target does not implement it), or `skipped` (it
needs a flag, such as `-allow-bucket-config`). With `-target=<name>`, the suite writes
`reports/<name>-<YYYY-MM-DD>.md`. The report has a verdict, a table with a result and time per case,
and the observations each case recorded, such as how the target answers a multi-range request.
Committed reports are the evidence that a target was accepted; name them after the target and version
(`seaweedfs-4.47`, `provider-a-<service>`).

When a case fails, `go test -v` prints the case's last 12 HTTP exchanges. They are sanitized:
`Authorization` keeps only its structure (`Credential=REDACTED`, `Signature=REDACTED`); session tokens,
cookies, SSE-C keys, presigned-URL signatures and credentials, and the literal access key, secret, and
token are redacted wherever they appear. Object payloads are never printed, only their length. Error
bodies are printed (at most 2 KiB) with the signing details S3 echoes back (`StringToSign`,
`CanonicalRequest`, `AWSAccessKeyId`, `SignatureProvided`) removed. `harness_unit_test.go` tests this.

## Running against a managed S3

Use a **dedicated scratch bucket**. The suite writes only under `-prefix`
(`relay-conformance/<timestamp>-<random>/` by default) and deletes what it wrote at the end (unless
`-keep`). But `-allow-bucket-config` temporarily changes the bucket's lifecycle and logging
configuration. The suite merges its lifecycle rule into the existing rules and restores them, but a
crash mid-run would leave its rule behind.

Credentials come from the standard AWS chain only (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
`AWS_SESSION_TOKEN`, or `AWS_PROFILE`), never from flags, so they stay out of shell history and CI
logs. Give the identity only what the suite needs on the scratch bucket:
`s3:ListBucket`, `s3:ListBucketMultipartUploads`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`,
`s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`, plus `s3:GetLifecycleConfiguration`,
`s3:PutLifecycleConfiguration`, `s3:GetBucketLogging`, and `s3:PutBucketLogging` for
`-allow-bucket-config`.

```bash
export AWS_PROFILE=relay-conformance     # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
go test -count=1 -timeout=20m -v ./conformance/s3 \
  -endpoint=https://<s3 endpoint of the provider and region> \
  -region=<signing region> \
  -path-style=false \
  -bucket=<scratch bucket> \
  -target=<provider>-<service> \
  -allow-bucket-config \
  -access-log-note="<how this provider exports request logs>"
```

- `-endpoint`: the provider's S3 API endpoint for the bucket's region. Use the endpoint, not a CDN
  or website hostname.
- `-path-style=false`: most managed services prefer virtual-hosted addressing. Run it both ways if
  Relay could be configured with either.
- `-region`: the signing region the provider documents. Some providers accept any value or `auto`.
- `-access-log-note`: write down how download logs are obtained on this target (for example a
  bucket-logging API, a provider log-push feature, or only CDN logs). The note goes into the report
  next to case 11's result. Take it from the provider's documentation and cite it in the PR.
- `-sdk-checksums=when_required` reruns with the AWS SDK's pre-2025 behaviour (no CRC32 on every
  request) if a target rejects the SDK's default checksums. Record which mode Relay must use.

Commit the report under `reports/`, and link it from the P0-07 or migration PR. A target is accepted
only when its report says **ACCEPTED**.

## Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `-endpoint` | (none) | S3 endpoint URL. Without it, the conformance cases are skipped |
| `-bucket` | (none) | Bucket to test in |
| `-region` | `us-east-1` | Signing region |
| `-path-style` | `true` | Path-style addressing; `false` uses virtual-hosted style |
| `-target` | (none) | Report name; no report without it |
| `-report-dir` | `reports` | Report directory, relative to this package |
| `-prefix` | `relay-conformance/<run>/` | Key prefix for everything the suite writes |
| `-create-bucket` | `false` | Create `-bucket` if missing, and delete it afterwards |
| `-allow-bucket-config` | `false` | Run the lifecycle (09) and logging (11) configuration checks |
| `-access-log-note` | (none) | How download logs are obtained on this target, for the report |
| `-access-log-wait` | `30s` | How long case 11 waits for a log object |
| `-list-objects` | `1100` | Objects created for the listing cases (more than 1,000) |
| `-sdk-checksums` | `when_supported` | SDK request checksum mode: `when_supported` (SDK default) or `when_required` |
| `-strict` | `false` | Fail the run on soft failures too |
| `-keep` | `false` | Keep the test objects |
| `-ca-file` | (none) | Extra CA certificates (PEM) to trust, for an https endpoint with a private CA |
| `-http1` | `false` | HTTP/1.1 only. By default an https endpoint may negotiate HTTP/2, as the AWS SDK's default transport does |

## Known target behaviour

- **SeaweedFS 4.47** passes every hard case. It has no working S3 bucket-logging API: `GetBucketLogging`
  answers "off", and `PUT ?logging` is routed to CreateBucket (`409 BucketAlreadyOwnedByYou`). Its S3
  gateway can send per-request audit records to Fluentd (`-s3.auditLogConfig`, not exercised by the
  suite). Lifecycle rules are accepted and read back; enforcement was not observed. See the committed
  report for the rest.
- **SeaweedFS 4.47 over HTTPS with HTTP/2** fails cases 07a and 07b (P0-07). Its `304 Not Modified`
  responses carry a `Content-Length` for a body they do not send. HTTP/1.1 clients ignore it, but Go's
  HTTP/2 client (and so the AWS SDK for Go on its default transport) fails the request with
  `unexpected EOF`. P0-06's runs were plain HTTP, so they could not see it. Over HTTPS with `-http1`,
  every hard case passes. Relay's S3 clients must use HTTP/1.1 against SeaweedFS over TLS, or TLS must
  terminate in front of it. Reports: `reports/local-b-seaweedfs-4.47-https-*.md`.
- Unknown bucket sub-resources on SeaweedFS can fall through to other handlers instead of returning
  `501 NotImplemented`. Do not rely on a bucket-level S3 API unless a conformance case covers it.

## Adding a case

Add an entry to `cases` in `cases_test.go` with the next ID in its group, a level, and a function
that takes a `*C`. Use `c.Errorf`/`c.Fatalf` for failures, `c.Unsupported` when the target does not
implement an API, and `c.Notef` for observations worth keeping in the report. Use `c.Key` for object
keys so the final sweep removes them. Update the table above in the same PR.
