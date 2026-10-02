# Linux test environment for clh.bash: bash 5 with GNU tools, curl and jq.
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends bash curl jq ca-certificates procps git && rm -rf /var/lib/apt/lists/*
WORKDIR /clh
