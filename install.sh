#!/bin/sh
# Install clh (command-line-helper) for zsh or bash. It works out the platform
# and your shell, installs what is missing (curl, jq, bash 4+/zsh, Ollama),
# pulls the model and hooks clh into ~/.zshrc or ~/.bashrc.
#
#   ./install.sh                     from a checkout
#   curl -fsSL https://raw.githubusercontent.com/himanshusingh335/command-line-helper/main/install.sh | sh
#
# Options: --shell zsh|bash|all, --model NAME, --no-model, -y/--yes (don't ask),
#          --uninstall (remove the hook; leaves Ollama, the model and history),
#          --ollama-only (just install Ollama and what it needs; install.ps1
#          uses this on Linux and macOS).
# The model is --model, else CLH_MODEL, else the one saved with `clh set model`,
# else the default.
# Environment: CLH_MODEL, CLH_URL (a remote Ollama: nothing is installed for it).
# For tests: CLH_OS (macos|linux|gitbash), CLH_SRC_URL (repo tarball),
#            CLH_OLLAMA_SCRIPT (Ollama's Linux install script).
#
# Plain POSIX sh, so it also runs under dash, busybox ash and macOS's bash 3.2.
set -u

repo=himanshusingh335/command-line-helper
model=${CLH_MODEL:-}
url=${CLH_URL:-http://localhost:11434}
src_url=${CLH_SRC_URL:-https://github.com/$repo/archive/refs/heads/main.tar.gz}
ollama_script=${CLH_OLLAMA_SCRIPT:-https://ollama.com/install.sh}
data=${XDG_DATA_HOME:-$HOME/.local/share}/clh
begin='# >>> command-line-helper >>>'
end='# <<< command-line-helper <<<'

shells='' yes=0 pull=1 uninstall=0 ollama_only=0 model_note=''
usage() { echo "usage: install.sh [--shell zsh|bash|all] [--model NAME] [--no-model] [-y] [--uninstall]"; }
while [ $# -gt 0 ]; do
  case $1 in
    --shell) [ $# -ge 2 ] || { usage >&2; exit 2; }; shells=$2; shift ;;
    --shell=*) shells=${1#*=} ;;
    --model) [ $# -ge 2 ] || { usage >&2; exit 2; }; model=$2; shift ;;
    --model=*) model=${1#*=} ;;
    --no-model) pull=0 ;;
    -y|--yes) yes=1 ;;
    --uninstall) uninstall=1 ;;
    --ollama-only) ollama_only=1 pull=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case $shells in all) shells='zsh bash' ;; ''|zsh|bash) ;; *) usage >&2; exit 2 ;; esac

if [ -t 1 ]; then bold=$(printf '\033[1m') red=$(printf '\033[31m') off=$(printf '\033[0m')
else bold='' red='' off=''; fi
step() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
warn() { printf '%swarning:%s %s\n' "$red" "$off" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
has_tty() { (: </dev/tty) 2>/dev/null; }

# ---- rc files -------------------------------------------------------------

rc_file() { case $1 in zsh) echo "${ZDOTDIR:-$HOME}/.zshrc" ;; bash) echo "$HOME/.bashrc" ;; esac; }

# Print $1 without the clh block, and without the two lines older installers
# appended ("# command-line-helper (:: <request>)" and "source …/clh.zsh").
# A blank line right before a removed block goes too, so re-runs don't pile up
# blank lines.
strip_hook() {
  awk -v b="$begin" -v e="$end" '
    function flush() { while (nb > 0) { print ""; nb-- } }
    skip { if ($0 == e) skip = 0; next }
    $0 == b { nb = 0; skip = 1; next }
    $0 == "# command-line-helper (:: <request>)" { nb = 0; next }
    /^source .*\/clh\.(zsh|bash)$/ { next }
    /^$/ { nb++; next }
    { flush(); print }
    END { flush() }' "$1"
}

