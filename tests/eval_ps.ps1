# Run sample requests through the model with clh.ps1 and print the results
# (nothing is asserted). Usually run via: tests/run_containers.sh --eval
$env:CLH_WARM = '0'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('clh-eval-' + [guid]::NewGuid())
$env:CLH_HISTORY_FILE = Join-Path $tmp 'history.jsonl'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'clh.ps1')

"platform: $($global:_ClhPlatform) ($(_clh_os_name))"
$queries = @(
  'show my PATH one entry per line'
  'how much free disk space'
  'kill the process on port 3000'
  'show the 10 largest files in this folder'
  'find files modified in the last day'
  'replace foo with bar in config.txt'
  'show running processes sorted by memory'
  'download https://example.com/a.zip'
  'start a simple http server on port 8000'
  'create conda env in current folder'
  'stop all running containers'
  'discard changes to main.py'
  'compress the logs folder into logs.zip'
  'search for the word password in all files recursively'
  'count lines in all python files'
  'set an environment variable API_KEY to abc for this session'
)
foreach ($q in $queries) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = try { _clh_generate $q } catch { "$_" }
  '{0,-55} → {1}  ({2:N2}s)' -f $q, $out, $sw.Elapsed.TotalSeconds
}

"`n--- fix"
foreach ($c in @(@('gti status', 0, ''), @('Get-Proces', 0, ''), @('Get-ChildItem -Recurce', 0, "A parameter cannot be found that matches parameter name 'Recurce'."))) {
  $out = try { _clh_complete 0 $c[0] @('user', (_clh_fix_msg $c[0] $c[1] $c[2])) } catch { "$_" }
  '{0,-30} → {1}' -f $c[0], $out
}

"`n--- explain"
foreach ($c in 'Remove-Item build -Recurse -Force', 'Get-NetTCPConnection -State Listen', 'Get-Content log.txt -Tail 20 -Wait') {
  $out = try { _clh_explain $c } catch { "$_" }
  '{0,-40} → {1}' -f $c, $out
}

"`n--- learned (seeded history; paraphrased requests)"
_clh_learn 'deploy to staging' '.\scripts\deploy.ps1 -Env staging'
_clh_learn 'tail api logs' 'docker compose logs -f api'
foreach ($q in 'deploy the app to staging', 'show the api logs') {
  $out = try { _clh_generate $q } catch { "$_" }
  '{0,-40} → {1}' -f $q, $out
}
Remove-Item -Recurse -Force $tmp -ErrorAction Ignore
