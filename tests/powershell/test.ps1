# Unit tests for the deterministic parts of clh.ps1 (no model needed).
#   pwsh -NoProfile -File tests/powershell/test.ps1      (or tests/run.sh unit powershell)
# Ignore the user's environment and saved settings, and keep every default
# path (history, config) inside a temp dir.
Get-ChildItem env:CLH_* -ErrorAction Ignore | Remove-Item
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('clh-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:XDG_DATA_HOME = "$tmp/data"; $env:XDG_CONFIG_HOME = "$tmp/config"
$env:LOCALAPPDATA = "$tmp/data"; $env:APPDATA = "$tmp/config"
$env:CLH_CONFIG_FILE = "$tmp/config/clh/config.json"
$plugin = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'clh.ps1'
. $plugin

$script:fails = 0
function check($got, $want, [string]$name) {
  if ([string]$got -ceq [string]$want) { "ok   $name" }
  else { "FAIL ${name}: got [$got] want [$want]"; $script:fails++ }
}
function joined($a) { @($a) -join '|' }

try {
check (_clh_sanitize 'git status')                       'git status'      plain
check (_clh_sanitize "``````powershell`nGet-ChildItem`n``````")  'Get-ChildItem'  fenced
check (_clh_sanitize '$ docker ps')                      'docker ps'       dollar-prefix
check (_clh_sanitize 'PS C:\Users\me> Get-Process')      'Get-Process'     ps-prompt-prefix
check (_clh_sanitize '`conda env list`')                 'conda env list'  backticks
check (_clh_sanitize "`n   Get-Date  `nexplanation")     'Get-Date'        first-line-trimmed
check ($null -eq (_clh_sanitize "``````n``````"))        'True'            empty-returns-null

function danger([string]$c) { if ($c -match $global:_CLH_DANGER_RE) { 'yes' } else { 'no' } }
check (danger 'Remove-Item build -Recurse -Force')       yes  danger-remove-recurse
check (danger 'rm -r build')                             yes  danger-rm-r
check (danger 'Get-ChildItem *.tmp | Remove-Item -Force') yes danger-pipe-remove-force
check (danger 'Stop-Process -Name chrome -Force')        yes  danger-stop-force
check (danger 'Format-Volume -DriveLetter D')            yes  danger-format
check (danger 'git push --force')                        yes  danger-force-push
check (danger 'docker system prune -a')                  yes  danger-prune
check (danger 'Remove-Item notes.txt')                   no   safe-remove-one-file
check (danger 'Get-ChildItem -Recurse')                  no   safe-gci-recurse
check (danger 'git status')                              no   safe-git

function hint([string]$q) { $h = _clh_hints $q; if ($h -match 'Answer with: conda [a-z]*') { $Matches[0] } else { 'none' } }
check (hint 'create conda env in current folder')  'Answer with: conda create'    hint-create
check (hint 'make conda environment HERE')         'Answer with: conda create'    hint-case-insensitive
check (hint 'activate the env in this folder')     'Answer with: conda activate'  hint-activate
check (hint 'delete the local conda env')          'Answer with: conda remove'    hint-remove
check (hint 'create conda env named ml')           none                           hint-named-env
check (hint 'create a venv here')                  none                           hint-venv

function parse([string]$l) { joined (_clh_parse $l) }
check (parse ':: list containers')                 'new|list containers'                   parse-new
check (parse '::list containers')                  'new|list containers'                   parse-new-nospace
check (parse ':: ')                                'new|'                                  parse-new-empty
check (parse '::fix')                              'fix'                                   parse-fix
check (parse '  ::fix   ')                         'fix'                                   parse-fix-spaces
check (parse '::fixed it')                         'new|fixed it'                          parse-fix-prefix-only
check (parse '::? Remove-Item x -Recurse')         'explain|Remove-Item x -Recurse'        parse-explain-prefix
check (parse 'Remove-Item x -Recurse ::?')         'explain|Remove-Item x -Recurse'        parse-explain-suffix
check (parse 'Get-ChildItem :: only py files')     'refine|Get-ChildItem|only py files'    parse-refine
check (parse 'a :: b :: c')                        'refine|a :: b|c'                       parse-refine-last
check (parse '[math]::Round(2.5)')                 'run'                                   parse-static-member
check (parse 'git status')                         'run'                                   parse-run
check (parse '')                                   'run'                                   parse-empty
check (parse '::help')                             'clh|help'                              parse-help
check (parse '::settings')                         'clh|settings'                          parse-settings

function fixmsg($c, $code, $err) { $m = _clh_fix_msg $c $code $err; ($m -split "`n" | Where-Object { $_ -like 'This command*' }) }
check (fixmsg 'gti status' 0 '')          "This command failed: 'gti' is not a known command (probably misspelled):"     fixmsg-not-found
check (fixmsg 'Get-ChildItem -Recurce' 0 "A parameter cannot be found that matches parameter name 'Recurce'.") `
  "This command failed with the error `"A parameter cannot be found that matches parameter name 'Recurce'.`":"    fixmsg-error
check (fixmsg 'git psuh' 1 '')            'This command failed with exit code 1 (likely wrong flags or arguments):'      fixmsg-exit-code
check (fixmsg 'Get-Date' 0 '')            'This command ran but did not do what the user wanted:'                        fixmsg-ran
check ((_clh_fix_msg 'gti status' 0 '').EndsWith($global:_CLH_FIX_TAIL))  'True'                                         fixmsg-tail

$global:CLH_URL = 'http://example.com:11434'
$e = try { _clh_start_server; 'started' } catch { "$_" }
check $e 'clh: cannot reach Ollama at http://example.com:11434 (not local, so not starting it)'  autostart-remote-refused
$global:CLH_URL = 'http://localhost:1'
check (_clh_server_up) 'False'                                                                   server-up-detects-down
$global:CLH_URL = 'http://localhost:11434'

# --- learning and example selection
$global:CLH_HISTORY_FILE = "$tmp/clh/history.jsonl"
function users($turns) { (@($turns | Where-Object { $_.role -eq 'user' } | ForEach-Object { $_.content })) -join '|' }
function last_user($turns) { @($turns | Where-Object { $_.role -eq 'user' })[-1].content }

_clh_learn 'deploy to staging' './scripts/deploy.sh staging'
_clh_learn 'nuke build' 'Remove-Item build -Recurse -Force'
$global:CLH_LEARN = '0'; _clh_learn 'list stuff' 'ls'; $global:CLH_LEARN = '1'
check (joined ((_clh_read_history).r))  'deploy to staging'                       learn-appends-skips-danger-and-off
if (-not $global:_ClhIsWindows) { check ([int](Get-Item $global:CLH_HISTORY_FILE).UnixFileMode) 384 learn-private-file }

$global:CLH_HISTORY_MAX = '3'
foreach ($i in 1..3) { _clh_learn "req $i" "echo $i"; Start-Sleep -Milliseconds 5 }
_clh_learn 'REQ 3' 'echo 3b'
check (joined ((_clh_read_history).c))  'echo 1|echo 2|echo 3b'                   learn-dedupes-and-trims
$global:CLH_HISTORY_MAX = '500'

Remove-Item $global:CLH_HISTORY_FILE
$want = ConvertTo-Json -Compress -Depth 4 -InputObject (_clh_pair_turns ($global:_CLH_EXAMPLES + $global:_CLH_FIX_EXAMPLES))
check (ConvertTo-Json -Compress -Depth 4 -InputObject (_clh_select_examples 'x'))  $want   select-all-unchanged

$global:CLH_EXAMPLE_MODE = 'keyword'
$sel = _clh_select_examples 'kill the process on port 5000'
check $sel.Count 16                                                               select-keyword-k
check (last_user $sel) 'kill whatever is running on port 5000'                    select-keyword-closest-last
check (users (_clh_select_examples 'zzz qqq')) (users (_clh_pair_turns $global:_CLH_EXAMPLES[0..15]))  select-keyword-no-match-defaults
check (_clh_select_examples 'gti status' $true)[-1].content 'git commit -m "init"'  select-keyword-fix-examples

_clh_learn 'show running docker containers' 'docker ps --format "{{.Names}}"'
_clh_learn 'tail api logs' 'docker compose logs -f api'
check (_clh_select_examples 'show running docker containers')[-1].content 'docker ps --format "{{.Names}}"'  select-learned-overrides-builtin
check (last_user (_clh_select_examples 'api logs please')) 'tail api logs'        select-learned-match
$global:CLH_EXAMPLE_MODE = 'all'
check (_clh_select_examples 'api logs')[-2].content 'tail api logs'               select-all-appends-learned

# --- settings and the clh command
function setting($n) { $s = _clh_setting $n; if ($s) { "$($s[0])|$($s[1])" } else { 'none' } }
check (setting model)         'CLH_MODEL|str'                       setting-short-name
check (setting example-mode)  'CLH_EXAMPLE_MODE|all|keyword|embed'  setting-dashes
check (setting CLH_LEARN)     'CLH_LEARN|bool'                      setting-full-name
check (setting nope)          none                                  setting-unknown

function value($t, $v) { $r = _clh_check_value $t $v; if ($null -eq $r) { 'bad' } else { $r } }
check "$(value bool on),$(value bool False),$(value bool 2)"   '1,0,bad'     value-bool
check "$(value int 12),$(value int 0),$(value int x)"          '12,bad,bad'  value-int
check "$(value 'all|keyword|embed' embed),$(value 'all|keyword|embed' em),$(value 'all|keyword|embed' 'all|embed')" 'embed,bad,bad' value-enum

clh set model 'my model:7b' | Out-Null
clh set learn off | Out-Null
check "$($global:CLH_MODEL)|$($global:CLH_LEARN)"  'my model:7b|0'                         set-applies-now
check (clh set timeout soon 2>&1)                  "clh: timeout must be a number, not 'soon'"  set-rejects-bad-value
check (clh set colour red 2>&1)                    "clh: unknown setting 'colour' (see: clh config)"  set-rejects-unknown
$cfg = Get-Content -Raw $global:CLH_CONFIG_FILE | ConvertFrom-Json
check (joined $cfg.PSObject.Properties.Name)       'CLH_MODEL|CLH_LEARN'                   set-saves-once-each
if (-not $global:_ClhIsWindows) { check ([int](Get-Item $global:CLH_CONFIG_FILE).UnixFileMode) 384 set-private-file }
check (_clh_setting_source CLH_MODEL 'qwen2.5-coder:1.5b')  saved                          source-saved

# A new shell loads saved values; a non-default value set beforehand wins.
function loaded([string]$pre) {
  $script = "Get-ChildItem env:CLH_* | Remove-Item; $pre `$env:CLH_CONFIG_FILE = '$($global:CLH_CONFIG_FILE)'; . '$plugin'; `"`$(`$global:CLH_MODEL)|`$(`$global:CLH_LEARN)`""
  pwsh -NoProfile -NonInteractive -Command $script
}
check (loaded '')                                       'my model:7b|0'  load-saved
check (loaded '$env:CLH_MODEL = ''other'';')            'other|0'        load-preset-wins
check (loaded '$CLH_MODEL = ''qwen2.5-coder:1.5b'';')   'my model:7b|0'  load-restated-default-ignored

clh reset model | Out-Null
$cfg = Get-Content -Raw $global:CLH_CONFIG_FILE | ConvertFrom-Json
check "$($global:CLH_MODEL)|$(joined $cfg.PSObject.Properties.Name)"  'qwen2.5-coder:1.5b|CLH_LEARN'  reset-one
clh reset --all | Out-Null
check "$($global:CLH_LEARN)|$(Test-Path $global:CLH_CONFIG_FILE)"     '1|False'                       reset-all

$global:CLH_HISTORY_FILE = "$tmp/clh/history.jsonl"   # reset --all restored the default
Remove-Item $global:CLH_HISTORY_FILE -ErrorAction Ignore
_clh_learn 'list pods' 'kubectl get pods'
check (clh history 1)                         'list pods  → kubectl get pods'  history-shows-pairs
_clh_learn 'list nodes' 'kubectl get nodes'
_clh_learn 'list files' 'ls'
check (clh forget KUBECTL)                    'forgot 2 of 3'                  forget-matching
check (@(clh history | Where-Object { $_ -like '*pods*' }).Count)  0          forget-removed

check ((_clh_dump_data | ConvertFrom-Json).settings.Count)  13                  dump-data
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction Ignore
}

if ($script:fails) { "$($script:fails) failed"; exit 1 }
'all passed'
