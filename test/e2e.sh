#!/bin/sh
# End-to-end test: real Dragonfly, `rclone serve s3` as a fake S3, and the image.
#
#   test/e2e.sh                     # builds dragonfly-s3-sync:e2e first
#   IMAGE=dragonfly-s3-sync:ci test/e2e.sh   # uses an already built image
#
# "Fresh empty volume" is reproduced the way Kubernetes delivers a new ext4 PVC with
# fsGroup: 999: a named volume whose root is root:root 0755 with a root-only lost+found,
# then kubelet's fsGroup pass (group 999, g+rwX, setgid dirs). Every container runs as
# 999:999 like the pod, so nothing gets a free root-owned or 999-owned volume.
set -eu

cd "$(dirname "$0")/.."
if [ -z "${IMAGE:-}" ]; then
  IMAGE=dragonfly-s3-sync:e2e
  docker build -t "$IMAGE" .
fi
RCLONE=$(sed -n 's/^FROM //p' Dockerfile | head -n 1)
DRAGONFLY=docker.dragonflydb.io/dragonflydb/dragonfly:v1.40.2
P="dss-e2e-$$"
KEYS=200000
MARK="marker-$$"
TMP=$(mktemp -d)

cleanup() {
  docker rm -f "$P-s3" "$P-df" "$P-restore" >/dev/null 2>&1 || :
  docker volume rm -f "$P-data" "$P-s3" >/dev/null 2>&1 || :
  docker network rm "$P" >/dev/null 2>&1 || :
  rm -rf "$TMP"
}
trap cleanup EXIT

step() { echo "==> $*"; }
fail() {
  echo "FAIL: $*"
  docker logs "$P-df" 2>&1 | tail -n 30 || :
  exit 1
}

fresh_volume() {
  docker rm -f "$P-df" >/dev/null 2>&1 || :
  docker volume rm -f "$P-data" >/dev/null 2>&1 || :
  docker volume create "$P-data" >/dev/null
  docker run --rm --user 0 --entrypoint sh -v "$P-data:/data" "$RCLONE" -c '
    chown 0:0 /data && chmod 0755 /data && mkdir -m 0700 /data/lost+found &&
    chgrp -R 999 /data && chmod -R g+rwX /data && chmod g+s /data /data/lost+found'
}

volume_files() { docker run --rm --user 999:999 -v "$P-data:/data:ro" --entrypoint ls "$RCLONE" -A /data; }

# sync [docker run options...] -- COMMAND
sync() {
  opts=
  while [ "$1" != -- ]; do opts="$opts $1"; shift; done
  shift
  # shellcheck disable=SC2086 # opts are simple flags
  docker run --rm --read-only --network "$P" --env-file "$TMP/s3.env" $opts "$IMAGE" "$@"
}

