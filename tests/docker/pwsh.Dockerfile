# Test environment for clh.ps1: PowerShell 7 with PSReadLine, native for the
# host architecture (the official image is amd64-only and crashes under qemu).
# zsh and jq are here too, so tests/test_sync.zsh can compare all three versions
# in one container (Debian's bash is 5.x).
FROM debian:stable-slim
ARG PWSH_VERSION=7.4.6
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git tmux libicu76 locales zsh jq && rm -rf /var/lib/apt/lists/* \
 && arch=$(dpkg --print-architecture | sed 's/amd64/x64/') \
 && mkdir -p /opt/pwsh \
 && curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz" | tar -xz -C /opt/pwsh \
 && chmod +x /opt/pwsh/pwsh && ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /clh
