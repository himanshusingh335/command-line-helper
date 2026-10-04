#!/bin/sh
# Installer test, run inside a fresh container with the repo at /clh (read-only):
#   sh /clh/tests/install/check.sh zsh|bash [fake|no-ollama|real]
# fake (default): Ollama's install script is replaced by fake-ollama-install.sh.
# no-ollama: expect Ollama to be skipped (Alpine/musl).
# real: the real Ollama install script, server and model download.
# POSIX sh, because stock images (Alpine) have no bash yet.
target=$1 mode=${2:-fake}
model=qwen2.5-coder:1.5b
begin='# >>> command-line-helper >>>'
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else nok "$d"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
# install NAME ARGS...: run the installer from the checkout, show output on failure.
install() {
  d=$1; shift
  out=$(sh /clh/install.sh "$@" 2>&1); st=$?
  if [ $st = 0 ]; then ok "$d"; else nok "$d (exit $st)"; echo "$out" | sed 's/^/  # /'; fi
}
blocks() { n=$(grep -cxF "$begin" "$1" 2>/dev/null); echo "${n:-0}"; }
loads() {
  case $target in
    zsh) TERM=dumb zsh -ic 'whence -w _clh_accept_line' </dev/null 2>/dev/null | grep -q function ;;
    bash) bash -ic 'declare -F _clh_accept_line' </dev/null 2>/dev/null | grep -q _clh_accept_line ;;
  esac
}
case $target in zsh) rc=$HOME/.zshrc ;; bash) rc=$HOME/.bashrc ;; *) echo "usage: check.sh zsh|bash [mode]"; exit 2 ;; esac

export FAKE_OLLAMA_STATE=$HOME/.fake-ollama
calls=$FAKE_OLLAMA_STATE/calls
[ $mode = fake ] && export CLH_OLLAMA_SCRIPT=file:///clh/tests/install/fake-ollama-install.sh

echo "# $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}"), user $(id -un), ${CLH_OS:-native} $target, $mode"
install "install from checkout" --yes --shell $target
check "curl installed" have curl
check "jq installed" have jq
check "$target installed" have $target
case $mode in
  fake)
    check "ollama installed" have ollama
    check "ollama serve started" grep -qx serve "$calls"
    check "model pulled" grep -qx "pull $model" "$calls" ;;
  no-ollama)
    check "ollama skipped" eval '! have ollama'
    check "musl note shown" eval 'echo "$out" | grep -q musl' ;;
  real)
    check "ollama installed" have ollama
    check "model pulled" eval 'ollama list | grep -q "^$model"' ;;
esac
check "one clh block in $rc" [ "$(blocks "$rc")" = 1 ]
check "block sources the checkout" grep -qF "source '/clh/clh.$target'" "$rc"
check "plugin loads in interactive $target" loads
if [ "${CLH_OS:-}" = macos ] && [ $target = bash ]; then
  check "~/.bash_profile loads ~/.bashrc" grep -q bashrc "$HOME/.bash_profile"
fi

install "second run" --yes --shell $target
check "still one clh block" [ "$(blocks "$rc")" = 1 ]
[ $mode = fake ] && check "model not pulled again" [ "$(grep -c '^pull' "$calls")" = 1 ]

printf 'export KEEP=1\n\n# command-line-helper (:: <request>)\nsource /old/place/clh.%s\nalias ll=ls\n' $target >"$rc"
install "migrate old-style hook" --yes --shell $target
check "old line removed" eval '! grep -q /old/place "$rc"'
check "user lines kept" eval 'grep -qx "export KEEP=1" "$rc" && grep -qx "alias ll=ls" "$rc"'
check "one clh block after migration" [ "$(blocks "$rc")" = 1 ]

# Piped from curl: no checkout next to the script, so it downloads the repo.
pkg=$(mktemp -d) && mkdir "$pkg/command-line-helper-main" \
  && cp /clh/clh.zsh /clh/clh.bash /clh/install.sh "$pkg/command-line-helper-main/" \
  && tar -czf "$pkg/src.tgz" -C "$pkg" command-line-helper-main
src=$HOME/.local/share/clh/src
out=$(cd /tmp && CLH_SRC_URL=file://$pkg/src.tgz sh -s -- --yes --shell $target </clh/install.sh 2>&1); st=$?
if [ $st = 0 ]; then ok "piped install"; else nok "piped install (exit $st)"; echo "$out" | sed 's/^/  # /'; fi
check "repo downloaded to $src" [ -f "$src/clh.$target" ]
check "block sources the download" grep -qF "source '$src/clh.$target'" "$rc"
check "one clh block after piped install" [ "$(blocks "$rc")" = 1 ]
check "plugin loads from the download" loads

out=$(cd /tmp && sh -s -- --uninstall </clh/install.sh 2>&1)
check "uninstall removes the block" [ "$(blocks "$rc")" = 0 ]
check "uninstall removes the download" [ ! -d "$src" ]
check "uninstall keeps user lines" grep -qx "export KEEP=1" "$rc"

# A model saved with `clh set model` (quoted as the plugin writes it) is the
# one pulled, unless --model says otherwise.
if [ $mode = fake ]; then
  mkdir -p "$HOME/.config/clh"
  printf '# clh settings\nCLH_MODEL=saved\\ model:2b\\ \\ \n' >"$HOME/.config/clh/config.$target"
  install "install with a saved model" --yes --shell $target
  check "saved model pulled" grep -qx "pull saved model:2b" "$calls"
  install "install with --model" --yes --shell $target --model other:1b
  check "--model wins over the saved model" grep -qx "pull other:1b" "$calls"
fi
exit $fail
