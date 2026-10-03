#!/usr/bin/env bash
# Run the tests, evals and benches in Linux containers (Docker or OrbStack).
# Every suite runs in the image for its shell; the host needs only Docker, plus
# Ollama for eval and bench.
#   tests/run.sh                         # unit tests for every shell + version sync
#   tests/run.sh unit bash               # one shell
#   tests/run.sh eval zsh powershell     # sample requests against the host's Ollama
#   tests/run.sh bench -v                # score example modes (zsh only)
#   tests/run.sh all                     # unit, eval and bench
#   CLH_MODEL=qwen3.5:4b tests/run.sh eval zsh
# Arguments starting with - are passed on to the scripts (bench -v).
root=$(cd "$(dirname "$0")/.." && pwd)
host_url=http://localhost:11434
container_url=http://host.docker.internal:11434

suite=unit shells=() args=()
for a in "$@"; do
  case $a in
    unit|eval|bench|all) suite=$a ;;
    zsh|bash|powershell) shells+=("$a") ;;
    -*) args+=("$a") ;;
    *) echo "usage: tests/run.sh [unit|eval|bench|all] [zsh|bash|powershell]... [-v]" >&2; exit 2 ;;
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

needed=("${shells[@]}")
[[ $suite == unit || $suite == all ]] && (( all_shells )) && needed+=(powershell)
for sh in $(printf '%s\n' "${needed[@]}" | sort -u); do build "$sh"; done
[[ $suite != unit ]] && need_ollama

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
exit $status
