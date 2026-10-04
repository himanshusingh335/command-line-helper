#!/usr/bin/env bash
# Run the tests, evals and benches in Linux containers (Docker or OrbStack).
# Every suite runs in the image for its shell; the host needs only Docker, plus
# Ollama for eval and bench.
#   tests/run.sh                         # unit tests for every shell + version sync
#   tests/run.sh unit bash               # one shell
#   tests/run.sh eval zsh powershell     # sample requests against the host's Ollama
#   tests/run.sh bench -v                # score example modes (zsh only)
#   tests/run.sh all                     # unit, eval and bench
#   tests/run.sh install                 # installers in fresh distro containers (fake Ollama)
#   tests/run.sh install --real          # also a real Ollama install + model pull (~2 GB)
#   CLH_MODEL=qwen3.5:4b tests/run.sh eval zsh
# Arguments starting with - are passed on to the scripts (bench -v).
root=$(cd "$(dirname "$0")/.." && pwd)
host_url=http://localhost:11434
container_url=http://host.docker.internal:11434

suite=unit shells=() args=()
for a in "$@"; do
  case $a in
    unit|eval|bench|all|install) suite=$a ;;
    zsh|bash|powershell) shells+=("$a") ;;
    -*) args+=("$a") ;;
    *) echo "usage: tests/run.sh [unit|eval|bench|all|install] [zsh|bash|powershell]... [-v|--real]" >&2; exit 2 ;;
  esac
done
all_shells=0
(( ${#shells[@]} )) || { shells=(zsh bash powershell); all_shells=1; }

# Per-shell lookups (case, not associative arrays: macOS has bash 3.2).
image()    { case $1 in zsh) echo clh-zsh ;; bash) echo clh-bash ;; powershell) echo clh-pwsh ;; esac; }
platform() { case $1 in zsh) echo macOS ;; bash) echo Linux ;; powershell) echo Windows ;; esac; }
unit_cmd() {
  case $1 in
    zsh) echo zsh tests/zsh/test.zsh ;;
    bash) echo bash tests/bash/test.sh ;;
    powershell) echo pwsh -NoProfile -File tests/powershell/test.ps1 ;;
  esac
}
eval_cmd() {
  case $1 in
    zsh) echo zsh tests/zsh/eval.zsh ;;
    bash) echo bash tests/bash/eval.sh ;;
    powershell) echo pwsh -NoProfile -File tests/powershell/eval.ps1 ;;
  esac
}

build() {
  local img; img=$(image "$1")
  docker build -q -t "$img" -f "$root/tests/docker/${img#clh-}.Dockerfile" "$root/tests/docker" >/dev/null \
    || { echo "failed to build $img" >&2; exit 1; }
}
# run <shell> <command...>: run in that shell's image with the repo at /clh.
# Model settings set on the host are passed through.
run() {
  local sh=$1; shift
  local env=(-e CLH_URL=$container_url)
  local v; for v in CLH_MODEL CLH_EXAMPLE_MODE CLH_EMBED_MODEL; do [[ -n ${!v} ]] && env+=(-e "$v"); done
  docker run --rm -v "$root:/clh" -w /clh "${env[@]}" "$(image "$sh")" "$@"
}
need_ollama() {
  curl -sf "$host_url/api/version" >/dev/null && return
  echo "Ollama isn't reachable at $host_url. Start it on the host (ollama serve) and retry." >&2
  exit 1
}

# Installer cases: label|image|shell|mode|setup|platform. Stock images have
# nothing installed; check.sh runs with POSIX sh. Arch's image is amd64-only,
# and pacman's sandbox can't start in a container.
install_cases() {
  cat <<'EOF'
Debian (apt, bash)|debian:stable-slim|bash|fake||
Ubuntu (apt, zsh)|ubuntu:24.04|zsh|fake||
Fedora (dnf, bash)|fedora:latest|bash|fake||
openSUSE (zypper, zsh)|opensuse/tumbleweed:latest|zsh|fake||
Arch (pacman, bash)|archlinux:latest|bash|fake|sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf|linux/amd64
Alpine (apk, no Ollama for musl)|alpine:latest|bash|no-ollama||
Debian as a user with sudo|clh-install-sudo|bash|fake||
macOS path, fake Homebrew (zsh)|clh-install-macos|zsh|fake||
macOS path, fake Homebrew (bash)|clh-install-macos|bash|fake||
EOF
  [[ " ${args[*]-} " == *" --real "* ]] && echo "Debian, real Ollama + model|debian:stable-slim|bash|real||"
}
run_install() {
  local label image sh mode setup platform out
  docker build -q -t clh-install-sudo -f "$root/tests/docker/install-sudo.Dockerfile" "$root/tests/docker" >/dev/null \
    && docker build -q -t clh-install-macos -f "$root/tests/docker/install-macos.Dockerfile" "$root/tests/docker" >/dev/null \
    || { echo "failed to build installer images" >&2; exit 1; }
  while IFS='|' read -r label image sh mode setup platform; do
    [[ " ${shells[*]} " == *" $sh "* ]] || continue
    echo "--- install: $label"
    out=$(docker run --rm ${platform:+--platform "$platform"} -v "$root:/clh:ro" "$image" \
            sh -c "${setup:+$setup && }sh /clh/tests/install/check.sh $sh $mode" 2>&1) || status=1
    grep -v '^ok' <<<"$out"
  done < <(install_cases)
  if [[ " ${shells[*]} " == *" powershell "* ]]; then
    echo "--- install: PowerShell 7 on Linux (install.ps1)"
    out=$(run powershell pwsh -NoProfile -File tests/install/check.ps1) || status=1
    grep -v '^ok' <<<"$out"
  fi
}

needed=("${shells[@]}")
[[ $suite == unit || $suite == all ]] && (( all_shells )) && needed+=(powershell)
for sh in $(printf '%s\n' "${needed[@]}" | sort -u); do build "$sh"; done
[[ $suite != unit && $suite != install ]] && need_ollama

status=0
if [[ $suite == unit || $suite == all ]]; then
  for sh in "${shells[@]}"; do
    echo "--- $sh ($(platform "$sh")) unit"
    # Keep the status of the test script, not of grep.
    out=$(run "$sh" $(unit_cmd "$sh")) || status=1
    grep -v '^ok' <<<"$out"
  done
  if (( all_shells )); then
    echo "--- version sync"
    out=$(run powershell zsh tests/test_sync.zsh) || status=1
    grep -v '^ok' <<<"$out"
  fi
fi
if [[ $suite == eval || $suite == all ]]; then
  for sh in "${shells[@]}"; do
    echo "--- $sh ($(platform "$sh")) eval, model at $container_url"
    run "$sh" $(eval_cmd "$sh") || status=1
  done
fi
if [[ $suite == bench || $suite == all ]]; then
  if [[ " ${shells[*]} " == *" zsh "* ]]; then
    echo "--- zsh (macOS) bench, model at $container_url"
    run zsh zsh tests/zsh/bench_examples.zsh ${args[@]+"${args[@]}"} || status=1
  else
    echo "--- bench exists only for zsh; skipped"
  fi
fi
[[ $suite == install ]] && run_install
exit $status
