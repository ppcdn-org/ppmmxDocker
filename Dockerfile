# ppmmxDocker: one-click deployment image for a self-hosted ppmmx node.
# See README.md for build/run instructions and
# docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md for the feature this
# image deploys for (self-hosted ppmmx licensing).
#
# The ppmmx binary is NOT stored in this repo: it is downloaded at build time
# from this repo's latest GitHub Release (only the newest version is kept
# there) and verified against the release's .sha256 file. ppmmx's own source
# repo is private, so end customers cannot compile it; the public Release is
# how they get a ready-to-run binary. Maintainers publish a new version with
# ./build.sh --release (see build.sh and README.md). To use a different source
# (a mirror, or a local file server while testing a build):
#   docker build --build-arg MMX_BASE_URL=http://host:8000 .
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Only linux/amd64 is built today - see build.sh's comment on the arm64
# rpicamera embed blocker. Override at build time once arm64 is fixed:
#   docker build --build-arg TARGETARCH=arm64 .
ARG TARGETARCH=amd64
ARG MMX_BASE_URL=https://github.com/ppcdn-org/ppmmxDocker/releases/latest/download

WORKDIR /app
ADD ${MMX_BASE_URL}/mmx-linux-${TARGETARCH} /app/mmx
ADD ${MMX_BASE_URL}/mmx-linux-${TARGETARCH}.sha256 /tmp/mmx.sha256
RUN echo "$(cut -d' ' -f1 /tmp/mmx.sha256)  /app/mmx" | sha256sum -c - \
    && chmod 755 /app/mmx && rm /tmp/mmx.sha256
COPY conf/ /app/conf/
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

ENV MMX_ROLE=standalone
VOLUME ["/app/data", "/app/logs"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
