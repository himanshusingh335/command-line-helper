#!/usr/bin/env zsh
# Unit tests for the deterministic parts of clh.zsh (no model needed).
# Ignore the user's environment and saved settings, and keep every default
# path (history, config) inside a temp dir instead of the real home.
unset -m 'CLH_*'
tmpdir=$(mktemp -d); trap 'rm -rf $tmpdir' EXIT
export HOME=$tmpdir/home XDG_DATA_HOME=$tmpdir/home/.local/share XDG_CONFIG_HOME=$tmpdir/home/.config
CLH_CONFIG_FILE=$tmpdir/config/config.zsh
plugin=${0:A:h:h}/clh.zsh
source $plugin

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

# --- learning and example selection (isolated history file)
CLH_HISTORY_FILE=$tmpdir/clh/history.jsonl
users() { jq -r '[.[] | select(.role == "user") | .content] | join("|")' }

_clh_learn 'deploy to staging' './scripts/deploy.sh staging'
_clh_learn 'nuke build' 'rm -rf build'
CLH_LEARN=0 _clh_learn 'list stuff' 'ls'
check "$(jq -sc 'map(.r)' $CLH_HISTORY_FILE)"   '["deploy to staging"]'  learn-appends-skips-danger-and-off
check "$(stat -f %Lp $CLH_HISTORY_FILE)"        600                     learn-private-file

CLH_HISTORY_MAX=3
for i in 1 2 3; do _clh_learn "req $i" "echo $i"; done
_clh_learn 'REQ 3' 'echo 3b'
check "$(jq -sc 'map(.c)' $CLH_HISTORY_FILE)"  '["echo 1","echo 2","echo 3b"]'  learn-dedupes-and-trims
CLH_HISTORY_MAX=500

_CLH_LEARN_PAIR=('show pods' 'kubectl get pods')
false; _clh_precmd
_CLH_LEARN_PAIR=('show nodes' 'kubectl get nodes')
true; _clh_precmd
check "$(jq -sc '[.[].r | select(startswith("show"))]' $CLH_HISTORY_FILE)"  '["show nodes"]'  learn-only-on-success

rm -f $CLH_HISTORY_FILE
check "$(_clh_select_examples 'x' | jq -c .)" "$(_clh_pair_turns "${_CLH_EXAMPLES[@]}" "${_CLH_FIX_EXAMPLES[@]}")"  select-all-unchanged

CLH_EXAMPLE_MODE=keyword
sel=$(_clh_select_examples 'kill the process on port 3000')
check "$(jq length <<<$sel)"                     16                                        select-keyword-k
check "$(users <<<$sel | awk -F'|' '{print $NF}')" 'kill whatever is running on port 5000' select-keyword-closest-last
check "$(_clh_select_examples 'zzz qqq' | users)" "$(_clh_pair_turns "${(@)_CLH_EXAMPLES[1,16]}" | users)" select-keyword-no-match-defaults
check "$(_clh_select_examples 'gti status' 1 | jq '.[-1].content')"  '"du -h -d 1"'           select-keyword-fix-examples

_clh_learn 'show running docker containers' 'docker ps --format "{{.Names}}"'
_clh_learn 'tail api logs' 'docker compose logs -f api'
check "$(_clh_select_examples 'show running docker containers' | jq -r '.[-1].content')" \
  'docker ps --format "{{.Names}}"'  select-learned-overrides-builtin
check "$(_clh_select_examples 'api logs please' | users | awk -F'|' '{print $NF}')"  'tail api logs'  select-learned-match
CLH_EXAMPLE_MODE=all
check "$(_clh_select_examples 'api logs' | jq -r '.[-2].content')"  'tail api logs'               select-all-appends-learned

# --- settings and the clh command
check "$(parse '::help')"                 'clh|help'                  parse-help
check "$(parse '::settings')"             'clh|settings'              parse-settings
check "$(parse ':: help me find files')"  'new|help me find files'    parse-help-request

setting() { local -a reply; _clh_setting "$1" && print -r -- "$reply[1]|$reply[2]" || print none }
check "$(setting model)"         'CLH_MODEL|str'                        setting-short-name
check "$(setting example-mode)"  'CLH_EXAMPLE_MODE|all|keyword|embed'   setting-dashes
check "$(setting CLH_LEARN)"     'CLH_LEARN|bool'                       setting-full-name
check "$(setting nope)"          none                                   setting-unknown

value() { _clh_check_value "$1" "$2" || print bad }
check "$(value bool on),$(value bool False),$(value bool 2)"               '1,0,bad'    value-bool
check "$(value int 12),$(value int 0),$(value int x)"                      '12,bad,bad' value-int
check "$(value 'all|keyword|embed' embed),$(value 'all|keyword|embed' em)" 'embed,bad'  value-enum

clh set model 'my model:7b' >/dev/null 2>&1
clh set learn off >/dev/null
check "$CLH_MODEL|$CLH_LEARN"                'my model:7b|0'                                      set-applies-now
check "$(clh set timeout soon 2>&1)"         "clh: timeout must be a number, not 'soon'"          set-rejects-bad-value
check "$(clh set colour red 2>&1; print $?)" $'clh: unknown setting \'colour\' (see: clh config)\n1' set-rejects-unknown
check "$(grep -c '^CLH_' $CLH_CONFIG_FILE)"  2                                                    set-saves-once-each
check "$(stat -f %Lp $CLH_CONFIG_FILE)"      600                                                  set-private-file
check "$(_clh_setting_source CLH_MODEL qwen2.5-coder:1.5b)"  saved                                source-saved

# A new shell loads saved values; a non-default value set beforehand wins.
loaded() {
  zsh -fc "unset -m 'CLH_*'; $1 CLH_CONFIG_FILE=$CLH_CONFIG_FILE
           source $plugin; print -r -- \"\$CLH_MODEL|\$CLH_LEARN\""
}
check "$(loaded '')"                               'my model:7b|0'  load-saved
check "$(loaded 'CLH_MODEL=other;')"               'other|0'        load-preset-wins
check "$(loaded 'CLH_MODEL=qwen2.5-coder:1.5b;')"  'my model:7b|0'  load-restated-default-ignored

clh reset model >/dev/null
check "$CLH_MODEL|$(grep -c '^CLH_MODEL=' $CLH_CONFIG_FILE)"  'qwen2.5-coder:1.5b|0'  reset-one
clh reset --all >/dev/null
check "$CLH_LEARN|$([[ -e $CLH_CONFIG_FILE ]] && print kept || print gone)"  '1|gone'  reset-all

CLH_HISTORY_FILE=$tmpdir/clh/history.jsonl   # reset --all restored the default
rm -f $CLH_HISTORY_FILE
_clh_learn 'list pods' 'kubectl get pods'
check "$(clh history 1)"               'list pods  → kubectl get pods'  history-shows-pairs
_clh_learn 'list nodes' 'kubectl get nodes'
_clh_learn 'list files' 'ls'
check "$(clh forget KUBECTL)"          'forgot 2 of 3'                  forget-matching
check "$(clh history | grep -c pods)"  0                                forget-removed

(( fails )) && { print "$fails failed"; exit 1 }
print "all passed"