# set_hook FILE [LINE...]: replace the clh block in FILE with LINEs (none: remove it).
set_hook() {
  f=$1; shift
  [ -f "$f" ] || [ $# -gt 0 ] || return 0
  tmp=$(mktemp) || die "mktemp failed"
  if [ -f "$f" ]; then strip_hook "$f" >"$tmp"; fi
  if [ $# -gt 0 ]; then
    [ -s "$tmp" ] && echo >>"$tmp"
    { echo "$begin"; for l in "$@"; do echo "$l"; done; echo "$end"; } >>"$tmp"
  fi
  # cat, not mv: keeps the file's mode and any symlink (dotfile managers).
  cat "$tmp" >"$f" && rm -f "$tmp"
}

quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

if [ $uninstall = 1 ]; then
  for sh in zsh bash; do
    f=$(rc_file $sh)
    [ -f "$f" ] && grep -qE 'clh\.(zsh|bash)' "$f" && { set_hook "$f"; step "removed clh from $f"; }
  done
  [ -f "$HOME/.bash_profile" ] && grep -qxF "$begin" "$HOME/.bash_profile" && set_hook "$HOME/.bash_profile"
  [ -d "$data/src" ] && rm -rf "$data/src" && step "removed $data/src"
  echo "done. Ollama, its models and your learned commands ($data) were left in place."
  exit 0
fi

# ---- platform -------------------------------------------------------------

os=${CLH_OS:-}
if [ -z "$os" ]; then
  case $(uname -s) in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=gitbash ;;
    *) die "unsupported system: $(uname -s)" ;;
  esac
fi
musl=0
[ $os = linux ] && { [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; } && musl=1

pm=''
case $os in
  macos) have brew && pm=brew ;;
  gitbash) have winget && pm=winget ;;
  linux) for p in apt-get dnf yum zypper pacman apk; do have $p && { pm=$p; break; }; done ;;
esac

sudo=''
if [ $os = linux ] && [ "$(id -u)" != 0 ]; then
  if have sudo; then sudo=sudo; elif have doas; then sudo=doas; fi
fi

# Is CLH_URL this machine? Only then is Ollama installed and started here.
hostport=${url#*://}; hostport=${hostport%%/*}
case ${hostport%:*} in localhost|127.0.0.1|0.0.0.0) local_ollama=1 ;; *) local_ollama=0 ;; esac

# Which shells: --shell, else the login shell, else whichever exists.
if [ -z "$shells" ] && [ $ollama_only = 0 ]; then
  login=${SHELL:-}
  case ${login##*/} in
    zsh) shells=zsh ;;
    bash) shells=bash ;;
    pwsh|powershell*) die "for PowerShell, run install.ps1 instead" ;;
    *) if [ $os = gitbash ]; then shells=bash
       elif have zsh; then shells=zsh
       else shells=bash; fi ;;
  esac
fi

# The model saved by `clh set model` for one of these shells. The config file
# holds NAME=value lines quoted by zsh's ${(q)} or bash's %q; model names need
# no more unquoting than dropping backslashes and quotes.
saved_model() {
  for sh in $shells; do
    f=${CLH_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/clh/config.$sh}
    [ -r "$f" ] || continue
    m=$(sed -n 's/^CLH_MODEL=//p' "$f" | tail -n 1 | sed -e 's/^\$//' -e "s/[\\'\"]//g" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$m" ] && { echo "$m"; return; }
  done
}
if [ -z "$model" ] && [ $ollama_only = 0 ]; then
  model=$(saved_model)
  [ -n "$model" ] && model_note=" (saved with clh set)"
fi
model=${model:-qwen2.5-coder:1.5b}

# ---- source files -----------------------------------------------------------

# A checkout has clh.zsh next to this script. When piped from curl, $0 is the
# shell, so the repo is downloaded to $data/src instead.
here=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ $ollama_only = 1 ] || { [ -n "$here" ] && [ -f "$here/clh.zsh" ] && [ -f "$here/clh.bash" ]; }; then
  src=$here remote=0
else src=$data/src remote=1; fi

# ---- what is missing --------------------------------------------------------

pkgs='' notes=''
add_pkg() { case " $pkgs " in *" $1 "*) ;; *) pkgs="${pkgs:+$pkgs }$1" ;; esac; }
# need CMD [PACKAGE]: install PACKAGE (default CMD) if CMD is missing.
need() { have "$1" || add_pkg "${2:-$1}"; }

