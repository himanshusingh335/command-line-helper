#!/usr/bin/env bash
# Install clh for bash (Linux, WSL, Git Bash): check dependencies, pull the
# model, and hook it into ~/.bashrc.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
model=${CLH_MODEL:-qwen2.5-coder:1.5b}

if (( BASH_VERSINFO[0] < 4 )); then
  echo "clh needs bash 4 or newer (this is $BASH_VERSION)"; exit 1
fi
hint() {
  case $1 in
    ollama) echo "curl -fsSL https://ollama.com/install.sh | sh   (Windows: winget install Ollama.Ollama)" ;;
    *) if command -v apt-get >/dev/null; then echo "sudo apt-get install $1"
       elif command -v dnf >/dev/null; then echo "sudo dnf install $1"
       elif command -v pacman >/dev/null; then echo "sudo pacman -S $1"
       else echo "install $1 with your package manager"; fi ;;
  esac
}
for bin in curl jq ollama; do
  command -v $bin >/dev/null || { echo "missing dependency: $bin ($(hint $bin))"; exit 1; }
done

if ! ollama list | awk '{print $1}' | grep -qx "$model"; then
  echo "pulling $model…"
  ollama pull "$model"
fi

line="source $dir/clh.bash"
if grep -qxF "$line" ~/.bashrc 2>/dev/null; then
  echo "already in ~/.bashrc"
else
  printf '\n# command-line-helper (:: <request>)\n%s\n' "$line" >> ~/.bashrc
  echo "added to ~/.bashrc"
fi
echo "done — open a new terminal or run: source ~/.bashrc"
