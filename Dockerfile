# ppmmxDocker: one-click deployment image for a self-hosted ppmmx node.
# See README.md for build/run instructions and
# docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md for the feature this
# image deploys for (self-hosted ppmmx licensing).
#
# The binary at bin/mmx-linux-${TARGETARCH} is committed to THIS repo (not
# gitignored, unlike dist/ - see build.sh's header comment) and just COPY'd
# in here. That's deliberate: ppmmx's own source repo is private, so an end
# customer's machine has no way to clone+compile it themselves - cloning
# this public repo must be enough on its own. Maintainers refresh
# bin/mmx-linux-amd64 (via build.sh, from a local ppmmx checkout) and commit
# it whenever a new ppmmx version should ship here; see build.sh's "release"
# note. Once ppmmx publishes public GitHub Releases this can switch to
# downloading those instead.
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Only linux/amd64 is built today - see build.sh's comment on the arm64
# rpicamera embed blocker. Override at build time once arm64 is fixed:
#   docker build --build-arg TARGETARCH=arm64 .
ARG TARGETARCH=amd64

WORKDIR /app
COPY bin/mmx-linux-${TARGETARCH} /app/mmx
COPY conf/ /app/conf/
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/mmx /app/docker-entrypoint.sh

ENV MMX_ROLE=standalone
VOLUME ["/app/data", "/app/logs"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