start_dragonfly() {
  docker run -d --name "$P-df" --network "$P" --user 999:999 --group-add 999 \
    --ulimit memlock=-1 -v "$P-data:/data" "$DRAGONFLY" \
    --dir=/data --dbfilename=snapshot --proactor_threads=4 >/dev/null
  i=0
  until [ "$(rcli ping 2>/dev/null)" = PONG ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "dragonfly did not start"
    sleep 1
  done
}

rcli() { docker exec "$P-df" redis-cli "$@"; }

# Loading runs in the background after start; wait for the full key count.
assert_dataset() {
  i=0
  while [ "$(rcli dbsize 2>/dev/null)" != $((KEYS + 1)) ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "dbsize is '$(rcli dbsize)', want $((KEYS + 1))"
    sleep 1
  done
  [ "$(rcli get marker)" = "$MARK" ] || fail "marker is '$(rcli get marker)', want $MARK"
  echo "PASS  $1: $((KEYS + 1)) keys and the marker"
}

step "fake S3 (rclone serve s3) and network"
docker network create "$P" >/dev/null
docker volume create "$P-s3" >/dev/null
docker run --rm --user 0 -v "$P-s3:/srv" --entrypoint mkdir "$RCLONE" /srv/bucket
docker run -d --name "$P-s3" --network "$P" -v "$P-s3:/srv" "$RCLONE" \
  serve s3 --addr :8080 --auth-key e2e-key,e2e-secret /srv >/dev/null
# The README's S3 example, pointed at the fake S3.
cat >"$TMP/s3.env" <<EOF
REMOTE=s3:bucket/dragonfly
RCLONE_CONFIG_S3_TYPE=s3
RCLONE_CONFIG_S3_PROVIDER=Rclone
RCLONE_CONFIG_S3_ENV_AUTH=true
RCLONE_CONFIG_S3_ENDPOINT=http://$P-s3:8080
RCLONE_CONFIG_S3_REGION=us-east-1
RCLONE_S3_NO_CHECK_BUCKET=true
AWS_ACCESS_KEY_ID=e2e-key
AWS_SECRET_ACCESS_KEY=e2e-secret
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
EOF

step "restore into a fresh volume with no backups"
fresh_volume
out=$(sync -v "$P-data:/data" -- restore 2>&1) || fail "restore with no backups: $out"
echo "$out" | grep -Fq "no backups — fresh volume" || fail "want 'no backups': $out"
echo "PASS  restore with an empty remote"

step "dragonfly: populate, mark, SAVE"
# The container clock, not the host's (Docker Desktop runs a VM).
started=$(docker run --rm --entrypoint date "$RCLONE" +%s)
start_dragonfly
rcli debug populate "$KEYS" key 100 RAND >/dev/null
rcli set marker "$MARK" >/dev/null
sleep 1 # the summary mtime must be strictly after the start second
[ "$(rcli save)" = OK ] || fail "SAVE failed"
echo "volume: $(volume_files | tr '\n' ' ')"

step "backup-once from a read-only volume"
out=$(sync -v "$P-data:/data:ro" -e "STARTED_AT=$started" -- backup-once 2>&1) || fail "backup-once: $out"
echo "$out" | grep -Fq "backup ok" || fail "want 'backup ok': $out"
docker run --rm --network "$P" --env-file "$TMP/s3.env" --entrypoint rclone "$IMAGE" lsl s3:bucket/dragonfly
echo "PASS  backup-once uploaded the snapshot"

step "wipe the volume, restore, start dragonfly"
fresh_volume
out=$(sync -v "$P-data:/data" -- restore 2>&1) || fail "restore: $out"
echo "$out" | grep -Fq "restore ok" || fail "want 'restore ok': $out"
start_dragonfly
assert_dataset "restore"

step "interrupted restore: throttle, kill mid-copy, rerun"
fresh_volume
docker run -d --name "$P-restore" --network "$P" --env-file "$TMP/s3.env" \
  --read-only -e RCLONE_BWLIMIT=2M -v "$P-data:/data" "$IMAGE" restore >/dev/null
sleep 4
[ "$(docker inspect -f '{{.State.Running}}' "$P-restore")" = true ] ||
  fail "restore finished before it could be interrupted: $(docker logs "$P-restore" 2>&1)"
docker kill "$P-restore" >/dev/null
files=$(volume_files)
echo "volume after kill: $(echo "$files" | tr '\n' ' ')"
if echo "$files" | grep -Fqx snapshot-summary.dfs; then fail "summary present after an interrupted restore"; fi
echo "PASS  interrupted restore left no summary"
out=$(sync -v "$P-data:/data" -- restore 2>&1) || fail "rerun restore: $out"
echo "$out" | grep -Fq "restore ok" || fail "want 'restore ok' on rerun: $out"
if volume_files | grep -q '\.partial$'; then fail "leftover .partial files: $(volume_files | tr '\n' ' ')"; fi
start_dragonfly
assert_dataset "rerun after an interrupted restore"

echo "e2e passed"
