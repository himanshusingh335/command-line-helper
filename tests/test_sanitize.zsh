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

parse() { local -a reply; _clh_parse "$1"; print -r -- "${(j:|:)reply}" }
check "$(parse ':: list containers')"                    'new|list containers'                 parse-new
check "$(parse '::list containers')"                     'new|list containers'                 parse-new-nospace
check "$(parse ':: ')"                                   'new|'                                parse-new-empty
check "$(parse '::fix')"                                 'fix'                                 parse-fix
check "$(parse '  ::fix   ')"                            'fix'                                 parse-fix-spaces
check "$(parse '::fixed it')"                            'new|fixed it'                        parse-fix-prefix-only
check "$(parse '::? rm -rf build')"                      'explain|rm -rf build'                parse-explain-prefix
check "$(parse 'rm -rf build ::?')"                      'explain|rm -rf build'                parse-explain-suffix
check "$(parse 'find . -size +1M :: only py files')"     'refine|find . -size +1M|only py files' parse-refine
check "$(parse 'a :: b :: c')"                           'refine|a :: b|c'                     parse-refine-last
check "$(parse 'echo a::b')"                             'run'                                 parse-no-space
check "$(parse 'echo "x ::?y"')"                         'run'                                 parse-explain-mid
check "$(parse 'git status')"                            'run'                                 parse-run
check "$(parse '')"                                      'run'                                 parse-empty

fixmsg() { _clh_fix_msg "$1" $2 | grep -o 'exit code .*[)a-z]' | head -1 }
check "$(fixmsg 'gti status' 127)"   "exit code 127: 'gti' is not a known command (probably misspelled)" fixmsg-127
check "$(fixmsg 'git psuh' 1)"       'exit code 1 (likely wrong flags or arguments)'                     fixmsg-1
check "$(fixmsg 'zzqq x' 1)"         "exit code 1: 'zzqq' is not a known command (probably misspelled)"   fixmsg-unknown-cmd

check "$(CLH_URL=http://example.com:11434 _clh_start_server 2>&1)" \
  'clh: cannot reach Ollama at http://example.com:11434 (not local, so not starting it)'  autostart-remote-refused
check "$(CLH_URL=http://localhost:1 _clh_server_up; print $?)"  7                        server-up-detects-down

(( fails )) && { print "$fails failed"; exit 1 }
print "all passed"
