#!/usr/bin/env zsh
# Run sample requests through the model and print the generated commands.
#   ./tests/eval.sh                      # default model
#   CLH_MODEL=smollm2:1.7b ./tests/eval.sh
zmodload zsh/datetime
CLH_WARM=0 source ${0:A:h}/../clh.zsh

queries=(
  # zsh / system
  "show my PATH one entry per line"
  "how much free disk space"
  "kill the process on port 3000"
  "show the 10 largest files in this folder"
  # python
  "run tests with pytest verbose"
  "start a simple http server on port 8000"
  "freeze installed packages to requirements.txt"
  "upgrade pip"
  # conda
  "activate the ml environment"
  "export current conda env to yaml"
  "delete conda env named old"
  "install numpy with conda from conda-forge"
  "create conda env in current folder"
  "create a new python env in this folder using conda -p"
  "make conda environment here with python 3.10"
  "activate the env in this folder"
  "delete the conda env in this directory"
  "local conda env python 3.12 with numpy"
  "use the conda env here"
  "create a venv here"
  # docker
  "stop all running containers"
  "remove dangling images"
  "start docker compose in background"
  "build image tagged myapp from this directory"
  # git
  "discard changes to main.py"
  "show what changed in last commit"
  "list all branches including remote"
  "stash my changes with a message wip"
  # file
  "make deploy.sh executable"
  "compress the logs folder into logs.tar.gz"
  "count lines in all python files"
  # search
  "find all files named config.yaml"
  "search for the word password ignoring case recursively"
)

for q in $queries; do
  s=$EPOCHREALTIME
  out=$(_clh_generate "$q" 2>&1)
  printf '%-55s → %s  (%.2fs)\n' "$q" "$out" $(( EPOCHREALTIME - s ))
done
