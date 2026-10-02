#!/usr/bin/env bash
# Run the bash and PowerShell test suites in Linux containers (Docker or
# OrbStack), so they can be checked from macOS.
#   tests/run_containers.sh          # unit tests + version sync
#   tests/run_containers.sh --eval   # also send sample requests to the host's Ollama
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
docker build -q -t clh-bash -f "$root/tests/docker/bash.Dockerfile" "$root/tests/docker" >/dev/null
[[ -f $root/clh.ps1 ]] && docker build -q -t clh-pwsh -f "$root/tests/docker/pwsh.Dockerfile" "$root/tests/docker" >/dev/null

status=0
echo "--- bash (clh.bash)"
docker run --rm -v "$root:/clh" clh-bash bash /clh/tests/test_bash.sh | grep -v '^ok' || status=1
if [[ -f $root/clh.ps1 ]]; then
  echo "--- PowerShell (clh.ps1)"
  docker run --rm -v "$root:/clh" clh-pwsh pwsh -NoProfile -File /clh/tests/test_ps.ps1 | grep -v '^ok' || status=1
fi
echo "--- version sync"
zsh "$root/tests/test_sync.zsh" | grep -v '^ok' || status=1

if [[ $1 == --eval ]]; then
  url=http://host.docker.internal:11434
  echo "--- bash eval (model at $url)"
  docker run --rm -v "$root:/clh" -e CLH_URL=$url clh-bash bash /clh/tests/eval_bash.sh
  if [[ -f $root/clh.ps1 ]]; then
    echo "--- PowerShell eval (model at $url)"
    docker run --rm -v "$root:/clh" -e CLH_URL=$url clh-pwsh pwsh -NoProfile -File /clh/tests/eval_ps.ps1
  fi
fi
exit $status
