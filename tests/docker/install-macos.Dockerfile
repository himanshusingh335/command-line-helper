# Installer test for the macOS path (CLH_OS=macos): Debian with zsh and curl,
# Homebrew replaced by tests/install/fake-brew, and jq hidden in /opt/real so
# that the installer has to "brew install" it.
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends zsh curl jq ca-certificates && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/real && mv /usr/bin/jq /opt/real/jq \
 && ln -s /clh/tests/install/fake-brew /usr/local/bin/brew
ENV CLH_OS=macos SHELL=/bin/zsh
