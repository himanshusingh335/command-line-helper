# clh.bash — natural-language → shell command helper for bash, powered by Ollama.
# The bash port of clh.zsh (Linux, WSL, Git Bash; needs bash 4+).
#
#   :: <what you want>     Enter → the generated command replaces the line
#   Enter again                   → run it
#   Tab                           → discard it
#   Ctrl-N                        → another suggestion for the same request
#   <cmd> :: <change>       Enter → revise the command on the line
#   <cmd> ::?  or  ::? <cmd> Enter → explain a command without running it
#   ::fix                   Enter → correct the last command you ran
#   ::help / ::settings     Enter → this help / change settings (also: clh help)
#
# Source this file from ~/.bashrc. Requires curl, jq and a running Ollama server.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "clh: needs bash 4 or newer (this is bash ${BASH_VERSION:-unknown})" >&2
  return 1 2>/dev/null || exit 1
fi

# Settings: name, type (bool, int, str or a|b|c), default, description.
# Precedence: set to a non-default value before this file is sourced (e.g. in
# ~/.bashrc) > saved with `clh set` in $CLH_CONFIG_FILE > default.
_CLH_SETTINGS=(
  CLH_MODEL         str               'qwen2.5-coder:1.5b'      'Ollama model that writes the commands'
  CLH_URL           str               'http://localhost:11434'  'Ollama server'
  CLH_PREFIX        str               '::'                      'trigger prefix'
  CLH_TIMEOUT       int               30                        'seconds to wait for the model'
  CLH_WARM          bool              1                         'preload the model when a shell starts'
  CLH_AUTOSTART     bool              1                         'start ollama serve if it is down (local URL only)'
  CLH_OLLAMA_LOG    str               "$HOME/.ollama/clh-serve.log"  'log file of a server started by clh'
  CLH_LEARN         bool              1                         'learn from generated commands you run'
  CLH_HISTORY_FILE  str               "${XDG_DATA_HOME:-$HOME/.local/share}/clh/history.jsonl"  'learned request → command pairs'
  CLH_HISTORY_MAX   int               500                       'learned pairs to keep'
  CLH_EXAMPLE_MODE  'all|keyword|embed'  all                    'examples sent: all built-ins + closest learned (fastest), or only the K most similar by words / embeddings'
  CLH_EXAMPLES_K    int               8                         'examples sent in keyword / embed mode'
  CLH_EMBED_MODEL   str               nomic-embed-text          'embedding model for embed mode'
)
: "${CLH_CONFIG_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/clh/config.bash}"