bash_ok() { have bash && [ "$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)" -ge 4 ]; }

if [ $ollama_only = 1 ]; then
  [ $os = linux ] && need curl
elif [ $os = gitbash ]; then
  need jq jqlang.jq
else
  need curl
  need jq
  [ $remote = 1 ] && { need tar; need gzip; }
  for sh in $shells; do
    case $sh in
      zsh) need zsh; [ $os = linux ] && need perl ;;  # perl detaches `ollama serve`
      bash) bash_ok || add_pkg bash ;;
    esac
  done
fi

# Debian's slim images have no CA certificates, so https would fail.
[ "$pm" = apt-get ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ] && add_pkg ca-certificates

ollama_how=''
if [ $local_ollama = 1 ] && ! have ollama; then
  case $os in
    macos) ollama_how=brew ;;
    gitbash) ollama_how=winget ;;
    linux)
      if [ $musl = 1 ]; then
        notes="$notes
  Ollama has no build for musl/Alpine: run it on another machine and set CLH_URL"
      else
        ollama_how=script
        # Tools Ollama's install script uses.
        need tar; need zstd; need xargs findutils; need awk gawk; need sed; need grep
      fi ;;
  esac
fi
[ $os = macos ] && [ -z "$pm" ] && { [ -n "$pkgs" ] || [ "$ollama_how" = brew ]; } && pm=install-brew

if [ $os = linux ] && [ -n "$pkgs$ollama_how" ] && [ "$(id -u)" != 0 ] && [ -z "$sudo" ]; then
  die "need root to install ${pkgs}${ollama_how:+${pkgs:+ }ollama}: run as root or install sudo"
fi
if [ -n "$pkgs" ] && [ -z "$pm" ]; then
  die "can't find a package manager; install these yourself and re-run: $pkgs"
fi

# ---- plan and confirm -------------------------------------------------------

step "clh installer — $os${pm:+, packages via ${pm#install-}}"
[ "$pm" = install-brew ] && echo "  install Homebrew (https://brew.sh)"
[ -n "$pkgs" ] && echo "  install: $pkgs"
[ -n "$ollama_how" ] && echo "  install Ollama ($ollama_how)"
[ $remote = 1 ] && echo "  download clh to $src"
[ $pull = 1 ] && echo "  pull model $model$model_note"
for sh in $shells; do echo "  add clh to $(rc_file $sh)"; done
[ -n "$notes" ] && echo "note:$notes"
if [ $yes = 0 ] && has_tty; then
  printf 'Continue? [Y/n] ' >/dev/tty
  read -r ans </dev/tty || ans=n
  case $ans in ''|[Yy]*) ;; *) echo "cancelled"; exit 1 ;; esac
fi

# ---- install ---------------------------------------------------------------

pkg_install() {
  case $pm in
    brew) brew install "$@" ;;
    apt-get) $sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
               && $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
    dnf) $sudo dnf install -y -q "$@" ;;
    yum) $sudo yum install -y -q "$@" ;;
    zypper) $sudo zypper --non-interactive --quiet install "$@" ;;
    pacman) $sudo pacman -Sy --noconfirm --needed "$@" ;;
    apk) $sudo apk add -q "$@" ;;
    winget) for p in "$@"; do
              winget install -e --id "$p" --accept-source-agreements --accept-package-agreements || return 1
            done
            # Make winget's links usable without opening a new terminal.
            [ -n "${LOCALAPPDATA:-}" ] && PATH="$PATH:$(cygpath -u "$LOCALAPPDATA")/Microsoft/WinGet/Links" ;;
  esac
}

if [ "$pm" = install-brew ]; then
  step "installing Homebrew"
  NONINTERACTIVE=$yes /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew install failed; get Ollama from https://ollama.com/download and jq with your package manager"
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x $b ] && eval "$($b shellenv)" && break; done
  pm=brew
fi
if [ -n "$pkgs" ]; then
  step "installing $pkgs"
  # shellcheck disable=SC2086
  pkg_install $pkgs || die "package install failed"
fi

