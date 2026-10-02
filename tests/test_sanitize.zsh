#!/usr/bin/env zsh
# Unit tests for _clh_sanitize and the destructive-command regex.
source ${0:A:h}/../clh.zsh

fails=0
check() {
  local got=$1 want=$2 name=$3
  if [[ $got == $want ]]; then
    print -r -- "ok   $name"
  else
    print -r -- "FAIL $name: got [$got] want [$want]"
    (( fails++ ))
  fi
}

check "$(_clh_sanitize 'git status')"                      'git status'           plain
check "$(_clh_sanitize $'```bash\nls -la\n```')"            'ls -la'               fenced
check "$(_clh_sanitize '$ docker ps')"                      'docker ps'            dollar-prefix
check "$(_clh_sanitize '`conda env list`')"                 'conda env list'       backticks
check "$(_clh_sanitize $'\n   du -sh *  \nexplanation')"    'du -sh *'             first-line-trimmed
_clh_sanitize $'```\n```' >/dev/null;  check $? 1                                  empty-returns-1

danger() { [[ $1 =~ $_CLH_DANGER_RE ]] && print yes || print no }
check "$(danger 'rm -rf build')"            yes  danger-rm
check "$(danger 'sudo lsof -i :80')"        yes  danger-sudo
check "$(danger 'git push --force')"        yes  danger-force-push
check "$(danger 'git reset --hard HEAD~1')" yes  danger-reset-hard
check "$(danger 'docker system prune -a')"  yes  danger-prune
check "$(danger 'git status')"              no   safe-git
check "$(danger 'find . -name "*.py"')"     no   safe-find
check "$(danger 'docker ps')"               no   safe-docker

hint() { _clh_hints "$1" | grep -o 'Answer with: conda [a-z]*' || print none }
check "$(hint 'create conda env in current folder')"  'Answer with: conda create'    hint-create
check "$(hint 'make conda environment HERE')"         'Answer with: conda create'    hint-case-insensitive
check "$(hint 'activate the env in this folder')"     'Answer with: conda activate'  hint-activate
check "$(hint 'delete the local conda env')"          'Answer with: conda remove'    hint-remove
check "$(hint 'create conda env named ml')"           none                           hint-named-env
check "$(hint 'create a venv here')"                  none                           hint-venv
check "$(hint 'list files here')"                     none                           hint-unrelated

(( fails )) && { print "$fails failed"; exit 1 }
print "all passed"
