#!/bin/sh
# Picks the config file for MMX_ROLE (standalone|origin|edge|record, default
# standalone) unless the caller bind-mounted their own at /app/mmx.yml - see
# README.md.
set -e

ROLE="${MMX_ROLE:-standalone}"
CONF="/app/mmx.yml"

if [ ! -f "$CONF" ]; then
  CONF="/app/conf/${ROLE}.yml"
fi

if [ ! -f "$CONF" ]; then
  echo "ERROR: no config for MMX_ROLE='${ROLE}' (expected ${CONF}, or bind-mount your own at /app/mmx.yml)" >&2
  echo "       valid roles: standalone, origin, edge, record" >&2
  exit 1
fi

echo "ppmmxDocker: starting with role='${ROLE}' conf='${CONF}'"
exec /app/mmx "$CONF"
