#!/bin/bash
# Share the Debian startup fixtures between the OS and migration matrices.
set -euo pipefail
case "$1" in
    11) debian=bullseye ;;
    12) debian=bookworm ;;
    13) debian=trixie ;;
    *) echo "Unsupported Debian version: $1" >&2; exit 2 ;;
esac

docker build --build-arg "DEBIAN=$debian" -t "pagalava-startup-matrix:$1" - <<'DOCKER'
ARG DEBIAN
FROM debian:${DEBIAN}-slim
ARG DEBIAN
RUN if [ "$DEBIAN" = bullseye ]; then \
        sed -i '/^deb /d; s|^# deb http://snapshot.debian.org/|deb [check-valid-until=no] http://snapshot.debian.org/|' /etc/apt/sources.list; \
    fi && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends ca-certificates git python3 python3-venv && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv /venv && \
    /venv/bin/pip install -q --no-cache-dir azure-iot-device python-dotenv
DOCKER
