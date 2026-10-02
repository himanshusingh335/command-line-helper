#!/usr/bin/env zsh
# Check that the zsh, bash and PowerShell versions agree where they must:
# setting names, types and (non-path) defaults everywhere; few-shot and fix
# examples between zsh and bash. Prompts are platform-specific on purpose.
# bash and pwsh run in Docker when they aren't installed locally (bash 4+).
root=${0:A:h:h}
fails=0
check() {
  if [[ $1 == $2 ]]; then print -r -- "ok   $3"
  else print -r -- "FAIL $3"; diff <(print -r -- $2) <(print -r -- $1) | head -20; (( fails++ )); fi
}

# Settings whose default is a path differ per platform by design.
paths='["CLH_OLLAMA_LOG", "CLH_HISTORY_FILE"]'
settings() { jq -c --argjson p $paths '.settings | map(if IN(.n; $p[]) then del(.d) else . end)' }

zsh_data=$(zsh -fc "source $root/clh.zsh; _clh_dump_data")

if (( ${${$(bash -c 'echo $BASH_VERSINFO' 2>/dev/null)}:-0} >= 4 )); then
  bash_data=$(bash --norc -c "source $root/clh.bash; _clh_dump_data")
else
  bash_data=$(docker run --rm -v $root:/clh clh-bash bash --norc -c 'source /clh/clh.bash; _clh_dump_data')
fi
check "$(settings <<<$bash_data)"              "$(settings <<<$zsh_data)"              bash-settings
check "$(jq -c .examples <<<$bash_data)"       "$(jq -c .examples <<<$zsh_data)"       bash-examples
check "$(jq -c .fix_examples <<<$bash_data)"   "$(jq -c .fix_examples <<<$zsh_data)"   bash-fix-examples

if [[ -f $root/clh.ps1 ]]; then
  if command -v pwsh >/dev/null; then
    ps_data=$(pwsh -NoProfile -Command ". '$root/clh.ps1'; _clh_dump_data")
  else
    ps_data=$(docker run --rm -v $root:/clh clh-pwsh pwsh -NoProfile -Command '. /clh/clh.ps1; _clh_dump_data')
  fi
  check "$(settings <<<$ps_data)"  "$(settings <<<$zsh_data)"  pwsh-settings
fi

(( fails )) && { print "$fails failed"; exit 1 }
print "all passed"
