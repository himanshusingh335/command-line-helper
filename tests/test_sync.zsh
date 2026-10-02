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

  # clh.ps1 reimplements _CLH_JQ_LIB; given the same examples and history it
  # must pick the same examples, in the same order.
  tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
  zsh -fc "source $root/clh.zsh; print -rl -- \"\${_CLH_EXAMPLES[@]}\"" > $tmp/examples.txt
  print -l 'kill the process on port 3000' 'show running docker containers' 'undo my last commit' \
    'make a conda environment here with python 3.10' 'show the biggest files in this folder' \
    'follow api logs please' 'deploy it to staging now' 'zzz qqq' > $tmp/queries.txt
  print -l '{"r":"tail api logs","c":"docker compose logs -f api","t":100}' \
    '{"r":"deploy to staging","c":"./deploy.sh staging","t":100}' \
    '{"r":"show running docker containers","c":"docker ps --format x","t":90}' > $tmp/history.jsonl
  cat > $tmp/select.ps1 <<'EOF'
param($dir, $mode)
$env:CLH_HISTORY_FILE = "$dir/history.jsonl"; $env:CLH_CONFIG_FILE = "$dir/none.json"; $env:CLH_EXAMPLE_MODE = $mode
. "$env:CLH_ROOT/clh.ps1"
$global:_CLH_EXAMPLES = @(Get-Content "$dir/examples.txt")
foreach ($q in Get-Content "$dir/queries.txt") {
  $turns = _clh_select_examples $q
  ConvertTo-Json -Compress -InputObject @($turns | Where-Object { $_.role -eq 'user' -and $_.content -notlike 'This command*' } | ForEach-Object { $_.content })
}
EOF
  for mode in keyword all; do
    want=$(zsh -fc "unset -m 'CLH_*'; CLH_CONFIG_FILE=/dev/null CLH_HISTORY_FILE=$tmp/history.jsonl
      source $root/clh.zsh; CLH_EXAMPLE_MODE=$mode
      while IFS= read -r q; do _clh_select_examples \"\$q\" | jq -c '[.[] | select(.role == \"user\") | .content | select(startswith(\"This command\") | not)]'; done < $tmp/queries.txt")
    if command -v pwsh >/dev/null; then
      got=$(CLH_ROOT=$root pwsh -NoProfile -File $tmp/select.ps1 $tmp $mode | jq -c .)
    else
      got=$(docker run --rm -e CLH_ROOT=/clh -v $root:/clh -v $tmp:/t clh-pwsh pwsh -NoProfile -File /t/select.ps1 /t $mode | jq -c .)
    fi
    check "$got" "$want" pwsh-ranking-$mode
  done
fi

(( fails )) && { print "$fails failed"; exit 1 }
print "all passed"
