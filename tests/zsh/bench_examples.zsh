#!/usr/bin/env zsh
# Compare few-shot selection modes against the real model and score the
# results with accept patterns. Needs Ollama and `ollama pull nomic-embed-text`.
#   tests/run.sh bench zsh                  # all modes
#   tests/run.sh bench zsh -v               # also print every answer
#   CLH_MODEL=qwen3.5:4b tests/run.sh bench zsh
zmodload zsh/datetime
CLH_WARM=0 source ${0:A:h:h:h}/clh.zsh
verbose=0; [[ $1 == -v ]] && verbose=1

tmpdir=$(mktemp -d); trap 'rm -rf $tmpdir' EXIT
stats=$tmpdir/stats

# Record prompt size of each chat call without changing the plugin.
curl() {
  local out; out=$(command curl "$@") || return
  [[ $* == */api/chat* ]] && jq -r '.prompt_eval_count // 0' <<<"$out" >> $stats
  print -r -- "$out"
}

# request, accept pattern (ERE matched against the generated command)
general=(
  'show my PATH one entry per line'                 'tr .:. .\\n.|echo -e|\$\{?path|sed'
  'how much free disk space'                        '^df'
  'kill the process on port 3000'                   'lsof -t?i ?(tcp)?:3000'
  'show the 10 largest files in this folder'        '(ls -[a-z]*S|sort -[a-z]*[nh]).*(head|-10)|head.*10'
  'run tests with pytest verbose'                   '^(python3? -m )?pytest (.* )?-v'
  'start a simple http server on port 8000'         'http\.server 8000'
  'freeze installed packages to requirements.txt'   'pip3? freeze > requirements\.txt'
  'upgrade pip'                                     'pip3? install (--upgrade|-U) pip'
  'activate the ml environment'                     'conda activate ml'
  'export current conda env to yaml'                'conda env export.*\.ya?ml'
  'delete conda env named old'                      'conda (env )?remove (-n|--name) old'
  'install numpy with conda from conda-forge'       'conda install (-c|--channel) conda-forge numpy|numpy.*-c conda-forge'
  'create conda env in current folder'              'conda create -p \./\.conda'
  'make conda environment here with python 3.10'    'conda create -p \./\.conda python=3\.10'
  'activate the env in this folder'                 'conda activate \./\.conda'
  'delete the conda env in this directory'          'conda remove -p \./\.conda --all'
  'create a venv here'                              'python3? -m venv'
  'stop all running containers'                     'docker stop \$\(docker ps -q\)'
  'remove dangling images'                          'docker image prune( -f)?$|dangling=true'
  'start docker compose in background'              'docker[ -]compose up -d'
  'build image tagged myapp from this directory'    'docker build -t myapp \.'
  'discard changes to main.py'                      'git (restore|checkout --) main\.py'
  'show what changed in last commit'                'git (show|diff HEAD~1|log -1 -p)'
  'list all branches including remote'              'git branch -a'
  'stash my changes with a message wip'             'git stash (push )?-m "?wip'
  'make deploy.sh executable'                       'chmod (\+x|755|u\+x) \.?/?deploy\.sh'
  'compress the logs folder into logs.tar.gz'       'tar -c?z?c?v?z?f logs\.tar\.gz \.?/?logs'
  'count lines in all python files'                 '\.py.*wc -l|wc -l.*\.py'
  'find all files named config.yaml'                'find \. .*-name "?config\.yaml'
  'search for the word password ignoring case recursively'  'grep -[a-z]*(ri|ir)[a-z]* "?password'
  'show disk usage of each folder here'             'du -[a-z]*s[a-z]* \*|du -[a-z]*d ?1'
  'what is listening on port 5432'                  'lsof -i ?(tcp)?:5432'
)

# Personal pairs the user "accepted" earlier, and paraphrased requests.
learned=(
  'deploy to staging'                 './scripts/deploy.sh staging'
  'tail api logs'                     'docker compose logs -f api'
  'open my project notes'             'code ~/notes/project.md'
  'run the backend tests'             'make test-backend'
  'connect to the dev database'       'psql -h localhost -U dev appdb'
  'rebuild the frontend'              'npm --prefix web run build'
  'sync photos to the nas'            'rsync -av ~/Pictures/ nas:/photos/'
  'show running docker containers'    'docker ps --format "table {{.Names}}\t{{.Status}}"'
  'activate work env'                 'conda activate ./.conda'
  'start the dev server'              'npm run dev -- --port 4000'
)
personal=(
  'deploy the app to staging'         'deploy\.sh staging'
  'ship it to staging'                'deploy\.sh staging'
  'show the api logs'                 'docker compose logs -f api'
  'follow api output'                 'docker compose logs -f api'
  'open the project notes'            'notes/project\.md'
  'test the backend'                  'make test-backend'
  'connect to dev db'                 'psql -h localhost -U dev appdb'
  'build the web frontend'            'npm --prefix web run build'
  'back up my photos to the nas'      'rsync .*Pictures.*nas:/photos'
  'list running containers'           'docker ps --format'
  'start dev server'                  'npm run dev -- --port 4000'
  'run the server for development'    'npm run dev -- --port 4000'
)

# run <label> <mode> <history:0|1> <pairs...> → prints "pass/total ms tokens"
run() {
  local label=$1 mode=$2 hist=$3; shift 3
  local -a times; local q re out s pass=0 n=0
  CLH_HISTORY_FILE=$tmpdir/$label/history.jsonl CLH_EXAMPLE_MODE=$mode
  mkdir -p $tmpdir/$label
  if (( hist )); then for q re in $learned; do _clh_learn "$q" "$re"; done; fi
  [[ $mode == embed ]] && _clh_select_examples warmup >/dev/null   # fill the embed cache
  : > $stats
  for q re in "$@"; do
    s=$EPOCHREALTIME
    out=$(_clh_generate "$q" 2>&1)
    times+=($(( (EPOCHREALTIME - s) * 1000 )))
    (( n++ ))
    if [[ $out =~ $re ]]; then (( pass++ )); r=ok; else r=MISS; fi
    print -r -- "$label	$q	$r	$out" >> $tmpdir/answers
  done
  times=(${(n)times})
  printf '%-22s %5s  %6.0f ms  %5.0f tok\n' $label "$pass/$n" ${times[$(( (n + 1) / 2 ))]} \
    $(jq -s 'add / length' $stats)
}

print "model: $CLH_MODEL   K=$CLH_EXAMPLES_K   embed: $CLH_EMBED_MODEL"
print "\nlabel                   pass  median latency  avg prompt"
print -- "--- general requests"
run gen-all      all     0 $general
run gen-keyword  keyword 0 $general
run gen-embed    embed   0 $general
print -- "--- personal requests (learned history)"
run per-all-nohist  all  0 $personal
run per-all      all     1 $personal
run per-keyword  keyword 1 $personal
run per-embed    embed   1 $personal

print "\n--- requests where modes disagree"
awk -F'\t' '{ split($1, a, "-"); key = a[1] "\t" $2; res[key] = res[key] sprintf(" %s=%s", substr($1, length(a[1]) + 2), $3) }
            END { for (k in res) if (res[k] ~ /ok/ && res[k] ~ /MISS/) { split(k, p, "\t"); printf "%-40s%s\n", p[2], res[k] } }' $tmpdir/answers | sort
(( verbose )) && { print "\n--- answers"; column -t -s $'\t' $tmpdir/answers }
