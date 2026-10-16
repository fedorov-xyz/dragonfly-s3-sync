# dragonfly-s3-sync

A small container image on top of [rclone](https://rclone.org) that keeps a
[Dragonfly](https://www.dragonflydb.io) snapshot in S3 (or any rclone remote)
without letting the object store anywhere near Dragonfly itself:

- **`restore`** (init container): if the snapshot volume is empty, copy the
  latest backup into it before Dragonfly starts;
- **`backup`** (sidecar): whenever Dragonfly has saved a new snapshot to the
  volume, mirror it to the remote.

```
ghcr.io/fedorov-xyz/dragonfly-s3-sync:<version>      # linux/amd64, linux/arm64
```

## Why

Dragonfly can snapshot straight to S3 (`--dir=s3://…`), but a slow object store
or a DNS hiccup then stalls Dragonfly itself
([dragonflydb/dragonfly#6389](https://github.com/dragonflydb/dragonfly/issues/6389)).
We saw 4–12 minute stalls on Backblaze B2 and `TxQueue is too long` on Wasabi
during a DNS outage. So Dragonfly snapshots to a local volume, and this image
copies the files to S3 out of band. If S3 is slow or down, only the backup is
late; Dragonfly does not notice.

## How it works

```
pod (one replica)
├─ init     dragonfly-s3-sync restore   REMOTE ──▶ volume    only if the volume has no summary
├─ main     dragonfly --dir=<volume> --dbfilename=snapshot   SAVE / cron ──▶ volume
└─ sidecar  dragonfly-s3-sync backup    volume (read-only) ──▶ REMOTE   each new, finished save

volume:  snapshot-summary.dfs  snapshot-0000.dfs  snapshot-0001.dfs  …
REMOTE:  s3:bucket/prefix/ with the same files
```

Dragonfly's DF snapshot format (the default) writes one `<name>-summary.dfs`
plus one `<name>-NNNN.dfs` per shard (thread). It writes `….dfs.tmp` files and
renames them when the save is done. On start it loads the newest
`<name>-summary.dfs` and every `<name>-????.dfs` next to it.

### `restore`

1. `<name>-summary.dfs` already on the volume → `volume already has a snapshot — skip restore`, exit 0.
2. List the remote. A listing error (network, auth, DNS) exits non-zero and is
   never taken for "no backups"; kubelet retries the init container.
3. No `<name>-summary.dfs` in the remote → `no backups — fresh volume`, exit 0.
4. Copy the shards first (`rclone sync --inplace`, which also drops stray local
   shards Dragonfly would otherwise load), then the summary last (`rclone copyto`,
   atomic rename). If the copy is interrupted, the volume has no summary, so the
   retry restores again instead of skipping and letting Dragonfly silently
   load a partial dataset; Dragonfly does not error on missing shards.
5. Any rclone error → non-zero exit; success → `restore ok`.

### `backup` and `backup-once`

`backup` notes its start time, then every `POLL_SECONDS` runs one attempt if
nothing has been uploaded yet or `BACKUP_INTERVAL_SECONDS` have passed since the
last upload. A failed or skipped attempt is retried on the next tick. SIGTERM
stops it immediately between attempts. `backup-once` runs exactly one attempt
(exit 0 = uploaded or nothing to do, 1 = retry) and takes the start time from
`STARTED_AT` (epoch seconds, default now).

One attempt:

1. No summary on the volume → `no snapshot yet — skip`.
2. Summary not newer than the start time → `no snapshot saved since start — skip`.
   Files from before this Dragonfly started may be a partial restore; uploading
   them right after start once deleted a good shard from S3.
3. Any `*.tmp` on the volume → `save in progress — retry next tick`.
4. `rclone sync` the volume's `<name>-*.dfs` files to the remote. It is `sync`,
   not `copy`, so stale shards in the remote are deleted when the shard count
   changes. Other files under `REMOTE` are not touched. If the files changed
   during the upload (size or mtime), → `snapshot changed while uploading — retry next tick`.
5. Success → `backup ok`; an rclone error → `backup failed` (stderr), retried.

The sidecar never writes to the data volume; mount it read-only.

Other commands: `version` prints the image version and the rclone version.
Exit code 2 means a wrong command line.

## Configuration

Everything is set through environment variables and checked at start; a bad
value exits 1 with a message.

| Variable | Default | Meaning |
|---|---|---|
| `REMOTE` | required | rclone path of the backup location, e.g. `s3:bucket/prefix/`. Any rclone remote works, including `crypt` and a plain local directory. Normalised to exactly one trailing `/`. |
| `DATA_DIR` | `/data` | Where the Dragonfly snapshot volume is mounted. |
| `DBFILENAME` | `snapshot` | Same value as Dragonfly's `--dbfilename`. Must be a fixed name (`[A-Za-z0-9_-]+`); see below. |
| `BACKUP_INTERVAL_SECONDS` | `600` | Minimum time between successful uploads. |
| `POLL_SECONDS` | `60` | Loop tick. |
| `STARTED_AT` | now | `backup-once` only: treat summaries not newer than this epoch second as old. |

**`DBFILENAME` must be fixed.** Dragonfly's default `--dbfilename` is
`dump-{timestamp}`, and the Dragonfly operator does not change it. With a
timestamp every save is a new set of files, and Dragonfly never deletes the
old ones, so the volume fills up. Set `--dbfilename=snapshot` (or another fixed
name) on Dragonfly and the same value here. Names with `{…}` are rejected.

rclone itself is configured with `RCLONE_CONFIG_<REMOTE>_*` variables and
credentials. The image sets `RCLONE_CONFIG=""` (in-memory config, no config
file); set `RCLONE_CONFIG=/path/rclone.conf` to use a mounted file instead.
Any other `RCLONE_*` flag works too, e.g. `RCLONE_BWLIMIT=10M`,
`RCLONE_TRANSFERS=2`, `RCLONE_VERBOSE=1`.

S3 example (`REMOTE=s3:my-bucket/dragonfly/cache/`):

```sh
RCLONE_CONFIG_S3_TYPE=s3
RCLONE_CONFIG_S3_PROVIDER=Other            # AWS, Wasabi, Cloudflare, Ceph, … (rclone docs)
RCLONE_CONFIG_S3_ENV_AUTH=true             # take credentials from AWS_* below
RCLONE_CONFIG_S3_ENDPOINT=https://s3.eu-central-003.backblazeb2.com
RCLONE_CONFIG_S3_REGION=eu-central-003
RCLONE_S3_NO_CHECK_BUCKET=true             # the bucket exists; don't try to create it
AWS_ACCESS_KEY_ID=…                        # from a Secret
AWS_SECRET_ACCESS_KEY=…                    # from a Secret
# Non-AWS S3: newer AWS SDKs send checksums that many providers reject.
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
```

## Example: Dragonfly operator

The [Dragonfly operator](https://github.com/dragonflydb/dragonfly-operator)
mounts the snapshot volume as `df` at `/dragonfly/snapshots`, passes
`--dir=/dragonfly/snapshots`, and with `cron` set passes `--snapshot_cron`.
The init container and the sidecar mount the same `df` volume at `/data`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cache-snapshots
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cache-s3-sync
data:
  REMOTE: s3:my-bucket/dragonfly/cache/
  DBFILENAME: snapshot
  BACKUP_INTERVAL_SECONDS: "600"
  RCLONE_CONFIG_S3_TYPE: s3
  RCLONE_CONFIG_S3_PROVIDER: Other
  RCLONE_CONFIG_S3_ENV_AUTH: "true"
  RCLONE_CONFIG_S3_ENDPOINT: https://s3.eu-central-003.backblazeb2.com
  RCLONE_CONFIG_S3_REGION: eu-central-003
  RCLONE_S3_NO_CHECK_BUCKET: "true"
  AWS_REQUEST_CHECKSUM_CALCULATION: when_required
  AWS_RESPONSE_CHECKSUM_VALIDATION: when_required
---
apiVersion: v1
kind: Secret
metadata:
  name: cache-s3-sync
stringData:
  AWS_ACCESS_KEY_ID: "…"
  AWS_SECRET_ACCESS_KEY: "…"
---
apiVersion: dragonflydb.io/v1alpha1
kind: Dragonfly
metadata:
  name: cache
spec:
  replicas: 1
  args:
    - --dbfilename=snapshot          # fixed name, same as DBFILENAME
  snapshot:
    cron: "*/10 * * * *"
    existingPersistentVolumeClaimName: cache-snapshots
  # No podSecurityContext here: the operator then sets fsGroup: 999 (see Requirements).
  initContainers:
    - name: s3-restore
      image: ghcr.io/fedorov-xyz/dragonfly-s3-sync:0.1.0
      args: [restore]
      envFrom:
        - configMapRef: { name: cache-s3-sync }
        - secretRef: { name: cache-s3-sync }
      volumeMounts:
        - name: df
          mountPath: /data
  additionalContainers:
    - name: s3-backup
      image: ghcr.io/fedorov-xyz/dragonfly-s3-sync:0.1.0
      args: [backup]
      envFrom:
        - configMapRef: { name: cache-s3-sync }
        - secretRef: { name: cache-s3-sync }
      volumeMounts:
        - name: df
          mountPath: /data
          readOnly: true
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
      resources:
        requests: { cpu: 10m, memory: 64Mi }
        limits: { memory: 256Mi }
```

To restore from S3 on purpose, delete the PVC (or the snapshot files on it)
and restart the pod; a volume that has a summary is never overwritten.

## Requirements and limits

- **The volume needs `fsGroup: 999`.** Dragonfly writes its snapshot files as
  `0600` owned by uid 999, and the image runs as `999:999`. The operator sets
  `fsGroup: 999` by default, but not when the CR sets `podSecurityContext` or
  `skipFSGroup`; then set `fsGroup: 999` in your `podSecurityContext` yourself.
  Running the containers as another uid works only if that uid can read
  (backup) and write (restore) the volume.
- **Single replica only.** One Dragonfly, one volume, one writer to `REMOTE`.
  No replicas or cluster mode, and never point two deployments at the same `REMOTE`.
- **The remote is not updated atomically.** Files upload one by one, so during
  an upload (up to one tick, or until the next successful upload if one fails
  midway) the remote can hold the summary and shards from different saves.
  A restore in that window gets a mixed set.
- **Use bucket versioning plus a lifecycle rule that expires noncurrent
  versions** (e.g. after 7 days). Versioning lets you recover from a bad
  upload; the lifecycle rule stops the old versions piling up, since every
  upload overwrites the same objects. Avoid storage classes and providers with a
  **minimum storage duration** (Wasabi, S3 IA/Glacier, …): each overwrite is
  billed as if it had been kept for the full minimum.
- The restore needs as much free space on the volume as the snapshot itself.
- Both commands work with `readOnlyRootFilesystem` (the e2e test runs them
  that way against S3); if an rclone backend needs a cache, mount an `emptyDir` at `/tmp`.
- Only Dragonfly's DF snapshot format (`.dfs`) is supported, not `.rdb`.

Out of scope: a metrics endpoint, scheduling Dragonfly saves (use
`--snapshot_cron` / the operator's `cron`), replica and cluster setups,
encryption beyond rclone's own remotes (use `crypt`), Kubernetes manifests or a
Helm chart.

## Development

See [AGENTS.md](AGENTS.md) for commands and rules, and
[RELEASING.md](RELEASING.md) for releases.

## License

[MIT](LICENSE)