case $ollama_how in
  brew) step "installing Ollama"; brew install ollama || die "Ollama install failed" ;;
  winget) step "installing Ollama"; pkg_install Ollama.Ollama || die "Ollama install failed"
          [ -n "${LOCALAPPDATA:-}" ] && PATH="$PATH:$(cygpath -u "$LOCALAPPDATA")/Programs/Ollama" ;;
  script) step "installing Ollama"
          curl -fsSL "$ollama_script" | sh || die "Ollama install failed (see https://ollama.com/download)" ;;
esac

for sh in $shells; do
  if [ $sh = bash ] && ! bash_ok; then
    [ $os = macos ] && for b in /opt/homebrew/bin /usr/local/bin; do [ -x $b/bash ] && PATH="$b:$PATH" && break; done
    bash_ok || die "clh needs bash 4 or newer, and $(command -v bash) is older"
  fi
done

if [ $remote = 1 ]; then
  step "downloading clh to $src"
  tmp=$(mktemp -d) || die "mktemp failed"
  curl -fsSL "$src_url" | tar -xz -C "$tmp" || die "download failed: $src_url"
  top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -f "$top/clh.zsh" ] || die "no clh.zsh in $src_url"
  mkdir -p "$data" && rm -rf "$src" && mv "$top" "$src" && rm -rf "$tmp"
fi

# ---- model -----------------------------------------------------------------

ollama_up() { OLLAMA_HOST=$hostport ollama list >/dev/null 2>&1; }
start_ollama() {
  log=$HOME/.ollama/clh-serve.log
  mkdir -p "$HOME/.ollama"
  step "starting ollama serve (log: $log)"
  if have setsid; then OLLAMA_HOST=$hostport setsid ollama serve >>"$log" 2>&1 </dev/null &
  else OLLAMA_HOST=$hostport nohup ollama serve >>"$log" 2>&1 </dev/null & fi
  i=0
  while [ $i -lt 60 ]; do ollama_up && return 0; sleep 1; i=$((i + 1)); done
  return 1
}
has_model() {
  OLLAMA_HOST=$hostport ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qxF -e "$model" -e "$model:latest"
}

if [ $pull = 1 ]; then
  if [ $local_ollama = 0 ]; then
    if curl -fsS --max-time 5 "$url/api/tags" | grep -qF "\"$model"; then
      step "model $model is available at $url"
    else
      step "pulling $model on $url"
      curl -fsS "$url/api/pull" -d "{\"model\":\"$model\",\"stream\":false}" >/dev/null \
        || warn "couldn't pull $model on $url"
    fi
  elif ! have ollama; then
    warn "Ollama isn't installed, so $model wasn't pulled"
  else
    ollama_up || start_ollama || warn "ollama serve didn't come up; see ~/.ollama/clh-serve.log"
    if has_model; then step "model $model is already installed"
    else
      step "pulling $model"
      OLLAMA_HOST=$hostport ollama pull "$model" || warn "pull failed; later run: ollama pull $model"
    fi
  fi
fi

# ---- hook into the shell ------------------------------------------------------

for sh in $shells; do
  f=$(rc_file $sh)
  set_hook "$f" "source $(quote "$src/clh.$sh")"
  step "added clh to $f"
done
# Login shells (macOS Terminal, Git Bash) read ~/.bash_profile, not ~/.bashrc.
case " $shells " in *" bash "*)
  if [ $os != linux ] && ! grep -qs 'bashrc' "$HOME/.bash_profile"; then
    set_hook "$HOME/.bash_profile" '[ -f ~/.bashrc ] && . ~/.bashrc'
    step "made ~/.bash_profile load ~/.bashrc"
  fi ;;
esac

if [ $ollama_only = 1 ]; then step "done"; exit 0; fi
echo
step "done. Start a new terminal, or run:"
for sh in $shells; do echo "  source $(rc_file $sh)    # $sh"; done
echo "then try:  :: list files changed in the last day"
if [ $os = macos ] && [ "${SHELL:-}" = /bin/bash ] && [ "${shells#*bash}" != "$shells" ]; then
  echo "note: your login shell is macOS's bash 3.2. Switch to the newer bash with:"
  echo "  echo $(command -v bash) | sudo tee -a /etc/shells && chsh -s $(command -v bash)"
fi
