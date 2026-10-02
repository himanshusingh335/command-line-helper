#!/usr/bin/env zsh
# Install clh: check dependencies, pull the model, and hook it into ~/.zshrc.
set -e
dir=${0:A:h}
model=${CLH_MODEL:-qwen2.5-coder:1.5b}

for bin in curl jq ollama; do
  command -v $bin >/dev/null || { print "missing dependency: $bin (brew install $bin)"; exit 1 }
done

if ! ollama list | awk '{print $1}' | grep -qx "$model"; then
  print "pulling $model…"
  ollama pull "$model"
fi

line="source $dir/clh.zsh"
if grep -qxF "$line" ~/.zshrc 2>/dev/null; then
  print "already in ~/.zshrc"
else
  print "\n# command-line-helper (:: <request>)\n$line" >> ~/.zshrc
  print "added to ~/.zshrc"
fi
print "done — open a new terminal or run: source ~/.zshrc"
