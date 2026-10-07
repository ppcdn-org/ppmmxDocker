# ppmmxDocker: one-click deployment image for a self-hosted ppmmx node.
# See README.md for build/run instructions and
# docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md for the feature this
# image deploys for (self-hosted ppmmx licensing).
#
# The binary is built OUTSIDE this Dockerfile by ./build.sh (cross-compiling
# from a sibling github.com/ppcdn-org/ppmmx checkout) and just COPY'd in here
# - see build.sh's header comment for why, and its note on switching to
# downloading a GitHub Release artifact once ppmmx publishes one.
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Only linux/amd64 is built today - see build.sh's comment on the arm64
# rpicamera embed blocker. Override at build time once arm64 is fixed:
#   docker build --build-arg TARGETARCH=arm64 .
ARG TARGETARCH=amd64

WORKDIR /app
COPY dist/mmx-linux-${TARGETARCH} /app/mmx
COPY conf/ /app/conf/
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/mmx /app/docker-entrypoint.sh

ENV MMX_ROLE=standalone
VOLUME ["/app/data", "/app/logs"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
