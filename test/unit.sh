#!/bin/sh
# Unit tests for dragonfly-s3-sync. A temp dir is the remote, fake .dfs files are the snapshot.
#
# Run from anywhere: test/unit.sh. It re-runs itself inside the Dockerfile's rclone base
# image as uid 999 with no network, so rclone, busybox and permissions match production
# (chmod 000 only blocks a non-root user).
set -eu

if [ -z "${IN_TEST_IMAGE:-}" ]; then
  repo=$(cd "$(dirname "$0")/.." && pwd)
  base=$(sed -n 's/^FROM //p' "$repo/Dockerfile" | head -n 1)
  exec docker run --rm --network none --user 999:999 \
    -e IN_TEST_IMAGE=1 -e HOME=/tmp -e RCLONE_CONFIG= \
    -v "$repo:/src:ro" --entrypoint sh "$base" /src/test/unit.sh
fi

SUT=/src/dragonfly-s3-sync
T=$(mktemp -d)
failures=0
errs=
out=
rc=

# ---- helpers ---------------------------------------------------------------

setup() {
  chmod -R u+rwX "$T" 2>/dev/null || :
  rm -rf "${T:?}"/*
  mkdir -p "$T/data" "$T/remote"
  unset STARTED_AT DBFILENAME
  export DATA_DIR="$T/data" REMOTE="$T/remote"
}

# mkset DIR TAG: a 3-shard snapshot whose contents carry TAG.
mkset() {
  for i in 0000 0001 0002; do echo "shard $i $2" >"$1/snapshot-$i.dfs"; done
  echo "summary $2" >"$1/snapshot-summary.dfs"
}

run() {
  rc=0
  out=$("$SUT" "$@" 2>&1) || rc=$?
}

# shellcheck disable=SC2012 # fixture names are plain
files() { (cd "$1" && ls -A | tr '\n' ' '); }

check() {
  msg=$1
  shift
  "$@" || errs="$errs
    - $msg"
}
has() { printf '%s\n' "$out" | grep -Fq -- "$1"; }
hasnt() { ! has "$1"; }
eq() { [ "$1" = "$2" ]; }
same_dirs() { [ "$(files "$1")" = "$(files "$2")" ] && for f in "$1"/*; do cmp -s "$f" "$2/${f##*/}" || return 1; done; }

finish() {
  if [ -z "$errs" ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1$errs"
    echo "      exit code: $rc, output:"
    printf '%s\n' "$out" | sed 's/^/      | /'
    failures=$((failures + 1))
  fi
  errs=
}

now() { date +%s; }

# ---- config ----------------------------------------------------------------

setup
unset REMOTE
run restore
check "exit 1" eq "$rc" 1
check "explains REMOTE" has "REMOTE is required"
finish "config: missing REMOTE fails fast"

setup
DBFILENAME='dump-{timestamp}' run backup-once
check "exit 1" eq "$rc" 1
check "explains DBFILENAME" has "DBFILENAME must be a fixed name"
finish "config: timestamped DBFILENAME is rejected"

setup
mkset "$T/remote" A
for f in "$T"/remote/*; do mv "$f" "$T/remote/cache-${f##*/snapshot-}"; done
DBFILENAME=cache run restore
check "exit 0" eq "$rc" 0
check "restored under the custom name" same_dirs "$T/remote" "$T/data"
finish "config: custom DBFILENAME"

setup
POLL_SECONDS=0 run backup
check "exit 1" eq "$rc" 1
check "explains POLL_SECONDS" has "POLL_SECONDS must be a positive integer"
finish "config: POLL_SECONDS=0 is rejected"

# ---- restore ---------------------------------------------------------------

setup
run restore
check "exit 0" eq "$rc" 0
check "logs no backups" has "no backups — fresh volume"
check "volume still empty" eq "$(files "$T/data")" ""
finish "restore: empty volume, empty remote"

setup
mkset "$T/remote" A
REMOTE="$T/remote///" run restore
check "exit 0" eq "$rc" 0
check "logs restore ok" has "restore ok"
check "volume equals remote" same_dirs "$T/remote" "$T/data"
check "files owned by uid 999" eq "$(stat -c %u "$T"/data/* | sort -u)" 999
finish "restore: empty volume, full remote (REMOTE with extra slashes)"

setup
mkset "$T/remote" A
echo old >"$T/data/snapshot-summary.dfs"
run restore
check "exit 0" eq "$rc" 0
check "logs skip" has "volume already has a snapshot — skip restore"
check "nothing copied" eq "$(files "$T/data")" "snapshot-summary.dfs "
check "summary untouched" eq "$(cat "$T/data/snapshot-summary.dfs")" old
finish "restore: volume already has a summary"

setup
REMOTE="$T/missing" run restore
check "non-zero exit" [ "$rc" -ne 0 ]
check "no 'no backups' line" hasnt "no backups"
check "volume still empty" eq "$(files "$T/data")" ""
finish "restore: remote directory missing is a listing error"

