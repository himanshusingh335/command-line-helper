#!/bin/sh
# Stand-in for https://ollama.com/install.sh: checks for the tools the real
# script requires, then installs fake-ollama as /usr/local/bin/ollama.
set -e
for t in curl awk grep sed tee xargs tar zstd; do
  command -v $t >/dev/null || { echo "fake ollama install: missing $t" >&2; exit 1; }
done
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo
$SUDO install -m 755 /clh/tests/install/fake-ollama /usr/local/bin/ollama
echo ">>> fake Ollama installed"
