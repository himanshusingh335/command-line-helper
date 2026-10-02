# clh.zsh — natural-language → shell command helper for zsh, powered by Ollama.
#
#   :: <what you want>   then Enter  → the generated command replaces the line
#   Enter again                      → run it
#   Tab                              → discard it
#
# Source this file from ~/.zshrc. Requires curl, jq and a running Ollama server.

: ${CLH_MODEL:=qwen2.5-coder:1.5b}
: ${CLH_URL:=http://localhost:11434}
: ${CLH_PREFIX:=::}
: ${CLH_TIMEOUT:=30}
: ${CLH_WARM:=1}

typeset -g _CLH_PENDING=0

# Commands that deserve an extra look before running.
typeset -g _CLH_DANGER_RE='(^|[;&| ])(sudo|rm -[a-zA-Z]*[rf]|dd |mkfs|shred|diskutil (erase|partition)|chmod -R 777|kill -9 -1)|> ?/dev/|git (push.*(-f|--force)|reset --hard|clean -[a-z]*f)|docker (system|volume|image) prune|conda (env )?remove'

typeset -g _CLH_SYSTEM='You are a command-line expert. Convert the user request into ONE shell command for zsh on macOS.
Rules:
- Output ONLY the command on a single line. No explanation, no markdown, no backticks, no leading "$".
- Combine multiple steps with && on the same line.
- macOS uses BSD tools: sed -i '\'''\'', stat -f, date -v, pbcopy, open. Homebrew is available.
- Prefer common tools: git, docker, docker compose, conda, python3, pip, find, grep, rg, du, lsof, tar.
- Use the context (directory, files, git branch, conda env) when it helps; use placeholders like <name> only when the value is truly unknown.'

# Few-shot examples: alternating request / command.
typeset -ga _CLH_EXAMPLES=(
  'create a python virtual environment and activate it'    'python3 -m venv .venv && source .venv/bin/activate'
  'install packages from requirements file'                'pip install -r requirements.txt'
  'create conda env named ml with python 3.11'             'conda create -n ml python=3.11 -y'
  'list conda environments'                                'conda env list'
  'show running docker containers'                         'docker ps'
  'follow logs of container web'                           'docker logs -f web'
  'open a shell inside container api'                      'docker exec -it api /bin/sh'
  'undo last commit but keep the changes'                  'git reset --soft HEAD~1'
  'create and switch to branch feature/login'              'git switch -c feature/login'
  'show git history as a graph'                            'git log --oneline --graph --decorate --all'
  'show size of each folder here sorted'                   'du -sh * | sort -h'
  'extract archive.tar.gz'                                 'tar -xzf archive.tar.gz'
  'search for TODO in all python files'                    'grep -rn "TODO" --include="*.py" .'
  'find files bigger than 100MB'                           'find . -type f -size +100M'
  'what is using port 8080'                                'lsof -i :8080'
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

# Print the generated command for a natural-language query.
# Returns non-zero and prints an error on stderr on failure.
_clh_generate() {
  emulate -L zsh
  local query=$1 payload response err content

  payload=$(jq -nc \
    --arg model "$CLH_MODEL" \
    --arg sys "$_CLH_SYSTEM" \
    --arg q "$(_clh_context)

Request: $query" \
    '{model: $model, stream: false, think: false, keep_alive: "30m",
      options: {temperature: 0, num_predict: 120},
      messages: ([{role: "system", content: $sys}]
        + [$ARGS.positional as $e | range(0; $e | length; 2) as $i
           | {role: "user", content: $e[$i]}, {role: "assistant", content: $e[$i + 1]}]
        + [{role: "user", content: $q}])}' \
    --args "${_CLH_EXAMPLES[@]}") || { print -u2 "clh: failed to build request (jq)"; return 1 }

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

  content=$(jq -r '.message.content // empty' <<<"$response" 2>/dev/null)
  _clh_sanitize "$content" || { print -u2 "clh: model returned no command"; return 1 }
}

# --- ZLE widgets ------------------------------------------------------------

_clh_reset() {
  _CLH_PENDING=0
  region_highlight=()
}

_clh_accept_line() {
  emulate -L zsh
  if [[ $BUFFER != ${CLH_PREFIX}* ]]; then
    _clh_reset
    zle .accept-line
    return
  fi

  local query=${BUFFER#$CLH_PREFIX} cmd
  query=${query##[[:space:]]##}
  if [[ -z $query ]]; then
    zle -M "usage: $CLH_PREFIX <describe the command you want>"
    return
  fi

  zle -M "⏳ thinking ($CLH_MODEL)…"
  zle -R

  # On success only the command is printed; on failure only the error.
  cmd=$(_clh_generate "$query" 2>&1) || {
    zle -M "$cmd"
    return
  }

  BUFFER=$cmd
  CURSOR=${#BUFFER}
  _CLH_PENDING=1
  if [[ $cmd =~ $_CLH_DANGER_RE ]]; then
    region_highlight=("0 ${#BUFFER} fg=red,bold")
    zle -M "⚠  potentially destructive — review carefully · ↵ run · ⇥ clear"
  else
    region_highlight=("0 ${#BUFFER} fg=cyan")
    zle -M "↵ run · ⇥ clear · or edit it first"
  fi
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

_clh_line_init() {
  _clh_reset
}

if [[ -o interactive ]]; then
  autoload -Uz add-zle-hook-widget
  zle -N _clh_accept_line
  zle -N _clh_tab
  zle -N _clh_line_init
  add-zle-hook-widget line-init _clh_line_init
  bindkey '^M' _clh_accept_line
  bindkey '^I' _clh_tab

  # Load the model in the background so the first query is fast.
  if (( CLH_WARM )); then
    ( curl -s --max-time 60 "$CLH_URL/api/generate" \
        -d "{\"model\":\"$CLH_MODEL\",\"keep_alive\":\"30m\"}" >/dev/null 2>&1 & ) 2>/dev/null
  fi
fi