setup
mkset "$T/remote" A
chmod 000 "$T/remote"
run restore
check "non-zero exit" [ "$rc" -ne 0 ]
check "no 'no backups' line" hasnt "no backups"
finish "restore: unreadable remote is a listing error"

setup
mkset "$T/remote" A
chmod 000 "$T/remote/snapshot-0001.dfs"
run restore
check "non-zero exit" [ "$rc" -ne 0 ]
check "no summary in volume" [ ! -e "$T/data/snapshot-summary.dfs" ]
chmod 644 "$T/remote/snapshot-0001.dfs"
run restore
check "rerun exit 0" eq "$rc" 0
check "rerun restores the full set" same_dirs "$T/remote" "$T/data"
finish "restore: interrupted copy leaves no summary, rerun completes"

setup
mkset "$T/remote" A
echo stray >"$T/data/snapshot-0007.dfs"
run restore
check "exit 0" eq "$rc" 0
check "stray local shard removed" same_dirs "$T/remote" "$T/data"
finish "restore: stray shard in a summary-less volume is dropped"

# ---- backup-once -----------------------------------------------------------

setup
run backup-once
check "exit 0" eq "$rc" 0
check "logs no snapshot" has "no snapshot yet — skip"
check "nothing uploaded" eq "$(files "$T/remote")" ""
finish "backup: no snapshot yet"

setup
mkset "$T/data" A
STARTED_AT=$(($(now) + 100)) run backup-once
check "exit 0" eq "$rc" 0
check "logs skip" has "no snapshot saved since start — skip"
check "nothing uploaded" eq "$(files "$T/remote")" ""
finish "backup: summary older than STARTED_AT is not uploaded"

setup
mkset "$T/data" A
chmod a-w "$T/data"
STARTED_AT=$(($(now) - 100)) run backup-once
check "exit 0" eq "$rc" 0
check "logs backup ok" has "backup ok"
check "remote equals volume" same_dirs "$T/data" "$T/remote"
finish "backup: fresh summary is uploaded from a read-only volume"

setup
mkset "$T/data" A
echo partial >"$T/data/snapshot-0001.dfs.tmp"
STARTED_AT=$(($(now) - 100)) run backup-once
check "exit 1" eq "$rc" 1
check "logs save in progress" has "save in progress — retry next tick"
check "nothing uploaded" eq "$(files "$T/remote")" ""
finish "backup: .tmp present means retry"

setup
mkset "$T/data" B
mkset "$T/remote" OLD # different size: same-second fixtures would look unchanged to rclone
echo stale >"$T/remote/snapshot-0003.dfs"
echo keep >"$T/remote/other.txt"
STARTED_AT=$(($(now) - 100)) run backup-once
check "exit 0" eq "$rc" 0
check "stale shard removed" [ ! -e "$T/remote/snapshot-0003.dfs" ]
check "unrelated file kept" [ -e "$T/remote/other.txt" ]
check "new set uploaded" eq "$(cat "$T/remote/snapshot-summary.dfs")" "summary B"
finish "backup: sync drops a stale shard, leaves other files"

setup
mkset "$T/data" A
chmod 555 "$T/remote"
STARTED_AT=$(($(now) - 100)) run backup-once
check "exit 1" eq "$rc" 1
check "logs backup failed" has "backup failed"
finish "backup: upload error means retry"

# A shim rclone that rewrites a shard right after the upload, as a concurrent SAVE would.
setup
mkset "$T/data" A
mkdir "$T/bin"
cat >"$T/bin/rclone" <<EOF
#!/bin/sh
/usr/local/bin/rclone "\$@" || exit
sleep 1
echo changed >"$T/data/snapshot-0000.dfs"
EOF
chmod +x "$T/bin/rclone"
PATH="$T/bin:$PATH" STARTED_AT=$(($(now) - 100)) run backup-once
check "exit 1" eq "$rc" 1
check "logs changed" has "snapshot changed while uploading — retry next tick"
finish "backup: snapshot changed during upload means retry"

# ---- backup loop -----------------------------------------------------------

setup
mkset "$T/data" OLD
sleep 1
POLL_SECONDS=1 "$SUT" backup >"$T/loop.log" 2>&1 &
pid=$!
sleep 2
mkset "$T/data" NEW # newer than the loop's start
sleep 3
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
out=$(cat "$T/loop.log")
check "exits 0 on TERM" eq "$rc" 0
check "skipped files from before start" has "no snapshot saved since start — skip"
check "uploaded exactly once" eq "$(grep -c 'backup ok' "$T/loop.log")" 1
check "remote equals volume" same_dirs "$T/data" "$T/remote"
finish "backup loop: skips old files, uploads a new save once per interval, exits on TERM"

# ---------------------------------------------------------------------------

chmod -R u+rwX "$T" 2>/dev/null || :
rm -rf "$T"
if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
