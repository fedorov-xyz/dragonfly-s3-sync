# AGENTS.md

Guidance for AI agents and humans changing this repository. See README.md for
what dragonfly-s3-sync is and how it works.

## Commands

```sh
shellcheck dragonfly-s3-sync test/*.sh   # or: docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable dragonfly-s3-sync test/*.sh
test/unit.sh                             # needs docker; runs in the rclone base image as uid 999, no network
test/e2e.sh                              # builds the image; real Dragonfly + rclone serve s3
IMAGE=dragonfly-s3-sync:ci test/e2e.sh   # against an already built image
docker build -t dragonfly-s3-sync:dev .
```

## Layout

- `dragonfly-s3-sync` — the whole program: one POSIX `sh` script, installed as
  `/usr/local/bin/dragonfly-s3-sync` and used as the ENTRYPOINT.
- `Dockerfile` — `FROM rclone/rclone`, no RUN steps (multi-arch without QEMU).
  The `FROM` line is the single source of the rclone version; both test
  scripts read it.
- `test/unit.sh` — restore/backup cases against a temp-dir remote and fake `.dfs` files.
- `test/e2e.sh` — Dragonfly → backup-once → wipe → restore → Dragonfly, plus an
  interrupted restore, against a fake S3.
- `.github/workflows/ci.yml`, `release.yml` — CI and the manual release (see RELEASING.md).

## Rules

1. **POSIX `sh` only.** The script runs under busybox `sh` in Alpine; no bash,
   no other languages, no extra packages in the image.
2. **Every behaviour change needs a unit test** in `test/unit.sh`; changes in
   how files reach or leave Dragonfly also need `test/e2e.sh` to cover them.
3. **Each restore/backup rule keeps its one-line reason comment.** They were
   learned from real failures (partial restores, deleted shards, stalled
   Dragonfly); do not "simplify" one away without understanding it.
4. **`backup` never writes to `DATA_DIR`**; it is mounted read-only in the sidecar.
5. **Configuration** comes only from the variables in the README env table
   (plus rclone's own `RCLONE_*`). Validate new ones at start and fail fast.
6. **No secrets** in logs, fixtures, tests or commits. Test credentials are
   throwaway values for the local fake S3.
7. **Out of scope stays out:** metrics endpoint, scheduling Dragonfly saves,
   replica/cluster setups, encryption beyond rclone remotes, Kubernetes
   manifests or Helm charts.
8. **Commits follow [Conventional Commits](https://www.conventionalcommits.org/):**
   `<type>(<scope>)?: <summary>` with types such as `feat`, `fix`,
   `refactor`, `docs`, `test`, `ci`, `build`, `chore`; the scope is the area
   (e.g. `restore`, `backup`, `image`). Breaking changes use `!` after the
   type/scope and a `BREAKING CHANGE:` footer.
