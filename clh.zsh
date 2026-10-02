# clh.zsh — natural-language → shell command helper for zsh, powered by Ollama.
#
#   :: <what you want>     Enter → the generated command replaces the line
#   Enter again                   → run it
#   Tab                           → discard it
#   Ctrl-N                        → another suggestion for the same request
#   <cmd> :: <change>       Enter → revise the command on the line
#   <cmd> ::?  or  ::? <cmd> Enter → explain a command without running it
#   ::fix                   Enter → correct the last command you ran
#
# Source this file from ~/.zshrc. Requires curl, jq and a running Ollama server.

: ${CLH_MODEL:=qwen2.5-coder:1.5b}
: ${CLH_URL:=http://localhost:11434}
: ${CLH_PREFIX:=::}
: ${CLH_TIMEOUT:=30}
: ${CLH_WARM:=1}
: ${CLH_AUTOSTART:=1}
: ${CLH_OLLAMA_LOG:=$HOME/.ollama/clh-serve.log}
: ${CLH_LEARN:=1}
: ${CLH_HISTORY_FILE:=${XDG_DATA_HOME:-$HOME/.local/share}/clh/history.jsonl}
: ${CLH_HISTORY_MAX:=500}
: ${CLH_EXAMPLE_MODE:=all}
: ${CLH_EXAMPLES_K:=8}
: ${CLH_EMBED_MODEL:=nomic-embed-text}

typeset -g _CLH_PENDING=0 _CLH_LAST_STATUS=0
# Conversation behind the generated command (role/content pairs) and the
# commands already suggested for it; both live only while it is pending.
typeset -ga _CLH_TURNS=() _CLH_SEEN=()
# The request behind the pending command, and the request / command pair
# waiting for its exit status before it is learned.
typeset -g _CLH_REQUEST=
typeset -ga _CLH_LEARN_PAIR=()

# Commands that deserve an extra look before running.
typeset -g _CLH_DANGER_RE='(^|[;&| ])(sudo|rm -[a-zA-Z]*[rf]|dd |mkfs|shred|diskutil (erase|partition)|chmod -R 777|kill -9 -1)|> ?/dev/|git (push.*(-f|--force)|reset --hard|clean -[a-z]*f)|docker (system|volume|image) prune|conda (env )?remove'

typeset -g _CLH_SYSTEM='You are a command-line expert. Convert the user request into ONE shell command for zsh on macOS.
Rules:
- Output ONLY the command on a single line. No explanation, no markdown, no backticks, no leading "$".
- Combine multiple steps with && on the same line.
- macOS uses BSD tools: sed -i '\'''\'', stat -f, date -v, pbcopy, open. Homebrew is available.
- Prefer common tools: git, docker, docker compose, conda, python3, pip, find, grep, du, lsof, tar.
- Only use flags that exist on macOS (no grep -P, no GNU-only options).
- conda env "here" / "in this folder" / "local" / "-p" means a prefix env: conda create -p ./.conda ..., activated with conda activate ./.conda.
- Do exactly what was asked: never add destructive or extra flags (like --hard, -a, -f, file filters) the user did not ask for.
- Use the context (directory, files, git branch, conda env) when it helps; use placeholders like <name> only when the value is truly unknown.'

typeset -g _CLH_EXPLAIN_SYSTEM='You explain shell commands for zsh on macOS.
Reply with ONE short plain sentence (at most 20 words) saying exactly what the command does. No markdown.'

typeset -ga _CLH_EXPLAIN_EXAMPLES=(
  user 'docker ps -a'                     assistant 'Lists all Docker containers, including stopped ones.'
  user 'git stash pop'                    assistant 'Re-applies your most recently stashed changes and removes them from the stash.'
  user 'find . -name "*.log" -delete'     assistant 'Deletes every .log file in this folder and its subfolders.'
  user 'lsof -i :8080'                    assistant 'Shows which process is listening on port 8080.'
)

# Few-shot examples: alternating request / command.
typeset -ga _CLH_EXAMPLES=(
  'create a python virtual environment and activate it'    'python3 -m venv .venv && source .venv/bin/activate'
  'make a venv here'                                       'python3 -m venv .venv'
  'install packages from requirements file'                'pip install -r requirements.txt'
  'create conda env named ml with python 3.11'             'conda create -n ml python=3.11 -y'
  'make a conda env in this folder'                        'conda create -p ./.conda python=3.11 -y'
  'local conda env with python 3.9 and pandas'             'conda create -p ./.conda python=3.9 pandas -y'
  'activate the conda env in this folder'                  'conda activate ./.conda'
  'remove the local conda env'                             'conda remove -p ./.conda --all -y'
  'list conda environments'                                'conda env list'
  'show running docker containers'                         'docker ps'
  'start compose services in background'                   'docker compose up -d'
  'follow logs of container web'                           'docker logs -f web'
  'open a shell inside container api'                      'docker exec -it api /bin/sh'
  'undo last commit but keep the changes'                  'git reset --soft HEAD~1'
  'create and switch to branch feature/login'              'git switch -c feature/login'
  'show git history as a graph'                            'git log --oneline --graph --decorate --all'
  'discard local changes to app.js'                        'git restore app.js'
  'show files changed in last commit'                      'git show --stat HEAD'
  'show size of each folder here sorted'                   'du -sh * | sort -h'
  'extract archive.tar.gz'                                 'tar -xzf archive.tar.gz'
  'search for TODO in all python files'                    'grep -rn "TODO" --include="*.py" .'
  'search for error ignoring case'                         'grep -rni "error" .'
  'count lines in all js files'                            'find . -name "*.js" -type f -exec cat {} + | wc -l'
  'show the 5 biggest files here'                          'ls -lhS | head -n 6'
  'find files bigger than 100MB'                           'find . -type f -size +100M'
  'what is using port 8080'                                'lsof -i :8080'
  'kill whatever is running on port 5000'                  'kill $(lsof -ti :5000)'
)

# Fix examples (same wording as _clh_fix_msg), used for ::fix.
typeset -g _CLH_FIX_TAIL='Output only the corrected command.'
typeset -ga _CLH_FIX_EXAMPLES=(
  $'This command failed with exit code 127: \'dokcer\' is not a known command (probably misspelled):\ndokcer ps -a\nOutput only the corrected command.'      'docker ps -a'
  $'This command failed with exit code 127: \'pyhton\' is not a known command (probably misspelled):\npyhton main.py\nOutput only the corrected command.'    'python3 main.py'
  $'This command failed with exit code 1 (likely wrong flags or arguments):\ngit comit -m "init"\nOutput only the corrected command.'                          'git commit -m "init"'
  $'This command failed with exit code 1 (likely wrong flags or arguments):\ndu -sh --max-depth=1\nOutput only the corrected command.'                           'du -h -d 1'
)

# --- core -------------------------------------------------------------------

# Clean raw model output into a single command line.
_clh_sanitize() {
  emulate -L zsh
  setopt extendedglob
  local line
  for line in "${(@f)1}"; do
    line=${line##[[:space:]]#}
    line=${line%%[[:space:]]#}
    [[ -z $line || $line == '```'* ]] && continue
    line=${line#(\$|%|>) }
    if [[ $line == \`*\` ]]; then
      line=${line#\`}
      line=${line%\`}
    fi
    print -r -- "$line"
    return 0
  done
  return 1
}

_clh_context() {
  emulate -L zsh
  local branch files
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  files=(${(f)"$(command ls -1A 2>/dev/null | head -n 25)"})
  print -r -- "Context:
- OS: macOS $(sw_vers -productVersion 2>/dev/null), shell: zsh
- Current directory: $PWD
- Files here: ${(j:, :)files:-none}
- Git branch: ${branch:-not a git repo}
- Conda env: ${CONDA_DEFAULT_ENV:-none}"
}

# Extra hints for phrasings small models tend to get wrong.
_clh_hints() {
  emulate -L zsh
  setopt nocasematch
  local q=$1
  if [[ $q =~ '(conda|env|environment)' && $q != *(venv|virtualenv)* \
        && $q =~ '(here|this (folder|dir|directory)|current (folder|dir|directory)|local|-p|prefix)' ]]; then
    local tpl
    if [[ $q =~ '(activate|use|switch|enter)' ]]; then
      tpl='conda activate ./.conda'
    elif [[ $q =~ '(delete|remove|destroy|uninstall)' ]]; then
      tpl='conda remove -p ./.conda --all -y'
    else
      tpl='conda create -p ./.conda python=3.11 -y (change the python version / add packages if asked)'
    fi
    print -r -- "IMPORTANT: the env lives in the folder ./.conda. Use -p ./.conda, never -n and never just \".\". Answer with: $tpl"
  fi
}

# Build a messages array from alternating role / content arguments.
_clh_turns() {
  jq -nc '[$ARGS.positional as $e | range(0; $e | length; 2) as $i
           | {role: $e[$i], content: $e[$i + 1]}]' --args "$@"
}

# Send one chat request and print the raw reply.
#   _clh_chat <system> <temperature> <num_predict> <messages-json>
# Returns non-zero and prints an error on stderr on failure.
_clh_chat() {
  emulate -L zsh
  local sys=$1 temp=$2 npred=$3 msgs=$4 payload response err

  payload=$(jq -nc \
    --arg model "$CLH_MODEL" --arg sys "$sys" \
    --argjson temp $temp --argjson npred $npred --argjson msgs "$msgs" \
    '{model: $model, stream: false, think: false, keep_alive: "30m",
      options: {temperature: $temp, num_predict: $npred},
      messages: ([{role: "system", content: $sys}] + $msgs)}') \
    || { print -u2 "clh: failed to build request (jq)"; return 1 }

  response=$(curl -sS --max-time $CLH_TIMEOUT "$CLH_URL/api/chat" -d "$payload" 2>&1) || {
    print -u2 "clh: cannot reach Ollama at $CLH_URL — is 'ollama serve' running?"
    return 1
  }

  err=$(jq -r '.error // empty' <<<"$response" 2>/dev/null)
  if [[ -n $err ]]; then
    [[ $err == *"not found"* ]] && err+=" — run: ollama pull $CLH_MODEL"
    print -u2 "clh: $err"
    return 1
  fi

  jq -r '.message.content // empty' <<<"$response" 2>/dev/null
}

# Print a command for a conversation (few-shots are prepended).
#   _clh_complete <temperature> <query> <role> <content> [<role> <content> ...]
# <query> is the plain request (or command) used to pick similar examples.
_clh_complete() {
  emulate -L zsh
  local temp=$1 query=$2; shift 2
  local msgs content fix=0
  [[ ${@[-1]} == *"$_CLH_FIX_TAIL"* ]] && fix=1
  msgs=$(jq -nc --argjson a "$(_clh_select_examples "$query" $fix)" --argjson b "$(_clh_turns "$@")" '$a + $b')
  content=$(_clh_chat "$_CLH_SYSTEM" $temp 120 "$msgs") || return 1
  _clh_sanitize "$content" || { print -u2 "clh: model returned no command"; return 1 }
}

# Alternating request / command arguments → user / assistant turns.
_clh_pair_turns() {
  jq -nc '[$ARGS.positional as $e | range(0; $e | length; 2) as $i
           | {role: "user", content: $e[$i]}, {role: "assistant", content: $e[$i + 1]}]' \
    --args "$@"
}

# --- learned and similar examples -------------------------------------------

# jq helpers. Pool items are {r: request, c: command, l: learned, t: time};
# rankers add a similarity score s.
typeset -g _CLH_JQ_LIB='
def stop: ["a","an","the","in","of","to","for","on","with","and","or","me","my",
           "i","it","is","all","this","that","from","by","please","can","you","how","do","what"];
def toks: [ascii_downcase | scan("[a-z0-9]+") | select(IN(stop[]) | not)
           | if length > 3 and endswith("s") and (endswith("ss") | not) then .[:-1] else . end]
          | unique;
def keyword($q):
  length as $n | map(.r | toks) as $pt | ($q | toks) as $qt
  | (reduce $pt[][] as $w ({}; .[$w] += 1)) as $df
  | [range($n) as $i | .[$i] + {s: (([$pt[$i][] | select(IN($qt[])) | ($n + 1) / $df[.] | log] | add // 0)
                                    / ([$pt[$i] | length, 1] | max | sqrt))}];
def cos($a; $b): ([range($a | length) as $i | $a[$i] * $b[$i]] | add)
                 / ((([$a[] | . * .] | add) * ([$b[] | . * .] | add)) | sqrt);
# The $k best matches, closest last; unmatched slots go to the first built-ins.
def pick($k):
  ([.[] | select(.s > 0)] | sort_by([-.s, (if .l then 0 else 1 end), -(.t // 0)]) | .[:$k]) as $top
  | ([.[] | select(.s <= 0 and (.l | not))] | .[:($k - ($top | length))]) + ($top | reverse);
def turns: [.[] | {role: "user", content: .r}, {role: "assistant", content: .c}];
'

# Remember a request and the command the user ran for it.
_clh_learn() {
  emulate -L zsh
  zmodload zsh/datetime
  local req=$1 cmd=$2 f=$CLH_HISTORY_FILE tmp
  (( CLH_LEARN )) || return 0
  [[ -n $req && -n $cmd && $cmd != *$'\n'* ]] || return 0
  [[ $cmd =~ $_CLH_DANGER_RE ]] && return 0
  ( umask 077
    mkdir -p -- ${f:h} &&
    jq -nc --arg r "$req" --arg c "$cmd" --argjson t $EPOCHSECONDS '{r: $r, c: $c, t: $t}' >> $f ) || return 1
  if (( $(wc -l < $f) > CLH_HISTORY_MAX )); then
    tmp=$f.$$
    jq -c -s --argjson max $CLH_HISTORY_MAX \
      'group_by(.r | ascii_downcase) | map(max_by(.t)) | sort_by(.t) | .[-$max:][]' $f > $tmp &&
      mv -f -- $tmp $f
  fi
}

# Learned pairs (newest per request) followed by the built-in examples.
_clh_pool() {
  emulate -L zsh
  local learned='[]'
  if [[ -r $CLH_HISTORY_FILE ]]; then
    learned=$(jq -c -s 'map(select(.r and .c)) | group_by(.r | ascii_downcase)
                        | map(max_by(.t) | {r, c, t, l: true})' $CLH_HISTORY_FILE 2>/dev/null) || learned='[]'
  fi
  jq -nc --argjson l "$learned" \
    '($l | map(.r | ascii_downcase)) as $seen
     | $l + [$ARGS.positional as $e | range(0; $e | length; 2) as $i
             | {r: $e[$i], c: $e[$i + 1]} | select(.r | ascii_downcase | IN($seen[]) | not)]' \
    --args "${_CLH_EXAMPLES[@]}"
}

_clh_rank_keyword() {
  jq -c --arg q "$1" "$_CLH_JQ_LIB"' keyword($q)' <<<"$2"
}

# Embed texts with $CLH_EMBED_MODEL; prints a JSON array of vectors.
_clh_embed() {
  emulate -L zsh
  local payload resp
  payload=$(jq -nc --arg m "$CLH_EMBED_MODEL" '{model: $m, input: $ARGS.positional, keep_alive: "30m"}' --args "$@")
  resp=$(curl -sS --max-time $CLH_TIMEOUT "$CLH_URL/api/embed" -d "$payload" 2>/dev/null) || return 1
  jq -ce '.embeddings | select(type == "array" and length > 0)' <<<"$resp" 2>/dev/null
}

# Score the pool by cosine similarity. Example vectors are cached next to
# the history file, so usually only the query is embedded.
_clh_rank_embed() {
  emulate -L zsh
  local q=$1 pool=$2 cache=${CLH_HISTORY_FILE:h}/embed-cache.jsonl vecs
  local -a missing
  missing=(${(f)"$(jq -r --arg m "$CLH_EMBED_MODEL" --slurpfile c <([[ -r $cache ]] && cat $cache) \
    '[$c[] | select(.m == $m) | .t] as $have | [.[].r] | unique[] | select(IN($have[]) | not)' <<<"$pool")"})
  vecs=$(_clh_embed "$q" "${missing[@]}") || return 1
  if (( ${#missing} )); then
    ( umask 077; mkdir -p -- ${cache:h} &&
      jq -c --arg m "$CLH_EMBED_MODEL" '.[1:] as $v | $ARGS.positional | to_entries[] | {m: $m, t: .value, e: $v[.key]}' \
        --args "${missing[@]}" <<<"$vecs" >> $cache ) || return 1
  fi
  jq -c --arg m "$CLH_EMBED_MODEL" --argjson pool "$pool" --slurpfile c $cache "$_CLH_JQ_LIB"'
    ($c | map(select(.m == $m) | {key: .t, value: .e}) | from_entries) as $E | .[0] as $qv
    | $pool | map(. + {s: (if $E[.r] then cos($E[.r]; $qv) else 0 end)})' <<<"$vecs"
}

# Few-shot turns for a query. CLH_EXAMPLE_MODE:
#   all      every built-in example plus the 3 closest learned pairs
#   keyword  the CLH_EXAMPLES_K most similar examples by shared words
#   embed    the same by embedding similarity (falls back to keyword)
# Fix examples are added for ::fix (always in "all" mode).
#   _clh_select_examples <query> [<fix:0|1>]
_clh_select_examples() {
  emulate -L zsh
  local q=$1 fix=${2:-0} pool scored fixes='[]'
  pool=$(_clh_pool) || return 1
  if (( fix )) || [[ $CLH_EXAMPLE_MODE != (keyword|embed) ]]; then
    fixes=$(_clh_pair_turns "${_CLH_FIX_EXAMPLES[@]}")
  fi
  case $CLH_EXAMPLE_MODE in
    embed)   scored=$(_clh_rank_embed "$q" "$pool") || scored=$(_clh_rank_keyword "$q" "$pool") ;;
    keyword) scored=$(_clh_rank_keyword "$q" "$pool") ;;
    *)
      jq -c --argjson f "$fixes" "$_CLH_JQ_LIB"'
        (map(select(.l | not)) | turns) + $f + (map(select(.l)) | pick(3) | turns)' \
        <<<"$(_clh_rank_keyword "$q" "$pool")"
      return
      ;;
  esac
  jq -c --argjson k $CLH_EXAMPLES_K --argjson f "$fixes" "$_CLH_JQ_LIB"' (pick($k) | turns) + $f' <<<"$scored"
}

# User messages for each kind of request.
_clh_request_msg() {
  print -r -- "$(_clh_context)

Request: $1
$(_clh_hints "$1")"
}

_clh_refine_msg() {
  print -r -- "Revise the command: $1. Output the full revised command only."
}

_clh_fix_msg() {
  emulate -L zsh
  local cmd=$1 st=$2 first=${${(z)1}[1]} why
  if (( st == 0 )); then
    why="This command ran but did not do what the user wanted"
  elif (( st == 127 )) || ! whence -- "$first" >/dev/null; then
    why="This command failed with exit code $st: '$first' is not a known command (probably misspelled)"
  else
    why="This command failed with exit code $st (likely wrong flags or arguments)"
  fi
  print -r -- "$(_clh_context)

$why:
$cmd
$_CLH_FIX_TAIL"
}

# --- Ollama server ----------------------------------------------------------

_clh_server_up() {
  curl -s --max-time 1 "$CLH_URL/api/version" >/dev/null 2>&1
}

# Start `ollama serve` in its own session (so Ctrl-C or closing the terminal
# doesn't kill it) and wait for it to answer. Only for a server on this machine.
_clh_start_server() {
  emulate -L zsh
  local hostport=${${CLH_URL#*://}%%/*} deadline=$(( SECONDS + 60 ))
  if [[ $hostport != (localhost|127.0.0.1|0.0.0.0)(:*|) ]]; then
    print -u2 "clh: cannot reach Ollama at $CLH_URL (not local, so not starting it)"
    return 1
  fi
  if ! command -v ollama >/dev/null; then
    print -u2 "clh: ollama is not installed (brew install ollama)"
    return 1
  fi
  mkdir -p ${CLH_OLLAMA_LOG:h}
  ( OLLAMA_HOST=$hostport perl -MPOSIX -e 'POSIX::setsid(); POSIX::close($_) for 3..255; exec @ARGV' ollama serve \
      >>$CLH_OLLAMA_LOG 2>&1 </dev/null & ) 2>/dev/null
  # On first start Ollama can spend ~20s detecting the GPU before answering.
  while (( SECONDS < deadline )); do
    _clh_server_up && return 0
    sleep 0.5
  done
  print -u2 "clh: started ollama but it did not respond — see $CLH_OLLAMA_LOG"
  return 1
}

# Print the generated command for a natural-language query.
_clh_generate() {
  _clh_complete 0 "$1" user "$(_clh_request_msg "$1")"
}

# Print a one-sentence explanation of a command.
_clh_explain() {
  emulate -L zsh
  local out
  out=$(_clh_chat "$_CLH_EXPLAIN_SYSTEM" 0 80 "$(_clh_turns "${_CLH_EXPLAIN_EXAMPLES[@]}" user "$1")") || return 1
  out=${out//$'\n'/ }
  print -r -- "${${out##[[:space:]]##}//\`/}"
}

# Classify the line. Sets reply=(mode args...):
#   fix | explain <cmd> | new <request> | refine <cmd> <change> | run
_clh_parse() {
  emulate -L zsh
  setopt extendedglob
  local b=${1##[[:space:]]#} P=$CLH_PREFIX
  b=${b%%[[:space:]]#}
  if [[ $b == ${P}fix ]]; then
    reply=(fix)
  elif [[ $b == ${P}\?* ]]; then
    reply=(explain "${${b#${P}\?}##[[:space:]]#}")
  elif [[ $b == *[[:space:]]${P}\? ]]; then
    reply=(explain "${${b%${P}\?}%%[[:space:]]#}")
  elif [[ $b == ${P}* ]]; then
    reply=(new "${${b#$P}##[[:space:]]#}")
  elif [[ $b == (#b)(*[^[:space:]])[[:space:]]##${P}[[:space:]]##(*) ]]; then
    reply=(refine "$match[1]" "$match[2]")
  else
    reply=(run)
  fi
}

# --- ZLE widgets ------------------------------------------------------------

typeset -g _CLH_HINT="↵ run · ⇥ clear · ^N another · ' :: …' refine · ' ::?' explain"

_clh_reset() {
  _CLH_PENDING=0
  _CLH_TURNS=()
  _CLH_SEEN=()
  _CLH_REQUEST=
  region_highlight=()
}

# Put a generated command on the line and mark it pending.
_clh_show() {
  BUFFER=$1
  CURSOR=${#BUFFER}
  _CLH_PENDING=1
  if [[ $1 =~ $_CLH_DANGER_RE ]]; then
    region_highlight=("0 ${#BUFFER} fg=red,bold")
    zle -M "⚠  potentially destructive — review carefully · $_CLH_HINT"
  else
    region_highlight=("0 ${#BUFFER} fg=cyan")
    zle -M "$_CLH_HINT"
  fi
}

# Make sure Ollama is running, starting it if allowed. Shows progress.
_clh_ensure_server() {
  _clh_server_up && return 0
  if ! (( CLH_AUTOSTART )); then
    zle -M "clh: cannot reach Ollama at $CLH_URL — is 'ollama serve' running?"
    return 1
  fi
  zle -M "🚀 starting ollama… (the first start can take ~20s)"
  zle -R
  local err
  err=$(_clh_start_server 2>&1) || { zle -M "$err"; return 1 }
}

# Generate from a conversation; on success show the command and keep the
# conversation for refine / Ctrl-N.
#   _clh_run <temperature> <query> <role> <content> ...
_clh_run() {
  local temp=$1 query=$2 cmd; shift 2
  _clh_ensure_server || return 1
  zle -M "⏳ thinking ($CLH_MODEL)…"
  zle -R
  # On success only the command is printed; on failure only the error.
  cmd=$(_clh_complete $temp "$query" "$@" 2>&1) || { zle -M "$cmd"; return 1 }
  _CLH_TURNS=("$@" assistant "$cmd")
  _CLH_SEEN+=("$cmd")
  _clh_show "$cmd"
}

_clh_accept_line() {
  emulate -L zsh
  local -a reply
  _clh_parse "$BUFFER"

  case $reply[1] in
    run)
      # Learn the request with the command as run (edits included) if it succeeds.
      (( _CLH_PENDING )) && [[ -n $_CLH_REQUEST ]] && _CLH_LEARN_PAIR=("$_CLH_REQUEST" "$BUFFER")
      _clh_reset
      zle .accept-line
      ;;
    new)
      [[ -z $reply[2] ]] && { zle -M "usage: $CLH_PREFIX <describe the command you want>"; return }
      _CLH_SEEN=()
      _CLH_REQUEST=$reply[2]
      _clh_run 0 "$reply[2]" user "$(_clh_request_msg "$reply[2]")"
      ;;
    refine)
      local -a turns
      if (( _CLH_PENDING )) && (( ${#_CLH_TURNS} )); then
        turns=("${(@)_CLH_TURNS[1,-2]}" "$reply[2]")   # respect manual edits
      else
        _CLH_REQUEST=
        turns=(user "$(_clh_context)

Request: run this command" assistant "$reply[2]")
      fi
      _CLH_SEEN=()
      _clh_run 0 "${_CLH_REQUEST:-$reply[2]}" "${turns[@]}" user "$(_clh_refine_msg "$reply[3]")"
      ;;
    fix)
      local last=${$(fc -ln -1 2>/dev/null)##[[:space:]]#}
      [[ -z $last ]] && { zle -M "clh: no previous command to fix"; return }
      _CLH_SEEN=("$last")
      _CLH_REQUEST=
      _clh_run 0 "$last" user "$(_clh_fix_msg "$last" $_CLH_LAST_STATUS)"
      ;;
    explain)
      [[ -z $reply[2] ]] && { zle -M "usage: <command> ${CLH_PREFIX}?  or  ${CLH_PREFIX}? <command>"; return }
      local cmd=$reply[2] out
      BUFFER=$cmd
      CURSOR=${#BUFFER}
      _clh_ensure_server || return
      zle -M "⏳ explaining…"
      zle -R
      out=$(_clh_explain "$cmd" 2>&1) || { zle -M "$out"; return }
      if [[ $cmd =~ $_CLH_DANGER_RE ]]; then
        zle -M "⚠  $out"
      else
        zle -M "💡 $out"
      fi
      ;;
  esac
}

_clh_tab() {
  if (( _CLH_PENDING )); then
    BUFFER=
    CURSOR=0
    _clh_reset
    zle -M ""
  else
    zle expand-or-complete
  fi
}

# Ctrl-N: another suggestion for the pending command's request.
_clh_next() {
  emulate -L zsh
  if ! (( _CLH_PENDING )) || (( ${#_CLH_TURNS} < 4 )); then
    zle down-line-or-history
    return
  fi
  local -a turns=("${(@)_CLH_TURNS[1,-3]}") ask
  local cmd try
  _clh_ensure_server || return
  for try in 1 2; do
    ask=("${turns[@]}")
    ask[-1]+=$'\n'"Give a different command than: ${(j: | :)_CLH_SEEN}"
    zle -M "⏳ another suggestion…"
    zle -R
    cmd=$(_clh_complete 0.8 "${_CLH_REQUEST:-$BUFFER}" "${ask[@]}" 2>&1) || { zle -M "$cmd"; return }
    (( ${_CLH_SEEN[(Ie)$cmd]} )) || break
  done
  if (( ${_CLH_SEEN[(Ie)$cmd]} )); then
    zle -M "no other suggestion · $_CLH_HINT"
    return
  fi
  _CLH_SEEN+=("$cmd")
  _CLH_TURNS=("${turns[@]}" assistant "$cmd")
  _clh_show "$cmd"
}

_clh_line_init() {
  _clh_reset
}

_clh_precmd() {
  _CLH_LAST_STATUS=$?
  if (( ${#_CLH_LEARN_PAIR} )); then
    (( _CLH_LAST_STATUS == 0 )) && _clh_learn "${_CLH_LEARN_PAIR[@]}"
    _CLH_LEARN_PAIR=()
  fi
}

if [[ -o interactive ]]; then
  autoload -Uz add-zle-hook-widget
  zle -N _clh_accept_line
  zle -N _clh_tab
  zle -N _clh_next
  zle -N _clh_line_init
  add-zle-hook-widget line-init _clh_line_init
  # Run first so $? is the user's command, not another hook's.
  precmd_functions=(_clh_precmd ${precmd_functions:#_clh_precmd})
  bindkey '^M' _clh_accept_line
  bindkey '^I' _clh_tab
  bindkey '^N' _clh_next

  # Load the model in the background so the first query is fast.
  if (( CLH_WARM )); then
    ( curl -s --max-time 60 "$CLH_URL/api/generate" \
        -d "{\"model\":\"$CLH_MODEL\",\"keep_alive\":\"30m\"}" >/dev/null 2>&1 & ) 2>/dev/null
  fi
fi
