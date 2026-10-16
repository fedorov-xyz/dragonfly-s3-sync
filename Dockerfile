# syntax=docker/dockerfile:1

FROM rclone/rclone:1.75.2

ARG VERSION=dev
ARG COMMIT=unknown

LABEL org.opencontainers.image.title="dragonfly-s3-sync" \
      org.opencontainers.image.description="Restore Dragonfly snapshots from S3 into an empty volume and mirror fresh snapshots back (rclone)" \
      org.opencontainers.image.source="https://github.com/fedorov-xyz/dragonfly-s3-sync" \
      org.opencontainers.image.url="https://github.com/fedorov-xyz/dragonfly-s3-sync" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}"

COPY --chmod=0755 dragonfly-s3-sync /usr/local/bin/dragonfly-s3-sync

# HOME=/tmp: rclone needs a writable home whatever uid the pod runs as.
# RCLONE_CONFIG="": in-memory config from RCLONE_CONFIG_* env, no "config file not found" notice.
ENV HOME=/tmp \
    RCLONE_CONFIG="" \
    DRAGONFLY_S3_SYNC_VERSION=${VERSION} \
    DRAGONFLY_S3_SYNC_COMMIT=${COMMIT}

# Dragonfly's uid/gid: its snapshot files are 0600 dfly:dfly.
USER 999:999

ENTRYPOINT ["/usr/local/bin/dragonfly-s3-sync"]
