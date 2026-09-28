# S3 conformance report: local-b-seaweedfs-4.47-https-h2

**REJECTED**: 2 hard case(s) fail. Relay must not use this target until they pass.

| | |
| --- | --- |
| Target | `local-b-seaweedfs-4.47-https-h2` |
| Run at | 2026-09-27T20:26:30Z |
| Endpoint | `https://localhost:18443` (path-style addressing) |
| HTTP | HTTP/2 when the server offers it (ALPN), as the AWS SDK's default transport does |
| Bucket | `relay-conformance-1790540789` |
| Region | `us-east-1` |
| SDK request checksums | `when_supported` |
| Bucket-config cases | enabled (`-allow-bucket-config`) |
| Suite revision | `884903347acf` |
| Go / SDK | go1.27.1, `aws-sdk-go-v2` v1.47.1, `aws-sdk-go-v2/service/s3` v1.113.4 |
| Results | 30 pass, 2 fail, 1 unsupported, 0 skipped, 0 not run; total time 5.938s |

| ID | Case | Level | Result | Time |
| --- | --- | --- | --- | ---: |
| 01a | Multipart: parts uploaded out of order, list parts, complete | hard | pass | 450 ms |
| 01b | Multipart: abort | hard | pass | 49 ms |
| 01c | Multipart: find and clean up incomplete uploads | hard | pass | 8 ms |
| 02a | Presigned PUT | hard | pass | 2 ms |
| 02b | Presigned GET | hard | pass | 3 ms |
| 02c | Presigned URL expiry is enforced | hard | pass | 5.01 s |
| 03a | Range bytes=0-0 | hard | pass | 13 ms |
| 03b | Range bytes=100- (open-ended) | hard | pass | 1 ms |
| 03c | Range bytes=-500 (suffix) | hard | pass | 1 ms |
| 03d | Range with several ranges (behaviour recorded) | soft | pass | 1 ms |
| 03e | Range past the end returns 416 | soft | pass | 1 ms |
| 04 | HEAD returns Content-Length, Content-Type, ETag, Last-Modified | hard | pass | 3 ms |
| 05a | Content-Type audio/mpeg | hard | pass | 3 ms |
| 05b | Content-Type audio/mp4 | hard | pass | 2 ms |
| 05c | Content-Type video/mp4 | hard | pass | 2 ms |
| 05d | Content-Type application/vnd.apple.mpegurl | hard | pass | 2 ms |
| 05e | Content-Type video/iso.segment | hard | pass | 2 ms |
| 05f | Content-Type text/vtt | hard | pass | 2 ms |
| 05g | Content-Type application/json+chapters | hard | pass | 2 ms |
| 05h | Content-Type application/rss+xml | hard | pass | 2 ms |
| 06a | Cache-Control round-trip | hard | pass | 2 ms |
| 06b | Content-Disposition round-trip | hard | pass | 2 ms |
| 07a | If-None-Match returns 304 | hard | **FAIL** | 2 ms |
| 07b | If-Modified-Since returns 304 | hard | **FAIL** | 2 ms |
| 08a | ListObjectsV2 pagination over 1,000 objects | hard | pass | 207 ms |
| 08b | ListObjectsV2 prefix and delimiter | hard | pass | 3 ms |
| 09a | Lifecycle: expire a prefix | soft | pass | 2 ms |
| 09b | Lifecycle: abort incomplete multipart uploads | soft | pass | 1 ms |
| 10a | Server-side copy (CopyObject) | hard | pass | 10 ms |
| 10b | Server-side copy of parts (UploadPartCopy) | soft | pass | 123 ms |
| 10c | x-amz-checksum-sha256 is verified and returned | soft | pass | 5 ms |
| 11 | Access-log export | soft | unsupported | 1 ms |
| 12 | Anonymous requests are denied | hard | pass | 3 ms |

## Observations

Notes and failure messages recorded by each case. The sanitized HTTP traces for failures are in the `go test -v` output.

### 01a Multipart: parts uploaded out of order, list parts, complete

- uploaded parts in the order 3, 1, 2
- multipart ETag is "d8444f560c6872dab9e2197ab4135ac4-3" (Relay uses its own SHA-256, never the ETag, as a checksum)

### 01b Multipart: abort

- ListParts after abort: HTTP 404 NoSuchUpload: The specified multipart upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.

### 01c Multipart: find and clean up incomplete uploads

- listed and aborted 3 incomplete uploads in 4 pages with MaxUploads=1

### 02a Presigned PUT

- signed headers: Content-Type, Host

### 02c Presigned URL expiry is enforced

- URLs signed for 2s were refused 5s later

### 03d Range with several ranges (behaviour recorded)

- ignores multiple ranges: 200 with the whole object (allowed by RFC 9110)
- Relay players and the edge only send single ranges; multi-range behaviour is recorded, not required

### 03e Range past the end returns 416

- Range past the end: status 416, Content-Range "bytes */10000"

### 04 HEAD returns Content-Length, Content-Type, ETag, Last-Modified

- single-part ETag is the MD5 of the body
- Accept-Ranges on HEAD: "bytes"

### 07a If-None-Match returns 304

- **Error:** read body: unexpected EOF

### 07b If-Modified-Since returns 304

- **Error:** read body: unexpected EOF

### 08a ListObjectsV2 pagination over 1,000 objects

- 1100 objects under the prefix
- default MaxKeys: 1100 keys in 2 pages
- MaxKeys=300: 1100 keys in 4 pages

### 08b ListObjectsV2 prefix and delimiter

- 30 common prefixes in 5 pages with MaxKeys=7

### 09a Lifecycle: expire a prefix

- rule accepted and read back; enforcement is not observed because the shortest period is one day

### 09b Lifecycle: abort incomplete multipart uploads

- rule accepted and read back; enforcement is not observed because the shortest period is one day

### 10b Server-side copy of parts (UploadPartCopy)

- needed only for copies over 5 GiB on targets that enforce AWS's CopyObject size limit

### 10c x-amz-checksum-sha256 is verified and returned

- stored checksum returned on HEAD: "Zr7peigXyOXfxKiuzoyDW5xloHivtePbMIZYiGAl4Tg="; wrong checksum rejected: true (HTTP 400 BadDigest: The Content-Md5 you specified did not match what we received.)

### 11 Access-log export

- how to get download logs on this target: SeaweedFS has no working S3 bucket-logging API. Its S3 gateway can send per-request audit records to Fluentd (weed -s3.auditLogConfig; not exercised by this suite). Relay would ship those, or the edge access logs, to relay-logs.
- PutBucketLogging is refused, so S3 server access logs cannot be enabled: HTTP 409 BucketAlreadyOwnedByYou: Your previous request to create the named bucket succeeded and you already own it.
