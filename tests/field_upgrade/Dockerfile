ARG DEBIAN
FROM debian:${DEBIAN}-slim
ARG DEBIAN
# Bullseye's live security index advertised files the mirror no longer served.
# Use the snapshot recorded in the base image's sources.list.
RUN if [ "$DEBIAN" = bullseye ]; then \
      sed -i '/^deb /d; s|^# deb http://snapshot.debian.org/|deb [check-valid-until=no] http://snapshot.debian.org/|' /etc/apt/sources.list; \
      grep -q '^deb ' /etc/apt/sources.list; \
    fi && \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-venv python3-pip python3-dev gcc libc6-dev \
      sudo coreutils && rm -rf /var/lib/apt/lists/*
COPY requirements-* /requirements/
RUN for requirements in /requirements/*; do \
    /usr/bin/python3 -m pip wheel --wheel-dir "/wheels/${requirements##*/}" -r "$requirements" || exit; \
    done
