#!/usr/bin/env bash
# Seeds the synthetic Phase 0 dataset into the source environment ($FROM):
#   - media: $MEDIA_OBJECTS random objects of $MEDIA_OBJECT_MIB MiB (default 64 × 16 MiB = 1 GiB) in
#     relay-media, under immutable, versioned keys, plus a few feed snapshots in relay-feeds;
#   - database: $EPISODE_ROWS rows (default 10,000) in portability.episodes on the relay cluster, each
#     referencing a media object by key and SHA-256, plus a marker table that verify.sh uses to prove
#     where recovery stopped.
# Idempotent: an existing dataset is kept (objects are immutable, so they are never rewritten).
set -euo pipefail
# shellcheck source=scripts/portability/common.sh
source "$(dirname "$0")/common.sh"

use_run "${1:-}"
work=$(mktemp -d)
trap 'rm -rf "$work"; cleanup_s3' EXIT

seed_media() {
  # Generated and hashed inside the source cluster: the data never crosses a port-forward.
  rclone_job "$FROM" seed src="$FROM" -- "
    have=\$(rclone lsf src:relay-media/portability/v1/ 2>/dev/null | grep -c '\\.bin\$' || true)
    if [ \"\$have\" -ge $MEDIA_OBJECTS ]; then
      echo \"keeping the \$have existing objects\" >&2
    else
      i=1
      while [ \$i -le $MEDIA_OBJECTS ]; do
        key=\$(printf 'portability/v1/episode-%04d.bin' \$i)
        if ! rclone lsf \"src:relay-media/\$key\" 2>/dev/null | grep -q .; then
          head -c $((MEDIA_OBJECT_MIB * 1024 * 1024)) /dev/urandom | rclone rcat --size $((MEDIA_OBJECT_MIB * 1024 * 1024)) \"src:relay-media/\$key\"
          echo \"@@ bytes $((MEDIA_OBJECT_MIB * 1024 * 1024))\"
        fi
        i=\$((i + 1))
      done
    fi
    for n in 1 2 3 4; do
      printf '<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n<rss version=\"2.0\"><channel><title>Portability show %s</title></channel></rss>\\n' \$n |
        rclone rcat \"src:relay-feeds/portability/feeds/show-\$n.xml\"
    done
    # Checksums come from the stored objects, so the DB records what S3 holds.
    rclone hashsum sha256 --download src:relay-media/portability/v1/ | sed 's/^/@@ sha256 /'
  "
  local out=$RUN_DIR/jobs/seed.out bytes
  while read -r bytes; do record_bytes "$bytes"; done < <(sed -n 's/^bytes //p' "$out")
  sed -n 's/^sha256 //p' "$out" | sort -k2 >"$work/media.sha256"
  [ "$(wc -l <"$work/media.sha256")" -ge "$MEDIA_OBJECTS" ] || die "expected $MEDIA_OBJECTS media objects"
}

seed_db() {
  {
    cat <<'SQL'
CREATE SCHEMA IF NOT EXISTS portability;
CREATE TABLE IF NOT EXISTS portability.media_objects (
  key text PRIMARY KEY, sha256 text NOT NULL);
CREATE TABLE IF NOT EXISTS portability.episodes (
  guid uuid PRIMARY KEY, title text NOT NULL, published_at timestamptz NOT NULL,
  media_key text NOT NULL REFERENCES portability.media_objects (key), media_sha256 text NOT NULL);
-- One row per event around the backup: seed.sh writes 'seeded', export.sh writes 'after-backup'
-- once the recovery point is taken. A restore to that point has the first and not the second.
CREATE TABLE IF NOT EXISTS portability.markers (
  run_id text NOT NULL, event text NOT NULL, at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (run_id, event));
SQL
    echo "INSERT INTO portability.media_objects (key, sha256) VALUES"
    awk '{printf "%s(%s, %s)", (NR > 1 ? ",\n" : ""), "'\''" $2 "'\''", "'\''" $1 "'\''"} END {print "\nON CONFLICT (key) DO NOTHING;"}' \
      "$work/media.sha256" | sed "s|('|('relay-media/portability/v1/|"
    cat <<SQL
INSERT INTO portability.episodes (guid, title, published_at, media_key, media_sha256)
SELECT md5('relay-portability-episode-' || n)::uuid, 'Episode ' || n,
       timestamptz '2026-01-01' + n * interval '1 hour', m.key, m.sha256
FROM generate_series(1, $EPISODE_ROWS) AS n
JOIN LATERAL (SELECT key, sha256 FROM portability.media_objects ORDER BY key
              OFFSET (n - 1) % (SELECT count(*) FROM portability.media_objects) LIMIT 1) m ON true
ON CONFLICT (guid) DO NOTHING;
INSERT INTO portability.markers (run_id, event) VALUES ('$RUN_ID', 'seeded') ON CONFLICT DO NOTHING;
SQL
  } | psql_env "$FROM" relay-db/relay relay
  local rows
  rows=$(psql_env "$FROM" relay-db/relay relay -At <<<"SELECT count(*) FROM portability.episodes")
  [ "$rows" -ge "$EPISODE_ROWS" ] || die "portability.episodes has $rows rows, expected $EPISODE_ROWS"
  log "portability.episodes: $rows rows"
}

step seed "media: $MEDIA_OBJECTS × $MEDIA_OBJECT_MIB MiB in relay-media, feeds in relay-feeds ($FROM)" seed_media
step seed "database: $EPISODE_ROWS rows in relay.portability.episodes ($FROM)" seed_db
