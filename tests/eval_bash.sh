#!/usr/bin/env bash
# Run sample requests through the model with clh.bash and print the results
# (nothing is asserted). Usually run via: tests/run_containers.sh --eval
CLH_WARM=0 source "$(cd "$(dirname "$0")/.." && pwd)/clh.bash"
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
CLH_HISTORY_FILE=$tmpdir/history.jsonl

echo "platform: $_CLH_PLATFORM ($(_clh_os_name))"
queries=(
  "show my PATH one entry per line"
  "how much free disk space"
  "kill the process on port 3000"
  "what is listening on port 5432"
  "install htop"
  "show the 10 largest files in this folder"
  "find files modified in the last day"
  "replace foo with bar in config.txt"
  "open the current folder in the file manager"
  "show my ip address"
  "start a simple http server on port 8000"
  "create conda env in current folder"
  "stop all running containers"
  "discard changes to main.py"
  "compress the logs folder into logs.tar.gz"
  "search for the word password ignoring case recursively"
)
for q in "${queries[@]}"; do
  s=$EPOCHREALTIME
  out=$(_clh_generate "$q" 2>&1)
  printf '%-55s → %s  (%.2fs)\n' "$q" "$out" "$(echo "$EPOCHREALTIME - $s" | awk '{print $1 - $3}')"
done

echo; echo "--- fix"
for c in 'gti status:127' 'pyhton3 app.py:127' 'git psuh origin main:1'; do
  printf '%-30s → %s\n' "${c%:*}" "$(_clh_complete 0 "${c%:*}" user "$(_clh_fix_msg "${c%:*}" "${c##*:}")" 2>&1)"
done

echo; echo "--- explain"
for c in 'rm -rf build' 'ss -tlnp' 'sed -i s/a/b/g f.txt'; do
  printf '%-30s → %s\n' "$c" "$(_clh_explain "$c" 2>&1)"
done

echo; echo "--- learned (seeded history; paraphrased requests)"
_clh_learn 'deploy to staging' './scripts/deploy.sh staging'
_clh_learn 'tail api logs' 'docker compose logs -f api'
for q in 'deploy the app to staging' 'show the api logs'; do
  printf '%-40s → %s\n' "$q" "$(_clh_generate "$q" 2>&1)"
done