# Settings set to a non-default value before the plugin loaded; they beat
# saved ones. (Restating a default, e.g. in ~/.bashrc, doesn't count.)
_CLH_PRESET=()
_clh_load_settings() {
  local i n d
  local -a keep=()
  for (( i = 0; i < ${#_CLH_SETTINGS[@]}; i += 4 )); do
    n=${_CLH_SETTINGS[i]} d=${_CLH_SETTINGS[i + 2]}
    if [[ -n ${!n} && ${!n} != "$d" ]]; then
      _CLH_PRESET+=("$n")
      keep+=("$n" "${!n}")
    fi
  done
  [[ -r $CLH_CONFIG_FILE ]] && source "$CLH_CONFIG_FILE"
  for (( i = 0; i < ${#keep[@]}; i += 2 )); do
    declare -g "${keep[i]}=${keep[i + 1]}"
  done
  for (( i = 0; i < ${#_CLH_SETTINGS[@]}; i += 4 )); do
    n=${_CLH_SETTINGS[i]}
    [[ -n ${!n} ]] || declare -g "$n=${_CLH_SETTINGS[i + 2]}"
  done
}
_clh_load_settings

_CLH_PENDING=0 _CLH_LAST_STATUS=0
# Conversation behind the generated command (role/content pairs) and the
# commands already suggested for it; both live only while it is pending.
_CLH_TURNS=() _CLH_SEEN=()
# The request behind the pending command, and the request / command pair
# waiting for its exit status before it is learned.
_CLH_REQUEST=
_CLH_LEARN_PAIR=()

# Commands that deserve an extra look before running.
_CLH_DANGER_RE='(^|[;&| ])(sudo|rm -[a-zA-Z]*[rf]|dd |mkfs|shred|diskutil (erase|partition)|chmod -R 777|kill -9 -1)|> ?/dev/|git (push.*(-f|--force)|reset --hard|clean -[a-z]*f)|docker (system|volume|image) prune|conda (env )?remove'

# Where we are: linux, macos or gitbash (plus WSL detection for the context).
case $(uname -s 2>/dev/null) in
  Darwin)               _CLH_OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) _CLH_OS=gitbash ;;
  *)                    _CLH_OS=linux ;;
esac

case $_CLH_OS in
  macos)
    _CLH_PLATFORM='bash on macOS'
    _CLH_PLATFORM_RULES="- macOS uses BSD tools: sed -i '', stat -f, date -v, pbcopy, open. Homebrew is available.
- Prefer common tools: git, docker, docker compose, conda, python3, pip, find, grep, du, lsof, tar.
- Only use flags that exist on macOS (no grep -P, no GNU-only options)." ;;
  gitbash)
    _CLH_PLATFORM='Git Bash on Windows'
    _CLH_PLATFORM_RULES="- This is Git Bash on Windows: GNU tools from MSYS2, drives are /c/, /d/; open files with start. There is no sudo and no apt.
- Prefer common tools: git, docker, docker compose, conda, python, pip, find, grep, du, tar.
- Use Windows programs (netstat -ano, taskkill //PID <pid> //F) where Linux tools like lsof, ss or kill don't exist." ;;
  *)
    _CLH_PLATFORM='bash on Linux'
    _CLH_PLATFORM_RULES="- Linux uses GNU tools: sed -i, stat -c, date -d, xdg-open. Install packages with the system package manager (apt, dnf or pacman) and sudo.
- Prefer common tools: git, docker, docker compose, conda, python3, pip, find, grep, du, ss, lsof, tar." ;;
esac

_CLH_SYSTEM="You are a command-line expert. Convert the user request into ONE shell command for $_CLH_PLATFORM.
Rules:
- Output ONLY the command on a single line. No explanation, no markdown, no backticks, no leading \"\$\".
- Combine multiple steps with && on the same line.
$_CLH_PLATFORM_RULES
- conda env \"here\" / \"in this folder\" / \"local\" / \"-p\" means a prefix env: conda create -p ./.conda ..., activated with conda activate ./.conda.
- Do exactly what was asked: never add destructive or extra flags (like --hard, -a, -f, file filters) the user did not ask for.
- Use the context (directory, files, git branch, conda env) when it helps; use placeholders like <name> only when the value is truly unknown."

_CLH_EXPLAIN_SYSTEM="You explain shell commands for $_CLH_PLATFORM.
Reply with ONE short plain sentence (at most 20 words) saying exactly what the command does. No markdown."

_CLH_EXPLAIN_EXAMPLES=(
  user 'docker ps -a'                     assistant 'Lists all Docker containers, including stopped ones.'
  user 'git stash pop'                    assistant 'Re-applies your most recently stashed changes and removes them from the stash.'
  user 'find . -name "*.log" -delete'     assistant 'Deletes every .log file in this folder and its subfolders.'
  user 'lsof -i :8080'                    assistant 'Shows which process is listening on port 8080.'
)

# Few-shot examples: alternating request / command. Keep in sync with
# clh.zsh (tests/test_sync.zsh checks).
_CLH_EXAMPLES=(
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
_CLH_FIX_TAIL='Output only the corrected command.'
_CLH_FIX_EXAMPLES=(
  $'This command failed with exit code 127: \'dokcer\' is not a known command (probably misspelled):\ndokcer ps -a\nOutput only the corrected command.'      'docker ps -a'
  $'This command failed with exit code 127: \'pyhton\' is not a known command (probably misspelled):\npyhton main.py\nOutput only the corrected command.'    'python3 main.py'
  $'This command failed with exit code 1 (likely wrong flags or arguments):\ngit comit -m "init"\nOutput only the corrected command.'                          'git commit -m "init"'
  $'This command failed with exit code 1 (likely wrong flags or arguments):\ndu -sh --max-depth=1\nOutput only the corrected command.'                           'du -h -d 1'
)

# --- core -------------------------------------------------------------------

_clh_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Clean raw model output into a single command line.
_clh_sanitize() {
  local line
  while IFS= read -r line; do
    line=$(_clh_trim "$line")
    [[ -z $line || $line == '```'* ]] && continue
    case $line in '$ '*|'% '*|'> '*) line=${line:2} ;; esac
    if [[ $line == \`*\` ]]; then
      line=${line#\`}
      line=${line%\`}
    fi
    printf '%s\n' "$line"
    return 0
  done <<<"$1"
  return 1
}

_clh_os_name() {
  local name
  case $_CLH_OS in
    macos)   name="macOS $(sw_vers -productVersion 2>/dev/null)" ;;
    gitbash) name='Windows (Git Bash)' ;;
    *)
      name=$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$NAME}")
      name=${name:-Linux}
      grep -qi microsoft /proc/version 2>/dev/null && name+=' (WSL)' ;;
  esac
  printf '%s' "$name"
}

_clh_context() {
  local branch files
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  files=$(command ls -1A 2>/dev/null | head -n 25 | paste -sd, - | sed 's/,/, /g')
  printf '%s\n' "Context:
- OS: $(_clh_os_name), shell: bash
- Current directory: $PWD
- Files here: ${files:-none}
- Git branch: ${branch:-not a git repo}
- Conda env: ${CONDA_DEFAULT_ENV:-none}"
}

# Extra hints for phrasings small models tend to get wrong.
_clh_hints() {
  local q=$1 tpl restore
  restore=$(shopt -p nocasematch)
  shopt -s nocasematch
  if [[ $q =~ (conda|env|environment) ]] && ! [[ $q =~ (venv|virtualenv) ]] \
      && [[ $q =~ (here|this\ (folder|dir|directory)|current\ (folder|dir|directory)|local|-p|prefix) ]]; then
    if [[ $q =~ (activate|use|switch|enter) ]]; then
      tpl='conda activate ./.conda'
    elif [[ $q =~ (delete|remove|destroy|uninstall) ]]; then
      tpl='conda remove -p ./.conda --all -y'
    else
      tpl='conda create -p ./.conda python=3.11 -y (change the python version / add packages if asked)'
    fi
    printf '%s\n' "IMPORTANT: the env lives in the folder ./.conda. Use -p ./.conda, never -n and never just \".\". Answer with: $tpl"
  fi
  eval "$restore"
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
  local sys=$1 temp=$2 npred=$3 msgs=$4 payload response err

  payload=$(jq -nc \
    --arg model "$CLH_MODEL" --arg sys "$sys" \
    --argjson temp "$temp" --argjson npred "$npred" --argjson msgs "$msgs" \
    '{model: $model, stream: false, think: false, keep_alive: "30m",
      options: {temperature: $temp, num_predict: $npred},
      messages: ([{role: "system", content: $sys}] + $msgs)}') \
    || { echo "clh: failed to build request (jq)" >&2; return 1; }

  response=$(curl -sS --max-time "$CLH_TIMEOUT" "$CLH_URL/api/chat" -d "$payload" 2>&1) || {
    echo "clh: cannot reach Ollama at $CLH_URL — is 'ollama serve' running?" >&2
    return 1
  }

  err=$(jq -r '.error // empty' <<<"$response" 2>/dev/null)
  if [[ -n $err ]]; then
    [[ $err == *"not found"* ]] && err+=" — run: ollama pull $CLH_MODEL"
    echo "clh: $err" >&2
    return 1
  fi

  jq -r '.message.content // empty' <<<"$response" 2>/dev/null
}

# Print a command for a conversation (few-shots are prepended).
#   _clh_complete <temperature> <query> <role> <content> [<role> <content> ...]
# <query> is the plain request (or command) used to pick similar examples.
_clh_complete() {
  local temp=$1 query=$2; shift 2
  local msgs content fix=0
  [[ ${!#} == *"$_CLH_FIX_TAIL"* ]] && fix=1
  msgs=$(jq -nc --argjson a "$(_clh_select_examples "$query" $fix)" --argjson b "$(_clh_turns "$@")" '$a + $b')
  content=$(_clh_chat "$_CLH_SYSTEM" "$temp" 120 "$msgs") || return 1
  _clh_sanitize "$content" || { echo "clh: model returned no command" >&2; return 1; }
}

# Alternating request / command arguments → user / assistant turns.
_clh_pair_turns() {
  jq -nc '[$ARGS.positional as $e | range(0; $e | length; 2) as $i
           | {role: "user", content: $e[$i]}, {role: "assistant", content: $e[$i + 1]}]' \
    --args "$@"
}

# --- learned and similar examples -------------------------------------------

# jq helpers. Pool items are {r: request, c: command, l: learned, t: time};
# rankers add a similarity score s. Same program as clh.zsh.
_CLH_JQ_LIB='
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

_clh_dirname() {
  [[ $1 == */* ]] && printf '%s' "${1%/*}" || printf '.'
}

# Remember a request and the command the user ran for it.
_clh_learn() {
  local req=$1 cmd=$2 f=$CLH_HISTORY_FILE tmp now
  (( CLH_LEARN )) || return 0
  [[ -n $req && -n $cmd && $cmd != *$'\n'* ]] || return 0
  [[ $cmd =~ $_CLH_DANGER_RE ]] && return 0
  printf -v now '%(%s)T' -1
  ( umask 077
    mkdir -p -- "$(_clh_dirname "$f")" &&
    jq -nc --arg r "$req" --arg c "$cmd" --argjson t "$now" '{r: $r, c: $c, t: $t}' >> "$f" ) || return 1
  if (( $(wc -l < "$f") > CLH_HISTORY_MAX )); then
    tmp=$f.$$
    jq -c -s --argjson max "$CLH_HISTORY_MAX" \
      'group_by(.r | ascii_downcase) | map(max_by(.t)) | sort_by(.t) | .[-$max:][]' "$f" > "$tmp" &&
      mv -f -- "$tmp" "$f"
  fi
}

# Learned pairs (newest per request) followed by the built-in examples.
_clh_pool() {
  local learned='[]'
  if [[ -r $CLH_HISTORY_FILE ]]; then
    learned=$(jq -c -s 'map(select(.r and .c)) | group_by(.r | ascii_downcase)
                        | map(max_by(.t) | {r, c, t, l: true})' "$CLH_HISTORY_FILE" 2>/dev/null) || learned='[]'
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
  local payload resp
  payload=$(jq -nc --arg m "$CLH_EMBED_MODEL" '{model: $m, input: $ARGS.positional, keep_alive: "30m"}' --args "$@")
  resp=$(curl -sS --max-time "$CLH_TIMEOUT" "$CLH_URL/api/embed" -d "$payload" 2>/dev/null) || return 1
  jq -ce '.embeddings | select(type == "array" and length > 0)' <<<"$resp" 2>/dev/null
}

# Score the pool by cosine similarity. Example vectors are cached next to
# the history file, so usually only the query is embedded.
_clh_rank_embed() {
  local q=$1 pool=$2 cache vecs
  local -a missing
  cache=$(_clh_dirname "$CLH_HISTORY_FILE")/embed-cache.jsonl
  mapfile -t missing < <(jq -r --arg m "$CLH_EMBED_MODEL" --slurpfile c <([[ -r $cache ]] && cat "$cache") \
    '[$c[] | select(.m == $m) | .t] as $have | [.[].r] | unique[] | select(IN($have[]) | not)' <<<"$pool")
  vecs=$(_clh_embed "$q" "${missing[@]}") || return 1
  if (( ${#missing[@]} )); then
    ( umask 077; mkdir -p -- "$(_clh_dirname "$cache")" &&
      jq -c --arg m "$CLH_EMBED_MODEL" '.[1:] as $v | $ARGS.positional | to_entries[] | {m: $m, t: .value, e: $v[.key]}' \
        --args "${missing[@]}" <<<"$vecs" >> "$cache" ) || return 1
  fi
  jq -c --arg m "$CLH_EMBED_MODEL" --argjson pool "$pool" --slurpfile c "$cache" "$_CLH_JQ_LIB"'
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
  local q=$1 fix=${2:-0} pool scored fixes='[]'
  pool=$(_clh_pool) || return 1
  if (( fix )) || [[ $CLH_EXAMPLE_MODE != keyword && $CLH_EXAMPLE_MODE != embed ]]; then
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
  jq -c --argjson k "$CLH_EXAMPLES_K" --argjson f "$fixes" "$_CLH_JQ_LIB"' (pick($k) | turns) + $f' <<<"$scored"
}

# User messages for each kind of request.
_clh_request_msg() {
  printf '%s\n' "$(_clh_context)

Request: $1
$(_clh_hints "$1")"
}

_clh_refine_msg() {
  printf '%s\n' "Revise the command: $1. Output the full revised command only."
}

_clh_fix_msg() {
  local cmd=$1 st=$2 first why
  read -r first _ <<<"$cmd"
  if (( st == 0 )); then
    why="This command ran but did not do what the user wanted"
  elif (( st == 127 )) || ! type -t -- "$first" >/dev/null 2>&1; then
    why="This command failed with exit code $st: '$first' is not a known command (probably misspelled)"
  else
    why="This command failed with exit code $st (likely wrong flags or arguments)"
  fi
  printf '%s\n' "$(_clh_context)

$why:
$cmd
$_CLH_FIX_TAIL"
}

# --- Ollama server ----------------------------------------------------------

_clh_server_up() {
  curl -s --max-time 1 "$CLH_URL/api/version" >/dev/null 2>&1
}

# Start `ollama serve` detached from this terminal (so Ctrl-C or closing it
# doesn't kill the server) and wait for it to answer. Only for a local server.
_clh_start_server() {
  local hostport=${CLH_URL#*://} deadline=$(( SECONDS + 60 ))
  hostport=${hostport%%/*}
  case $hostport in
    localhost|localhost:*|127.0.0.1|127.0.0.1:*|0.0.0.0|0.0.0.0:*) ;;
    *) echo "clh: cannot reach Ollama at $CLH_URL (not local, so not starting it)" >&2; return 1 ;;
  esac
  if ! command -v ollama >/dev/null; then
    case $_CLH_OS in
      macos)   echo "clh: ollama is not installed (brew install ollama)" >&2 ;;
      gitbash) echo "clh: ollama is not installed (winget install Ollama.Ollama)" >&2 ;;
      *)       echo "clh: ollama is not installed (curl -fsSL https://ollama.com/install.sh | sh)" >&2 ;;
    esac
    return 1
  fi
  mkdir -p "$(_clh_dirname "$CLH_OLLAMA_LOG")"
  if command -v setsid >/dev/null; then
    OLLAMA_HOST=$hostport setsid -f ollama serve >>"$CLH_OLLAMA_LOG" 2>&1 </dev/null
  else
    ( OLLAMA_HOST=$hostport nohup ollama serve >>"$CLH_OLLAMA_LOG" 2>&1 </dev/null & )
  fi
  # On first start Ollama can spend ~20s detecting the GPU before answering.
  while (( SECONDS < deadline )); do
    _clh_server_up && return 0
    sleep 0.5
  done
  echo "clh: started ollama but it did not respond — see $CLH_OLLAMA_LOG" >&2
  return 1
}

# Print the generated command for a natural-language query.
_clh_generate() {
  _clh_complete 0 "$1" user "$(_clh_request_msg "$1")"
}

# Print a one-sentence explanation of a command.
_clh_explain() {
  local out
  out=$(_clh_chat "$_CLH_EXPLAIN_SYSTEM" 0 80 "$(_clh_turns "${_CLH_EXPLAIN_EXAMPLES[@]}" user "$1")") || return 1
  out=${out//$'\n'/ }
  out=$(_clh_trim "$out")
  printf '%s\n' "${out//\`/}"
}

# Classify the line. Sets reply=(mode args...):
#   fix | explain <cmd> | new <request> | refine <cmd> <change> | run
_clh_parse() {
  local b P=$CLH_PREFIX re
  b=$(_clh_trim "$1")
  re=$(_clh_re_escape "$P")
  if [[ $b == "$P"fix ]]; then
    reply=(fix)
  elif [[ $b == "$P"help || $b == "$P"settings ]]; then
    reply=(clh "${b#"$P"}")
  elif [[ $b == "$P"\?* ]]; then
    reply=(explain "$(_clh_trim "${b#"$P"\?}")")
  elif [[ $b == *[[:space:]]"$P"\? ]]; then
    reply=(explain "$(_clh_trim "${b%"$P"\?}")")
  elif [[ $b == "$P"* ]]; then
    reply=(new "$(_clh_trim "${b#"$P"}")")
  elif [[ $b =~ ^(.*[^[:space:]])[[:space:]]+${re}[[:space:]]+(.*)$ ]]; then
    reply=(refine "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
  else
    reply=(run)
  fi
}

# Escape a string for use inside an ERE.
_clh_re_escape() {
  local s=$1 out= c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    if [[ '\.^$*+?(){}|[]/' == *"$c"* ]]; then out+="\\$c"; else out+=$c; fi
  done
  printf '%s' "$out"
}

# --- clh command: help and settings -----------------------------------------

_clh_in() {
  local x=$1; shift
  local e
  for e in "$@"; do [[ $e == "$x" ]] && return 0; done
  return 1
}

_clh_short() { local n=${1#CLH_}; printf '%s' "${n,,}"; }

_clh_tilde() { local v=$1; printf '%s' "${v/#"$HOME"/"~"}"; }

# Look up a setting by name (CLH_MODEL, model, example-mode, ...).
# Sets reply=(name type default description); fails for unknown names.
_clh_setting() {
  local want=${1//-/_} i
  want=${want^^}
  [[ $want == CLH_* ]] || want=CLH_$want
  for (( i = 0; i < ${#_CLH_SETTINGS[@]}; i += 4 )); do
    if [[ ${_CLH_SETTINGS[i]} == "$want" ]]; then
      reply=("${_CLH_SETTINGS[@]:i:4}")
      return 0
    fi
  done
  return 1
}

# Print a value normalized for a setting type, or fail if it doesn't fit.
_clh_check_value() {
  # Spaces around a value typed into `clh settings` would otherwise be saved.
  local t=$1 v=$2
  v=${v#"${v%%[![:space:]]*}"} v=${v%"${v##*[![:space:]]}"}
  case $t in
    bool)
      case ${v,,} in
        1|on|true|yes)  echo 1 ;;
        0|off|false|no) echo 0 ;;
        *) return 1 ;;
      esac ;;
    int) [[ $v =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$v" ;;
    str) [[ -n $v && $v != *$'\n'* ]] && printf '%s\n' "$v" ;;
    *)   [[ -n $v && $v != *'|'* && "|$t|" == *"|$v|"* ]] && printf '%s\n' "$v" ;;
  esac
}

_clh_type_hint() {
  case $1 in
    bool) echo 'on or off' ;;
    int)  echo 'a number' ;;
    str)  echo 'text' ;;
    *)    local t=$1; echo "one of: ${t//|/, }" ;;
  esac
}

# Where a setting's current value comes from: bashrc, saved, default or shell.
_clh_setting_source() {
  local n=$1
  if _clh_in "$n" "${_CLH_PRESET[@]}"; then
    echo bashrc
  elif [[ -r $CLH_CONFIG_FILE ]] && grep -q "^$n=" "$CLH_CONFIG_FILE"; then
    echo saved
  elif [[ ${!n} == "$2" ]]; then
    echo default
  else
    echo shell
  fi
}

# Save NAME=value in the config file, or drop NAME when no value is given.
_clh_save_setting() {
  local n=$1 f=$CLH_CONFIG_FILE
  ( umask 077
    mkdir -p -- "$(_clh_dirname "$f")" || exit 1
    { echo '# clh settings, written by `clh set` and `clh settings`.'
      [[ -r $f ]] && grep -v -e "^$n=" -e '^#' "$f"
      if (( $# > 1 )); then printf '%s=%q\n' "$n" "$2"; fi
    } > "$f.$$" && mv -f -- "$f.$$" "$f" )
}

_clh_installed_models() {
  curl -s --max-time 2 "$CLH_URL/api/tags" 2>/dev/null | jq -r '.models[].name' 2>/dev/null
}

# Warn about a model that isn't installed (silent if Ollama is down).
_clh_check_model() {
  local -a models
  mapfile -t models < <(_clh_installed_models)
  (( ${#models[@]} )) || return 0
  _clh_in "$1" "${models[@]}" || _clh_in "$1:latest" "${models[@]}" ||
    echo "note: '$1' is not installed; run: ollama pull $1"
}

_clh_set() {
  local -a reply
  local n t v
  _clh_setting "$1" || { echo "clh: unknown setting '$1' (see: clh config)" >&2; return 1; }
  n=${reply[0]} t=${reply[1]}
  v=$(_clh_check_value "$t" "$2") ||
    { echo "clh: $(_clh_short "$n") must be $(_clh_type_hint "$t"), not '$2'" >&2; return 1; }
  declare -g "$n=$v"
  _clh_save_setting "$n" "$v" || { echo "clh: cannot write $CLH_CONFIG_FILE" >&2; return 1; }
  echo "$(_clh_short "$n") = $v (saved)"
  _clh_in "$n" "${_CLH_PRESET[@]}" &&
    echo "note: $n is also set in your shell startup files (e.g. ~/.bashrc), which wins in new shells"
  case $n in
    CLH_MODEL) _clh_check_model "$CLH_MODEL" ;;
    CLH_EXAMPLE_MODE|CLH_EMBED_MODEL) [[ $CLH_EXAMPLE_MODE == embed ]] && _clh_check_model "$CLH_EMBED_MODEL" ;;
    CLH_WARM) echo 'takes effect in new shells' ;;
  esac
  return 0
}

_clh_reset_setting() {
  local -a reply
  local n d i
  if [[ $1 == --all || $1 == all ]]; then
    rm -f -- "$CLH_CONFIG_FILE"
    for (( i = 0; i < ${#_CLH_SETTINGS[@]}; i += 4 )); do
      n=${_CLH_SETTINGS[i]}
      _clh_in "$n" "${_CLH_PRESET[@]}" || declare -g "$n=${_CLH_SETTINGS[i + 2]}"
    done
    echo 'all settings are back to their defaults'
    if (( ${#_CLH_PRESET[@]} )); then
      local IFS=,
      echo "still set in your shell startup files: ${_CLH_PRESET[*]}"
    fi
    return 0
  fi
  _clh_setting "$1" || { echo "clh: unknown setting '$1' (see: clh config)" >&2; return 1; }
  n=${reply[0]} d=${reply[2]}
  _clh_save_setting "$n" || { echo "clh: cannot write $CLH_CONFIG_FILE" >&2; return 1; }
  if _clh_in "$n" "${_CLH_PRESET[@]}"; then
    echo "$n is set in your shell startup files (e.g. ~/.bashrc); that value stays"
  else
    declare -g "$n=$d"
    echo "$(_clh_short "$n") = $d (default)"
  fi
}

# List settings with value, source and description. -n numbers them.
_clh_config() {
  local i n num= pad=
  for (( i = 0; i < ${#_CLH_SETTINGS[@]}; i += 4 )); do
    n=${_CLH_SETTINGS[i]}
    [[ $1 == -n ]] && { printf -v num '%2d) ' $(( i / 4 + 1 )); pad='    '; }
    printf '%s%-14s %s  (%s)\n' "$num" "$(_clh_short "$n")" "$(_clh_tilde "${!n}")" \
      "$(_clh_setting_source "$n" "${_CLH_SETTINGS[i + 2]}")"
    printf '%s%-14s %s\n' "$pad" '' "${_CLH_SETTINGS[i + 3]}"
  done
}

# Interactive editor: pick a setting by number or name; bools toggle.
_clh_settings_ui() {
  local -a reply models
  local choice n t v reset
  while :; do
    echo
    _clh_config -n
    echo
    read -r -p 'Setting to change (number or name; r <number> resets; Enter quits): ' choice || return 0
    [[ -z $choice ]] && return 0
    reset=0
    [[ $choice == 'r '* ]] && { reset=1; choice=${choice#r }; }
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#_CLH_SETTINGS[@]} / 4 )); then
      n=${_CLH_SETTINGS[(choice - 1) * 4]}
    else
      n=$choice
    fi
    _clh_setting "$n" || { echo "no setting '$choice'"; continue; }
    n=${reply[0]} t=${reply[1]}
    echo
    if (( reset )); then
      _clh_reset_setting "$n"
    elif [[ $t == bool ]]; then
      _clh_set "$n" $(( ! ${!n} ))
    else
      echo "${reply[3]} ($(_clh_type_hint "$t"))"
      if [[ $n == CLH_MODEL || $n == CLH_EMBED_MODEL ]]; then
        mapfile -t models < <(_clh_installed_models)
        local IFS=,
        echo "installed: ${models[*]:-unknown (is Ollama running?)}"
        unset IFS
      fi
      v=
      read -e -r -p "$(_clh_short "$n") [$(_clh_tilde "${!n}")] (Enter keeps it)> " v || continue
      [[ -z $v || $v == "${!n}" ]] || _clh_set "$n" "$v"
    fi
  done
}

_clh_history() {
  [[ -s $CLH_HISTORY_FILE ]] || { echo 'nothing learned yet'; return 0; }
  jq -r '"\(.r)  → \(.c)"' "$CLH_HISTORY_FILE" | tail -n "${1:-20}"
}

# Forget every learned pair, or those whose request or command contains text.
_clh_forget() {
  local f=$CLH_HISTORY_FILE before after ans
  [[ -s $f ]] || { echo 'nothing learned yet'; return 0; }
  before=$(wc -l < "$f"); before=${before// /}
  if [[ -z $1 ]]; then
    read -r -n 1 -p "Forget all $before learned commands? [y/N] " ans
    echo
    [[ $ans == [yY] ]] || return 1
    rm -f -- "$f" "$(_clh_dirname "$f")/embed-cache.jsonl"
    echo 'forgot everything'
    return 0
  fi
  ( umask 077
    jq -c --arg s "${1,,}" 'select((.r + " " + .c) | ascii_downcase | contains($s) | not)' "$f" > "$f.$$" &&
      mv -f -- "$f.$$" "$f" ) || return 1
  after=$(wc -l < "$f")
  echo "forgot $(( before - after )) of $before"
}

_clh_help() {
  local P=$CLH_PREFIX i n
  echo "clh — plain English → shell commands  (model: $CLH_MODEL)

On the command line, then Enter:"
  printf '  %-24s %s\n' \
    "$P <request>"           "generate a command, e.g.  $P find files over 100MB" \
    "<command> $P <change>"  "revise it, e.g.  find . -size +1M $P only python files" \
    "<command> ${P}?"        "explain without running (or: ${P}? <command>)" \
    "${P}fix"                "fix the last command you ran" \
    "${P}help  ${P}settings" "this page / change settings"
  echo "
With a generated command on the line:
  Enter  run it       Tab  clear it       Ctrl-N  another suggestion
  ⚠ marks potentially destructive commands. Nothing runs until you press Enter.
  Commands you run are learned and reused as examples (clh history).

Commands:
  clh help                 this page
  clh config               all settings, where each value comes from
  clh settings             change settings interactively
  clh set <name> <value>   change and save a setting    clh set model qwen3.5:4b
  clh reset <name>|--all   back to the default
  clh history [N]          the last N learned commands (default 20)
  clh forget [text]        forget all learned commands, or those containing text

Settings (saved in $(_clh_tilde "$CLH_CONFIG_FILE")):"
  for (( i = 0; i < ${#_CLH_SETTINGS[@]}; i += 4 )); do
    n=${_CLH_SETTINGS[i]}
    printf '  %-14s %s\n' "$(_clh_short "$n")" "$(_clh_tilde "${!n}")"
  done
}

clh() {
  local cmd=${1:-help}
  (( $# )) && shift
  case $cmd in
    help|-h|--help) _clh_help ;;
    config)         _clh_config ;;
    settings)       _clh_settings_ui ;;
    set)
      (( $# >= 2 )) || { echo 'usage: clh set <name> <value>   (names: clh config)' >&2; return 1; }
      local name=$1; shift
      _clh_set "$name" "$*" ;;
    reset)
      (( $# )) || { echo 'usage: clh reset <name>|--all' >&2; return 1; }
      _clh_reset_setting "$1" ;;
    history)        _clh_history "$@" ;;
    forget)         _clh_forget "$*" ;;
    *) echo "clh: unknown command '$cmd' (try: clh help)" >&2; return 1 ;;
  esac
}

# For tests/test_sync.zsh: the data that must match the other versions.
_clh_dump_data() {
  jq -nc --argjson s "$(jq -nc '$ARGS.positional' --args "${_CLH_SETTINGS[@]}")" \
    --argjson e "$(_clh_pair_turns "${_CLH_EXAMPLES[@]}")" \
    --argjson f "$(_clh_pair_turns "${_CLH_FIX_EXAMPLES[@]}")" \
    '{settings: [range(0; $s | length; 4) as $i | {n: $s[$i], t: $s[$i + 1], d: $s[$i + 2]}],
      examples: $e, fix_examples: $f}'
}

# --- readline key handling --------------------------------------------------
#
# bind -x functions can edit the line but can't decide whether it runs, so
# each key is a macro: first a bind -x handler, then an "action" key that
# the handler rebinds to accept-line (run) or a no-op (stay on the line).
# Tab and Ctrl-N are only taken over while a generated command is pending,
# so normal completion (including double-Tab) is untouched.

_CLH_HINT="↵ run · ⇥ clear · ^N another · ' :: …' refine · ' ::?' explain"
_CLH_KEYMAPS=(emacs vi-insert)

# Transient status (overwritten by the redrawn prompt) and lasting messages,
# both printed where the prompt line is.
_clh_status() { printf '\r\e[K%s' "$1" >&2; }
_clh_msg()    { printf '\r\e[K%s\n' "$1" >&2; }

# The readline function a key had before clh, per keymap (for Tab / Ctrl-N).
_clh_orig_binding() {
  bind -m "$1" -p 2>/dev/null | awk -v k="\"$2\":" '$1 == k { print $2; exit }'
}

# Take over (1) or give back (0) Tab and Ctrl-N.
_clh_grab_keys() {
  local km
  for km in "${_CLH_KEYMAPS[@]}"; do
    if (( $1 )); then
      bind -m "$km" '"\C-i": "\C-x}3\C-x}4"'
      bind -m "$km" '"\C-n": "\C-x}5\C-x}6"'
    else
      bind -m "$km" "\"\\C-i\": ${_CLH_ORIG_TAB[$km]:-complete}"
      bind -m "$km" "\"\\C-n\": ${_CLH_ORIG_NEXT[$km]:-next-history}"
    fi
  done
}

_clh_reset() {
  (( _CLH_PENDING )) && _clh_grab_keys 0
  _CLH_PENDING=0
  _CLH_TURNS=()
  _CLH_SEEN=()
  _CLH_REQUEST=
}

_clh_set_line() {
  READLINE_LINE=$1
  READLINE_POINT=${#1}
}

# Put a generated command on the line and mark it pending.
_clh_show() {
  _clh_set_line "$1"
  (( _CLH_PENDING )) || _clh_grab_keys 1
  _CLH_PENDING=1
  if [[ $1 =~ $_CLH_DANGER_RE ]]; then
    _clh_msg $'\e[1;31m⚠  potentially destructive — review carefully\e[0m · '"$_CLH_HINT"
  else
    _clh_msg $'\e[36m'"$_CLH_HINT"$'\e[0m'
  fi
}

# Make sure Ollama is running, starting it if allowed. Shows progress.
_clh_ensure_server() {
  _clh_server_up && return 0
  if ! (( CLH_AUTOSTART )); then
    _clh_msg "clh: cannot reach Ollama at $CLH_URL — is 'ollama serve' running?"
    return 1
  fi
  _clh_status "🚀 starting ollama… (the first start can take ~20s)"
  local err
  err=$(_clh_start_server 2>&1) || { _clh_msg "$err"; return 1; }
}

# Generate from a conversation; on success show the command and keep the
# conversation for refine / Ctrl-N.
#   _clh_run <temperature> <query> <role> <content> ...
_clh_run() {
  local temp=$1 query=$2 cmd; shift 2
  _clh_ensure_server || return 1
  _clh_status "⏳ thinking ($CLH_MODEL)…"
  # On success only the command is printed; on failure only the error.
  cmd=$(_clh_complete "$temp" "$query" "$@" 2>&1) || { _clh_msg "$cmd"; return 1; }
  _CLH_TURNS=("$@" assistant "$cmd")
  _CLH_SEEN+=("$cmd")
  _clh_show "$cmd"
}

# Enter.
_clh_accept_line() {
  local -a reply turns
  local action=redraw-current-line
  _clh_parse "$READLINE_LINE"

  case ${reply[0]} in
    run)
      # Learn the request with the command as run (edits included) if it succeeds.
      (( _CLH_PENDING )) && [[ -n $_CLH_REQUEST ]] && _CLH_LEARN_PAIR=("$_CLH_REQUEST" "$READLINE_LINE")
      _clh_reset
      action=accept-line
      ;;
    new)
      if [[ -z ${reply[1]} ]]; then
        _clh_msg "usage: $CLH_PREFIX <describe the command you want>"
      else
        _CLH_SEEN=()
        _CLH_REQUEST=${reply[1]}
        _clh_run 0 "${reply[1]}" user "$(_clh_request_msg "${reply[1]}")"
      fi
      ;;
    refine)
      if (( _CLH_PENDING )) && (( ${#_CLH_TURNS[@]} )); then
        turns=("${_CLH_TURNS[@]:0:${#_CLH_TURNS[@]}-1}" "${reply[1]}")   # respect manual edits
      else
        _CLH_REQUEST=
        turns=(user "$(_clh_context)

Request: run this command" assistant "${reply[1]}")
      fi
      _CLH_SEEN=()
      _clh_run 0 "${_CLH_REQUEST:-${reply[1]}}" "${turns[@]}" user "$(_clh_refine_msg "${reply[2]}")"
      ;;
    fix)
      # Not `fc -ln -1`: outside a running command it skips the newest entry.
      local last
      last=$(HISTTIMEFORMAT= history 1 2>/dev/null)
      [[ $last =~ ^[[:space:]]*[0-9]+\*?[[:space:]]+(.*)$ ]] && last=${BASH_REMATCH[1]} || last=
      last=$(_clh_trim "$last")
      if [[ -z $last ]]; then
        _clh_msg "clh: no previous command to fix"
      else
        _CLH_SEEN=("$last")
        _CLH_REQUEST=
        _clh_run 0 "$last" user "$(_clh_fix_msg "$last" "$_CLH_LAST_STATUS")"
      fi
      ;;
    clh)
      _clh_set_line "clh ${reply[1]}"
      _clh_reset
      action=accept-line
      ;;
    explain)
      if [[ -z ${reply[1]} ]]; then
        _clh_msg "usage: <command> ${CLH_PREFIX}?  or  ${CLH_PREFIX}? <command>"
      else
        local cmd=${reply[1]} out
        _clh_set_line "$cmd"
        if _clh_ensure_server; then
          _clh_status "⏳ explaining…"
          if out=$(_clh_explain "$cmd" 2>&1); then
            if [[ $cmd =~ $_CLH_DANGER_RE ]]; then
              _clh_msg $'\e[1;31m⚠\e[0m  '"$out"
            else
              _clh_msg "💡 $out"
            fi
          else
            _clh_msg "$out"
          fi
        fi
      fi
      ;;
  esac
  bind "\"\\C-x}2\": $action"
}

# Tab while a command is pending: clear it.
_clh_tab() {
  _clh_set_line ''
  _clh_reset
}

# Ctrl-N while a command is pending: another suggestion for its request.
_clh_next() {
  (( ${#_CLH_TURNS[@]} >= 4 )) || return
  local -a turns=("${_CLH_TURNS[@]:0:${#_CLH_TURNS[@]}-2}") ask
  local cmd try seen
  _clh_ensure_server || return
  for try in 1 2; do
    ask=("${turns[@]}")
    seen=$(printf ' | %s' "${_CLH_SEEN[@]}")
    ask[${#ask[@]}-1]+=$'\n'"Give a different command than: ${seen:3}"
    _clh_status "⏳ another suggestion…"
    cmd=$(_clh_complete 0.8 "${_CLH_REQUEST:-$READLINE_LINE}" "${ask[@]}" 2>&1) || { _clh_msg "$cmd"; return; }
    _clh_in "$cmd" "${_CLH_SEEN[@]}" || break
  done
  if _clh_in "$cmd" "${_CLH_SEEN[@]}"; then
    _clh_msg "no other suggestion · $_CLH_HINT"
    return
  fi
  _CLH_SEEN+=("$cmd")
  _CLH_TURNS=("${turns[@]}" assistant "$cmd")
  _clh_show "$cmd"
}

# First in PROMPT_COMMAND, so $? is the user's command. Keeps $? for the rest.
_clh_precmd() {
  _CLH_LAST_STATUS=$?
  if (( ${#_CLH_LEARN_PAIR[@]} )); then
    (( _CLH_LAST_STATUS == 0 )) && _clh_learn "${_CLH_LEARN_PAIR[@]}"
    _CLH_LEARN_PAIR=()
  fi
  (( _CLH_PENDING )) && _clh_reset
  return $_CLH_LAST_STATUS
}

if [[ $- == *i* ]]; then
  if [[ -z ${_CLH_ORIG_TAB+set} ]]; then
    declare -gA _CLH_ORIG_TAB=() _CLH_ORIG_NEXT=()
    for _clh_km in "${_CLH_KEYMAPS[@]}"; do
      _CLH_ORIG_TAB[$_clh_km]=$(_clh_orig_binding "$_clh_km" '\C-i')
      _CLH_ORIG_NEXT[$_clh_km]=$(_clh_orig_binding "$_clh_km" '\C-n')
    done
    unset _clh_km
  fi
  for _clh_km in "${_CLH_KEYMAPS[@]}" vi-command; do
    bind -m "$_clh_km" -x '"\C-x}1": _clh_accept_line'
    bind -m "$_clh_km" -x '"\C-x}3": _clh_tab'
    bind -m "$_clh_km" -x '"\C-x}5": _clh_next'
    bind -m "$_clh_km" '"\C-x}2": accept-line'
    bind -m "$_clh_km" '"\C-x}4": redraw-current-line'
    bind -m "$_clh_km" '"\C-x}6": redraw-current-line'
    bind -m "$_clh_km" '"\C-m": "\C-x}1\C-x}2"'
    bind -m "$_clh_km" '"\C-j": "\C-x}1\C-x}2"'
  done
  unset _clh_km

  # Run first so $? is the user's command, not another hook's.
  if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    _clh_pc=()
    for _clh_c in "${PROMPT_COMMAND[@]}"; do [[ $_clh_c == _clh_precmd ]] || _clh_pc+=("$_clh_c"); done
    PROMPT_COMMAND=(_clh_precmd "${_clh_pc[@]}")
    unset _clh_pc _clh_c
  else
    PROMPT_COMMAND=${PROMPT_COMMAND#_clh_precmd}
    PROMPT_COMMAND=${PROMPT_COMMAND#;}
    PROMPT_COMMAND="_clh_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
  fi

  # Load the model in the background so the first query is fast.
  if (( CLH_WARM )); then
    ( curl -s --max-time 60 "$CLH_URL/api/generate" \
        -d "{\"model\":\"$CLH_MODEL\",\"keep_alive\":\"30m\"}" >/dev/null 2>&1 & ) 2>/dev/null
  fi
fi
