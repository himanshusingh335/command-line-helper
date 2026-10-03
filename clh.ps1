# clh.ps1 — natural-language → shell command helper for PowerShell, powered by Ollama.
# The PowerShell port of clh.zsh (Windows; PowerShell 7+, best effort on 5.1).
#
#   :: <what you want>     Enter → the generated command replaces the line
#   Enter again                   → run it
#   Tab                           → discard it
#   Ctrl+N                        → another suggestion for the same request
#   <cmd> :: <change>       Enter → revise the command on the line
#   <cmd> ::?  or  ::? <cmd> Enter → explain a command without running it
#   ::fix                   Enter → correct the last command you ran
#   ::help / ::settings     Enter → this help / change settings (also: clh help)
#
# Dot-source this file from $PROFILE (after any Set-PSReadLineOption -EditMode).
# Requires a running Ollama server; no curl or jq needed.

$global:_ClhIsWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$global:_ClhUtf8 = New-Object System.Text.UTF8Encoding $false

if ($global:_ClhIsWindows) {
  $global:_ClhDataDir = Join-Path $env:LOCALAPPDATA 'clh'
  $global:_ClhConfigDir = Join-Path $env:APPDATA 'clh'
} else {
  $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
  $global:_ClhDataDir = Join-Path $base 'clh'
  $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
  $global:_ClhConfigDir = Join-Path $base 'clh'
}

# Settings: name, type (bool, int, str or a|b|c), default, description.
# Precedence: set to a non-default value before this file is dot-sourced
# ($env:CLH_X or $CLH_X in $PROFILE) > saved with `clh set` > default.
$global:_CLH_SETTINGS = @(
  @('CLH_MODEL',        'str',               'qwen2.5-coder:1.5b',     'Ollama model that writes the commands'),
  @('CLH_URL',          'str',               'http://localhost:11434', 'Ollama server'),
  @('CLH_PREFIX',       'str',               '::',                     'trigger prefix'),
  @('CLH_TIMEOUT',      'int',               '30',                     'seconds to wait for the model'),
  @('CLH_WARM',         'bool',              '1',                      'preload the model when a shell starts'),
  @('CLH_AUTOSTART',    'bool',              '1',                      'start ollama serve if it is down (local URL only)'),
  @('CLH_OLLAMA_LOG',   'str',               (Join-Path $HOME '.ollama/clh-serve.log'), 'log file of a server started by clh'),
  @('CLH_LEARN',        'bool',              '1',                      'learn from generated commands you run'),
  @('CLH_HISTORY_FILE', 'str',               (Join-Path $global:_ClhDataDir 'history.jsonl'), 'learned request → command pairs'),
  @('CLH_HISTORY_MAX',  'int',               '500',                    'learned pairs to keep'),
  @('CLH_EXAMPLE_MODE', 'all|keyword|embed', 'all',                    'examples sent: all built-ins + closest learned (fastest), or only the K most similar by words / embeddings'),
  @('CLH_EXAMPLES_K',   'int',               '8',                      'examples sent in keyword / embed mode'),
  @('CLH_EMBED_MODEL',  'str',               'nomic-embed-text',       'embedding model for embed mode')
)

function _clh_get([string]$name) { (Get-Variable -Name $name -Scope Global -ValueOnly -ErrorAction SilentlyContinue) }
function _clh_put([string]$name, $value) { Set-Variable -Name $name -Value ([string]$value) -Scope Global }

if (-not $env:CLH_CONFIG_FILE -and -not (_clh_get 'CLH_CONFIG_FILE')) { _clh_put CLH_CONFIG_FILE (Join-Path $global:_ClhConfigDir 'config.json') }
elseif ($env:CLH_CONFIG_FILE) { _clh_put CLH_CONFIG_FILE $env:CLH_CONFIG_FILE }

function _clh_read_config {
  $saved = @{}
  if (Test-Path -LiteralPath $global:CLH_CONFIG_FILE) {
    try {
      $obj = [IO.File]::ReadAllText($global:CLH_CONFIG_FILE) | ConvertFrom-Json
      foreach ($p in $obj.PSObject.Properties) { $saved[$p.Name] = [string]$p.Value }
    } catch { }
  }
  $saved
}

# Settings set to a non-default value before the plugin loaded; they beat
# saved ones. (Restating a default doesn't count.)
function _clh_load_settings {
  $global:_CLH_PRESET = @()
  $saved = _clh_read_config
  foreach ($s in $global:_CLH_SETTINGS) {
    $n = $s[0]; $d = $s[2]
    $pre = [Environment]::GetEnvironmentVariable($n)
    if (-not $pre) { $pre = _clh_get $n }
    if ($pre -and [string]$pre -cne $d) {
      $global:_CLH_PRESET += $n
      _clh_put $n $pre
    } elseif ($saved.ContainsKey($n)) {
      _clh_put $n $saved[$n]
    } else {
      _clh_put $n $d
    }
  }
}
_clh_load_settings

$global:_CLH_PENDING = $false
# Conversation behind the generated command (role/content pairs) and the
# commands already suggested for it; both live only while it is pending.
$global:_CLH_TURNS = @()
$global:_CLH_SEEN = @()
# The request behind the pending command, and the pair waiting to be checked
# (did the command succeed?) before it is learned.
$global:_CLH_REQUEST = ''
$global:_CLH_LEARN_PAIR = $null
# State just before the last command ran, to tell what it changed.
$global:_CLH_BEFORE = @{ Error = $null; HistoryId = 0 }

# Commands that deserve an extra look before running.
$global:_CLH_DANGER_RE = '(?i)(Remove-Item\b.*\s-(Recurse|Force)|(^|[;|&(\s])(rm|ri|del|erase|rd|rmdir)\s(.*\s)?-(r|rf|recurse|force)\b|Format-Volume|Clear-Disk|Initialize-Disk|Remove-Partition|Stop-Computer|Restart-Computer|Set-ExecutionPolicy|Stop-Process\b.*-Force|\btaskkill\b.*/f|reg(\.exe)? delete|Remove-ItemProperty|\bsudo\b|git (push.*(-f|--force)|reset --hard|clean -[a-z]*f)|docker (system|volume|image) prune|conda (env )?remove)'

if ($global:_ClhIsWindows) {
  $global:_ClhPlatform = 'PowerShell on Windows'
  $global:_ClhPlatformRules = @'
- Use PowerShell cmdlets: Get-ChildItem, Select-String, Get-Content, Set-Content, Get-Process, Stop-Process, Get-NetTCPConnection, Compress-Archive, Expand-Archive, Invoke-WebRequest. Do not use Unix-only tools (grep, sed, awk, lsof, xargs, chmod).
- Prefer common tools when they fit: git, docker, docker compose, conda, python, pip, winget.
- Paths use backslashes (.\folder); environment variables are $env:NAME.
'@
} else {
  $global:_ClhPlatform = 'PowerShell on ' + $(if ($IsMacOS) { 'macOS' } else { 'Linux' })
  $global:_ClhPlatformRules = @'
- Use PowerShell cmdlets (Get-ChildItem, Select-String, Get-Content, Get-Process, Stop-Process); native Unix tools (ls, grep, ps, lsof) are available too.
- Prefer common tools when they fit: git, docker, docker compose, conda, python3, pip.
'@
}

$global:_CLH_SYSTEM = @"
You are a command-line expert. Convert the user request into ONE command for $($global:_ClhPlatform).
Rules:
- Output ONLY the command on a single line. No explanation, no markdown, no backticks, no leading "PS>".
- Combine multiple steps with ; on the same line.
$($global:_ClhPlatformRules.TrimEnd())
- conda env "here" / "in this folder" / "local" / "-p" means a prefix env: conda create -p .\.conda ..., activated with conda activate .\.conda.
- Do exactly what was asked: never add destructive or extra flags (like --hard, -Force, -Recurse, file filters) the user did not ask for.
- Use the context (directory, files, git branch, conda env) when it helps; use placeholders like <name> only when the value is truly unknown.
"@

$global:_CLH_EXPLAIN_SYSTEM = @"
You explain PowerShell and shell commands for $($global:_ClhPlatform).
Reply with ONE short plain sentence (at most 20 words) saying exactly what the command does. No markdown.
"@

$global:_CLH_EXPLAIN_EXAMPLES = @(
  'user', 'docker ps -a',                                    'assistant', 'Lists all Docker containers, including stopped ones.',
  'user', 'git stash pop',                                   'assistant', 'Re-applies your most recently stashed changes and removes them from the stash.',
  'user', 'Get-ChildItem -Recurse -Filter *.log | Remove-Item', 'assistant', 'Deletes every .log file in this folder and its subfolders.',
  'user', 'Get-NetTCPConnection -LocalPort 8080',            'assistant', 'Shows the network connection using local port 8080, including its owning process ID.'
)

# Few-shot examples: alternating request / command.
$global:_CLH_EXAMPLES = @(
  'create a python virtual environment and activate it',  'python -m venv .venv; .\.venv\Scripts\Activate.ps1',
  'make a venv here',                                     'python -m venv .venv',
  'install packages from requirements file',              'pip install -r requirements.txt',
  'create conda env named ml with python 3.11',           'conda create -n ml python=3.11 -y',
  'make a conda env in this folder',                      'conda create -p .\.conda python=3.11 -y',
  'local conda env with python 3.9 and pandas',           'conda create -p .\.conda python=3.9 pandas -y',
  'activate the conda env in this folder',                'conda activate .\.conda',
  'remove the local conda env',                           'conda remove -p .\.conda --all -y',
  'list conda environments',                              'conda env list',
  'show running docker containers',                       'docker ps',
  'start compose services in background',                 'docker compose up -d',
  'follow logs of container web',                         'docker logs -f web',
  'undo last commit but keep the changes',                'git reset --soft HEAD~1',
  'create and switch to branch feature/login',            'git switch -c feature/login',
  'show git history as a graph',                          'git log --oneline --graph --decorate --all',
  'discard local changes to app.js',                      'git restore app.js',
  'list files including hidden ones',                     'Get-ChildItem -Force',
  'show size of each folder here',                        'Get-ChildItem -Directory | ForEach-Object { [pscustomobject]@{ Name = $_.Name; MB = [math]::Round((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1) } } | Sort-Object MB',
  'extract archive.zip',                                  'Expand-Archive archive.zip -DestinationPath .',
  'zip the logs folder',                                  'Compress-Archive -Path logs -DestinationPath logs.zip',
  'search for TODO in all python files',                  'Get-ChildItem -Recurse -Filter *.py | Select-String -Pattern "TODO"',
  'search for error in every file',                       'Get-ChildItem -Recurse -File | Select-String -Pattern "error"',
  'replace http with https in urls.txt',                  '(Get-Content urls.txt -Raw) -replace "http:", "https:" | Set-Content urls.txt',
  'files changed in the last 7 days',                     'Get-ChildItem -Recurse -File | Where-Object LastWriteTime -gt (Get-Date).AddDays(-7)',
  'count lines in all js files',                          '(Get-ChildItem -Recurse -Filter *.js | Get-Content | Measure-Object -Line).Lines',
  'show the 5 biggest files here',                        'Get-ChildItem -File | Sort-Object Length -Descending | Select-Object -First 5 Name, Length',
  'find files bigger than 100MB',                         'Get-ChildItem -Recurse -File | Where-Object Length -gt 100MB',
  'what is using port 8080',                              'Get-NetTCPConnection -LocalPort 8080 | Select-Object LocalPort, State, OwningProcess',
  'kill whatever is running on port 5000',                'Stop-Process -Id (Get-NetTCPConnection -LocalPort 5000).OwningProcess',
  'show PATH one entry per line',                         '$env:PATH -split [IO.Path]::PathSeparator',
  'install git',                                          'winget install --id Git.Git -e'
)

# Fix examples (same wording as _clh_fix_msg), used for ::fix.
$global:_CLH_FIX_TAIL = 'Output only the corrected command.'
$global:_CLH_FIX_EXAMPLES = @(
  "This command failed: 'gti' is not a known command (probably misspelled):`ngti status`nOutput only the corrected command.",  'git status',
  "This command failed: 'Get-Proces' is not a known command (probably misspelled):`nGet-Proces -Name chrome`nOutput only the corrected command.",  'Get-Process -Name chrome',
  "This command failed with the error `"A parameter cannot be found that matches parameter name 'Recurce'.`":`nGet-ChildItem -Recurce -Filter *.log`nOutput only the corrected command.",  'Get-ChildItem -Recurse -Filter *.log',
  "This command failed with exit code 1 (likely wrong flags or arguments):`ngit comit -m `"init`"`nOutput only the corrected command.",  'git commit -m "init"'
)

# --- core -------------------------------------------------------------------

# Clean raw model output into a single command line ($null if there is none).
function _clh_sanitize([string]$text) {
  foreach ($line in ($text -split "`r?`n")) {
    $l = $line.Trim()
    if (-not $l -or $l.StartsWith('```')) { continue }
    $l = $l -replace '^(PS [^>]*> |PS> |\$ |% |> )', ''
    if ($l.Length -ge 2 -and $l.StartsWith('`') -and $l.EndsWith('`')) { $l = $l.Substring(1, $l.Length - 2) }
    return $l
  }
  $null
}

function _clh_os_name {
  try { $os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription } catch { $os = $null }
  if (-not $os) { $os = [Environment]::OSVersion.VersionString }
  $os.Trim()
}

function _clh_context {
  $branch = $null
  if (Get-Command git -CommandType Application -ErrorAction Ignore) {
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
  }
  $files = @(Get-ChildItem -Force -Name -ErrorAction Ignore | Select-Object -First 25) -join ', '
  $conda = if ($env:CONDA_DEFAULT_ENV) { $env:CONDA_DEFAULT_ENV } else { 'none' }
  @"
Context:
- OS: $(_clh_os_name), shell: PowerShell $($PSVersionTable.PSVersion)
- Current directory: $((Get-Location).Path)
- Files here: $(if ($files) { $files } else { 'none' })
- Git branch: $(if ($branch) { $branch } else { 'not a git repo' })
- Conda env: $conda
"@
}

# Extra hints for phrasings small models tend to get wrong.
function _clh_hints([string]$q) {
  if ($q -match '(conda|env|environment)' -and $q -notmatch '(venv|virtualenv)' -and
      $q -match '(here|this (folder|dir|directory)|current (folder|dir|directory)|local|-p|prefix)') {
    $tpl = if ($q -match '(activate|use|switch|enter)') { 'conda activate .\.conda' }
           elseif ($q -match '(delete|remove|destroy|uninstall)') { 'conda remove -p .\.conda --all -y' }
           else { 'conda create -p .\.conda python=3.11 -y (change the python version / add packages if asked)' }
    "IMPORTANT: the env lives in the folder .\.conda. Use -p .\.conda, never -n and never just `".`". Answer with: $tpl"
  }
}

# Messages from alternating role / content values.
function _clh_turns([object[]]$pairs) {
  $out = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i + 1 -lt $pairs.Count; $i += 2) {
    $out.Add([ordered]@{ role = [string]$pairs[$i]; content = [string]$pairs[$i + 1] })
  }
  , $out.ToArray()
}

# Alternating request / command values → user / assistant messages.
function _clh_pair_turns([object[]]$pairs) {
  $out = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i + 1 -lt $pairs.Count; $i += 2) {
    $out.Add([ordered]@{ role = 'user'; content = [string]$pairs[$i] })
    $out.Add([ordered]@{ role = 'assistant'; content = [string]$pairs[$i + 1] })
  }
  , $out.ToArray()
}

# POST JSON to Ollama and return the parsed reply. Throws "clh: ..." errors.
function _clh_post([string]$path, $body, [int]$timeout) {
  $json = ConvertTo-Json -InputObject $body -Depth 8 -Compress
  try {
    Invoke-RestMethod -Method Post -Uri ($global:CLH_URL.TrimEnd('/') + $path) -TimeoutSec $timeout `
      -ContentType 'application/json; charset=utf-8' -Body $global:_ClhUtf8.GetBytes($json)
  } catch {
    $msg = $null
    try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
    if ($msg) {
      if ($msg -like '*not found*') { $msg += " — run: ollama pull $($body.model)" }
      throw "clh: $msg"
    }
    throw "clh: cannot reach Ollama at $($global:CLH_URL) — is 'ollama serve' running?"
  }
}

# Send one chat request and return the raw reply text.
function _clh_chat([string]$sys, [double]$temp, [int]$npred, [object[]]$msgs) {
  $body = [ordered]@{
    model = $global:CLH_MODEL; stream = $false; think = $false; keep_alive = '30m'
    options = [ordered]@{ temperature = $temp; num_predict = $npred }
    messages = [object[]](@([ordered]@{ role = 'system'; content = $sys }) + $msgs)
  }
  [string](_clh_post '/api/chat' $body ([int]$global:CLH_TIMEOUT)).message.content
}

# Return a command for a conversation (few-shots are prepended).
#   _clh_complete <temperature> <query> <role, content, ...>
# <query> is the plain request (or command) used to pick similar examples.
function _clh_complete([double]$temp, [string]$query, [object[]]$pairs) {
  $fix = ([string]$pairs[-1]).Contains($global:_CLH_FIX_TAIL)
  $msgs = [object[]]((_clh_select_examples $query $fix) + (_clh_turns $pairs))
  $content = _clh_chat $global:_CLH_SYSTEM $temp 120 $msgs
  $cmd = _clh_sanitize $content
  if (-not $cmd) { throw 'clh: model returned no command' }
  $cmd
}

# --- learned and similar examples -------------------------------------------
# Same algorithm as _CLH_JQ_LIB in clh.zsh. Pool items have r (request),
# c (command), l (learned), t (time), i (position); rankers add s (score).

$global:_ClhStop = @('a','an','the','in','of','to','for','on','with','and','or','me','my',
                     'i','it','is','all','this','that','from','by','please','can','you','how','do','what')

function _clh_toks([string]$s) {
  $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
  foreach ($m in [regex]::Matches($s.ToLowerInvariant(), '[a-z0-9]+')) {
    $w = $m.Value
    if ($global:_ClhStop -ccontains $w) { continue }
    if ($w.Length -gt 3 -and $w.EndsWith('s') -and -not $w.EndsWith('ss')) { $w = $w.Substring(0, $w.Length - 1) }
    [void]$set.Add($w)
  }
  , @($set)
}

function _clh_unix_now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function _clh_private_file([string]$path) {
  if (-not $global:_ClhIsWindows) { try { [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite') } catch { } }
}

function _clh_read_history {
  $f = $global:CLH_HISTORY_FILE
  if (-not (Test-Path -LiteralPath $f)) { return , @() }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($line in [IO.File]::ReadAllLines($f)) {
    if (-not $line.Trim()) { continue }
    try { $o = $line | ConvertFrom-Json; if ($o.r -and $o.c) { $out.Add($o) } } catch { }
  }
  , $out.ToArray()
}

function _clh_write_history([object[]]$items) {
  $lines = foreach ($o in $items) { ConvertTo-Json -InputObject ([ordered]@{ r = [string]$o.r; c = [string]$o.c; t = [long]$o.t }) -Compress }
  [IO.File]::WriteAllText($global:CLH_HISTORY_FILE, ((@($lines) -join "`n") + "`n"), $global:_ClhUtf8)
}

# Sort by string keys, ordinal (code point) order like jq.
function _clh_sort_by([object[]]$items, [scriptblock]$key) {
  if ($items.Count -lt 2) { return , @($items) }
  $keys = [string[]]@(foreach ($o in $items) { & $key $o })
  $arr = [object[]]@($items)
  # The non-generic overload: the generic one would sort a converted copy of $arr.
  [Array]::Sort([Array]$keys, [Array]$arr, [System.Collections.IComparer][StringComparer]::Ordinal)
  , $arr
}

# Newest entry per request (case-insensitive). -ByTime: oldest first, ties
# by request; otherwise by request. (Matches group_by / max_by / sort_by in jq.)
function _clh_latest_per_request([object[]]$items, [switch]$ByTime) {
  $best = @{}
  foreach ($o in $items) {
    $k = ([string]$o.r).ToLowerInvariant()
    if (-not $best.ContainsKey($k) -or [long]$o.t -ge [long]$best[$k].t) { $best[$k] = $o }
  }
  if ($ByTime) { _clh_sort_by @($best.Values) { '{0:D20}|{1}' -f [long]$args[0].t, ([string]$args[0].r).ToLowerInvariant() } }
  else { _clh_sort_by @($best.Values) { ([string]$args[0].r).ToLowerInvariant() } }
}

# Remember a request and the command the user ran for it.
function _clh_learn([string]$req, [string]$cmd) {
  if ($global:CLH_LEARN -ne '1') { return }
  if (-not $req -or -not $cmd -or $cmd.Contains("`n")) { return }
  if ($cmd -match $global:_CLH_DANGER_RE) { return }
  $f = $global:CLH_HISTORY_FILE
  $dir = Split-Path -Parent $f
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $new = -not (Test-Path -LiteralPath $f)
  $line = ConvertTo-Json -InputObject ([ordered]@{ r = $req; c = $cmd; t = (_clh_unix_now) }) -Compress
  [IO.File]::AppendAllText($f, $line + "`n", $global:_ClhUtf8)
  if ($new) { _clh_private_file $f }
  $all = _clh_read_history
  if ($all.Count -gt [int]$global:CLH_HISTORY_MAX) {
    $keep = _clh_latest_per_request $all -ByTime
    $max = [int]$global:CLH_HISTORY_MAX
    if ($keep.Count -gt $max) { $keep = $keep[($keep.Count - $max)..($keep.Count - 1)] }
    _clh_write_history $keep
  }
}

# Learned pairs (newest per request) followed by the built-in examples.
function _clh_pool {
  $pool = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($o in (_clh_latest_per_request (_clh_read_history))) {
    $pool.Add([pscustomobject]@{ r = [string]$o.r; c = [string]$o.c; l = $true; t = [long]$o.t; i = $pool.Count; s = 0.0 })
    $seen[([string]$o.r).ToLowerInvariant()] = $true
  }
  $e = $global:_CLH_EXAMPLES
  for ($j = 0; $j + 1 -lt $e.Count; $j += 2) {
    if ($seen.ContainsKey($e[$j].ToLowerInvariant())) { continue }
    $pool.Add([pscustomobject]@{ r = $e[$j]; c = $e[$j + 1]; l = $false; t = 0; i = $pool.Count; s = 0.0 })
  }
  , $pool.ToArray()
}

function _clh_rank_keyword([string]$q, [object[]]$pool) {
  $n = $pool.Count
  $pt = @(foreach ($p in $pool) { , (_clh_toks $p.r) })
  $qt = _clh_toks $q
  $df = @{}
  foreach ($t in $pt) { foreach ($w in $t) { $df[$w] = 1 + [int]$df[$w] } }
  for ($i = 0; $i -lt $n; $i++) {
    $sum = 0.0
    foreach ($w in $pt[$i]) { if ($qt -ccontains $w) { $sum += [math]::Log(($n + 1) / $df[$w]) } }
    $pool[$i].s = $sum / [math]::Sqrt([math]::Max($pt[$i].Count, 1))
  }
  , $pool
}

# Embed texts with $CLH_EMBED_MODEL; returns an array of vectors.
function _clh_embed([string[]]$texts) {
  $body = [ordered]@{ model = $global:CLH_EMBED_MODEL; input = [object[]]$texts; keep_alive = '30m' }
  $r = _clh_post '/api/embed' $body ([int]$global:CLH_TIMEOUT)
  if (-not $r.embeddings) { throw 'clh: no embeddings returned' }
  , @($r.embeddings)
}

function _clh_cos($a, $b) {
  $dot = 0.0; $na = 0.0; $nb = 0.0
  for ($i = 0; $i -lt $a.Count; $i++) { $dot += $a[$i] * $b[$i]; $na += $a[$i] * $a[$i]; $nb += $b[$i] * $b[$i] }
  $dot / [math]::Sqrt($na * $nb)
}

# Score the pool by cosine similarity. Example vectors are cached next to
# the history file, so usually only the query is embedded.
function _clh_rank_embed([string]$q, [object[]]$pool) {
  $cache = Join-Path (Split-Path -Parent $global:CLH_HISTORY_FILE) 'embed-cache.jsonl'
  $vec = @{}
  if (Test-Path -LiteralPath $cache) {
    foreach ($line in [IO.File]::ReadAllLines($cache)) {
      try { $o = $line | ConvertFrom-Json; if ($o.m -eq $global:CLH_EMBED_MODEL) { $vec[[string]$o.t] = @($o.e) } } catch { }
    }
  }
  $missing = @($pool | ForEach-Object { $_.r } | Where-Object { -not $vec.ContainsKey($_) } | Select-Object -Unique)
  $vs = _clh_embed (@($q) + $missing)
  if ($missing.Count) {
    $dir = Split-Path -Parent $cache
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = for ($i = 0; $i -lt $missing.Count; $i++) {
      $vec[$missing[$i]] = @($vs[$i + 1])
      ConvertTo-Json -InputObject ([ordered]@{ m = $global:CLH_EMBED_MODEL; t = $missing[$i]; e = @($vs[$i + 1]) }) -Compress
    }
    [IO.File]::AppendAllText($cache, ((@($lines) -join "`n") + "`n"), $global:_ClhUtf8)
    _clh_private_file $cache
  }
  foreach ($p in $pool) { $p.s = if ($vec.ContainsKey($p.r)) { _clh_cos $vec[$p.r] $vs[0] } else { 0.0 } }
  , $pool
}

# The $k best matches, closest last; unmatched slots go to the first built-ins.
function _clh_pick([object[]]$items, [int]$k) {
  $top = @($items | Where-Object { $_.s -gt 0 } |
    Sort-Object @{ e = { -$_.s } }, @{ e = { if ($_.l) { 0 } else { 1 } } }, @{ e = { -$_.t } }, @{ e = { $_.i } } |
    Select-Object -First $k)
  $fill = @($items | Where-Object { $_.s -le 0 -and -not $_.l } | Select-Object -First ([math]::Max($k - $top.Count, 0)))
  [array]::Reverse($top)
  , @($fill + $top)
}

function _clh_item_turns([object[]]$items) {
  , (_clh_pair_turns @(foreach ($o in $items) { $o.r; $o.c }))
}

# Few-shot messages for a query. CLH_EXAMPLE_MODE:
#   all      every built-in example plus the 3 closest learned pairs
#   keyword  the CLH_EXAMPLES_K most similar examples by shared words
#   embed    the same by embedding similarity (falls back to keyword)
# Fix examples are added for ::fix (always in "all" mode).
function _clh_select_examples([string]$q, [bool]$fix = $false) {
  $pool = _clh_pool
  $mode = $global:CLH_EXAMPLE_MODE
  $fixes = if ($fix -or ($mode -ne 'keyword' -and $mode -ne 'embed')) { _clh_pair_turns $global:_CLH_FIX_EXAMPLES } else { @() }
  if ($mode -eq 'embed') {
    try { $scored = _clh_rank_embed $q $pool } catch { $scored = _clh_rank_keyword $q $pool }
  } elseif ($mode -eq 'keyword') {
    $scored = _clh_rank_keyword $q $pool
  } else {
    $scored = _clh_rank_keyword $q $pool
    $builtin = @($scored | Where-Object { -not $_.l })
    $learned = @($scored | Where-Object { $_.l })
    return , [object[]]((_clh_item_turns $builtin) + $fixes + (_clh_item_turns (_clh_pick $learned 3)))
  }
  , [object[]]((_clh_item_turns (_clh_pick $scored ([int]$global:CLH_EXAMPLES_K))) + $fixes)
}

# User messages for each kind of request.
function _clh_request_msg([string]$q) {
  "$(_clh_context)`n`nRequest: $q`n$(_clh_hints $q)"
}

function _clh_refine_msg([string]$change) {
  "Revise the command: $change. Output the full revised command only."
}

# <code> is the native exit code (0 if none); <err> the error PowerShell
# reported for the command, if any.
function _clh_fix_msg([string]$cmd, [int]$code = 0, [string]$err = '') {
  $first = ($cmd.Trim() -split '\s+')[0]
  if (-not (Get-Command -Name $first -ErrorAction Ignore)) {
    $why = "This command failed: '$first' is not a known command (probably misspelled)"
  } elseif ($err) {
    $why = "This command failed with the error `"$(($err -split "`r?`n")[0])`""
  } elseif ($code -ne 0) {
    $why = "This command failed with exit code $code (likely wrong flags or arguments)"
  } else {
    $why = 'This command ran but did not do what the user wanted'
  }
  "$(_clh_context)`n`n${why}:`n$cmd`n$($global:_CLH_FIX_TAIL)"
}

# --- Ollama server ----------------------------------------------------------

function _clh_server_up {
  try { Invoke-RestMethod -Uri ($global:CLH_URL.TrimEnd('/') + '/api/version') -TimeoutSec 1 | Out-Null; $true } catch { $false }
}

# Start `ollama serve` detached from this terminal and wait for it to answer.
# Only for a server on this machine.
function _clh_start_server {
  $hostport = ($global:CLH_URL -replace '^[a-z]+://', '') -replace '/.*$', ''
  if ($hostport -notmatch '^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?$') {
    throw "clh: cannot reach Ollama at $($global:CLH_URL) (not local, so not starting it)"
  }
  if (-not (Get-Command ollama -ErrorAction Ignore)) {
    throw $(if ($global:_ClhIsWindows) { 'clh: ollama is not installed (winget install Ollama.Ollama)' }
            else { 'clh: ollama is not installed (https://ollama.com/download)' })
  }
  $old = $env:OLLAMA_HOST
  $env:OLLAMA_HOST = $hostport
  try {
    if ($global:_ClhIsWindows) {
      Start-Process -FilePath ollama -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    } else {
      $log = $global:CLH_OLLAMA_LOG
      New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force | Out-Null
      Start-Process -FilePath sh -ArgumentList '-c', "nohup ollama serve >>'$log' 2>&1 &" | Out-Null
    }
  } finally { $env:OLLAMA_HOST = $old }
  # On first start Ollama can spend ~20s detecting the GPU before answering.
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    if (_clh_server_up) { return }
    Start-Sleep -Milliseconds 500
  }
  throw "clh: started ollama but it did not respond — see $($global:CLH_OLLAMA_LOG)"
}

# Return the generated command for a natural-language query.
function _clh_generate([string]$q) {
  _clh_complete 0 $q @('user', (_clh_request_msg $q))
}

# Return a one-sentence explanation of a command.
function _clh_explain([string]$cmd) {
  $out = _clh_chat $global:_CLH_EXPLAIN_SYSTEM 0 80 (_clh_turns ($global:_CLH_EXPLAIN_EXAMPLES + @('user', $cmd)))
  (($out -replace "`r?`n", ' ').Trim()) -replace '`', ''
}

# Classify the line: @(mode, args...) with mode
#   fix | explain <cmd> | new <request> | refine <cmd> <change> | run | clh <word>
function _clh_parse([string]$line) {
  $b = $line.Trim(); $P = $global:CLH_PREFIX; $e = [regex]::Escape($P)
  $ord = [StringComparison]::Ordinal
  if ($b -ceq "${P}fix") { return , @('fix') }
  if ($b -ceq "${P}help" -or $b -ceq "${P}settings") { return , @('clh', $b.Substring($P.Length)) }
  if ($b.StartsWith("${P}?", $ord)) { return , @('explain', $b.Substring($P.Length + 1).Trim()) }
  if ($b -cmatch "\s$e\?$") { return , @('explain', $b.Substring(0, $b.Length - $P.Length - 1).Trim()) }
  if ($b.StartsWith($P, $ord)) { return , @('new', $b.Substring($P.Length).Trim()) }
  if ($b -cmatch "(?s)^(.*\S)\s+$e\s+(.*)$") { return , @('refine', $Matches[1], $Matches[2]) }
  , @('run')
}

# --- clh command: help and settings -----------------------------------------

function _clh_short([string]$n) { $n.Substring(4).ToLowerInvariant() }

function _clh_tilde([string]$v) {
  if ($v.StartsWith($HOME, [StringComparison]::Ordinal)) { '~' + $v.Substring($HOME.Length) } else { $v }
}

# Look up a setting by name (CLH_MODEL, model, example-mode, ...).
function _clh_setting([string]$name) {
  $want = $name.Replace('-', '_').ToUpperInvariant()
  if (-not $want.StartsWith('CLH_')) { $want = "CLH_$want" }
  foreach ($s in $global:_CLH_SETTINGS) { if ($s[0] -ceq $want) { return , $s } }
  $null
}

# A value normalized for a setting type, or $null if it doesn't fit.
function _clh_check_value([string]$t, [string]$v) {
  switch ($t) {
    'bool' {
      if (@('1','on','true','yes') -contains $v) { return '1' }
      if (@('0','off','false','no') -contains $v) { return '0' }
      return $null
    }
    'int' { if ($v -match '^[1-9][0-9]*$') { return $v }; return $null }
    'str' { if ($v -and -not $v.Contains("`n")) { return $v }; return $null }
    default { if ($v -and -not $v.Contains('|') -and ($t -split '\|') -ccontains $v) { return $v }; return $null }
  }
}

function _clh_type_hint([string]$t) {
  switch ($t) { 'bool' { 'on or off' } 'int' { 'a number' } 'str' { 'text' } default { 'one of: ' + ($t -replace '\|', ', ') } }
}

# Where a setting's current value comes from: profile, saved, default or shell.
function _clh_setting_source([string]$n, [string]$d) {
  if ($global:_CLH_PRESET -ccontains $n) { 'profile' }
  elseif ((_clh_read_config).ContainsKey($n)) { 'saved' }
  elseif ((_clh_get $n) -ceq $d) { 'default' }
  else { 'shell' }
}

# Save a setting in the config file, or drop it when $value is $null.
function _clh_save_setting([string]$n, $value) {
  $cfg = _clh_read_config
  if ($null -eq $value) { $cfg.Remove($n) } else { $cfg[$n] = [string]$value }
  $f = $global:CLH_CONFIG_FILE
  $dir = Split-Path -Parent $f
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $ordered = [ordered]@{}
  foreach ($s in $global:_CLH_SETTINGS) { if ($cfg.ContainsKey($s[0])) { $ordered[$s[0]] = $cfg[$s[0]] } }
  [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $ordered), $global:_ClhUtf8)
  _clh_private_file $f
}

function _clh_installed_models {
  try { @((Invoke-RestMethod -Uri ($global:CLH_URL.TrimEnd('/') + '/api/tags') -TimeoutSec 2).models.name) } catch { @() }
}

# Warn about a model that isn't installed (silent if Ollama is down).
function _clh_check_model([string]$m) {
  $models = _clh_installed_models
  if ($models.Count -and -not ($models -ccontains $m -or $models -ccontains "${m}:latest")) {
    "note: '$m' is not installed; run: ollama pull $m"
  }
}

function _clh_set([string]$name, [string]$value) {
  $s = _clh_setting $name
  if (-not $s) { Write-Error "clh: unknown setting '$name' (see: clh config)" -ErrorAction Continue; return }
  $n = $s[0]; $t = $s[1]
  $v = _clh_check_value $t $value
  if ($null -eq $v) { Write-Error "clh: $(_clh_short $n) must be $(_clh_type_hint $t), not '$value'" -ErrorAction Continue; return }
  _clh_put $n $v
  _clh_save_setting $n $v
  "$(_clh_short $n) = $v (saved)"
  if ($global:_CLH_PRESET -ccontains $n) { "note: $n is also set in your profile (or `$env:$n), which wins in new shells" }
  switch ($n) {
    'CLH_MODEL' { _clh_check_model $global:CLH_MODEL }
    { $_ -in 'CLH_EXAMPLE_MODE', 'CLH_EMBED_MODEL' } { if ($global:CLH_EXAMPLE_MODE -eq 'embed') { _clh_check_model $global:CLH_EMBED_MODEL } }
    'CLH_WARM' { 'takes effect in new shells' }
  }
}

function _clh_reset_setting([string]$name) {
  if ($name -in '--all', 'all') {
    Remove-Item -LiteralPath $global:CLH_CONFIG_FILE -ErrorAction Ignore
    foreach ($s in $global:_CLH_SETTINGS) { if ($global:_CLH_PRESET -cnotcontains $s[0]) { _clh_put $s[0] $s[2] } }
    'all settings are back to their defaults'
    if ($global:_CLH_PRESET.Count) { "still set in your profile: $($global:_CLH_PRESET -join ', ')" }
    return
  }
  $s = _clh_setting $name
  if (-not $s) { Write-Error "clh: unknown setting '$name' (see: clh config)" -ErrorAction Continue; return }
  _clh_save_setting $s[0] $null
  if ($global:_CLH_PRESET -ccontains $s[0]) { "$($s[0]) is set in your profile (or `$env:$($s[0])); that value stays" }
  else { _clh_put $s[0] $s[2]; "$(_clh_short $s[0]) = $($s[2]) (default)" }
}

# List settings with value, source and description. -n numbers them.
function _clh_config([switch]$n) {
  $i = 0
  foreach ($s in $global:_CLH_SETTINGS) {
    $i++
    $num = if ($n) { '{0,2}) ' -f $i } else { '' }
    $pad = if ($n) { '    ' } else { '' }
    '{0}{1,-14} {2}  ({3})' -f $num, (_clh_short $s[0]), (_clh_tilde (_clh_get $s[0])), (_clh_setting_source $s[0] $s[2])
    '{0}{1,-14} {2}' -f $pad, '', $s[3]
  }
}

# Interactive editor: pick a setting by number or name; bools toggle.
function _clh_settings_ui {
  while ($true) {
    ''; _clh_config -n | Write-Host; ''
    $choice = Read-Host 'Setting to change (number or name; r <number> resets; Enter quits)'
    if (-not $choice) { return }
    $reset = $choice.StartsWith('r ')
    if ($reset) { $choice = $choice.Substring(2) }
    $s = $null
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $global:_CLH_SETTINGS.Count) {
      $s = $global:_CLH_SETTINGS[[int]$choice - 1]
    } else { $s = _clh_setting $choice }
    if (-not $s) { Write-Host "no setting '$choice'"; continue }
    $n = $s[0]; $t = $s[1]
    Write-Host ''
    if ($reset) { _clh_reset_setting $n | Write-Host }
    elseif ($t -eq 'bool') { _clh_set $n $(if ((_clh_get $n) -eq '1') { '0' } else { '1' }) | Write-Host }
    else {
      Write-Host "$($s[3]) ($(_clh_type_hint $t))"
      if ($n -in 'CLH_MODEL', 'CLH_EMBED_MODEL') {
        $models = _clh_installed_models
        Write-Host ('installed: ' + $(if ($models.Count) { $models -join ', ' } else { 'unknown (is Ollama running?)' }))
      }
      $v = Read-Host "$(_clh_short $n) [$(_clh_tilde (_clh_get $n))] (Enter keeps it)"
      if ($v -and $v -cne (_clh_get $n)) { _clh_set $n $v | Write-Host }
    }
  }
}

function _clh_history([int]$count = 20) {
  $items = _clh_read_history
  if (-not $items.Count) { return 'nothing learned yet' }
  $items | Select-Object -Last $count | ForEach-Object { "$($_.r)  → $($_.c)" }
}

# Forget every learned pair, or those whose request or command contains text.
function _clh_forget([string]$text) {
  $items = _clh_read_history
  if (-not $items.Count) { return 'nothing learned yet' }
  if (-not $text) {
    $ans = Read-Host "Forget all $($items.Count) learned commands? [y/N]"
    if ($ans -notmatch '^[yY]') { return }
    Remove-Item -LiteralPath $global:CLH_HISTORY_FILE -ErrorAction Ignore
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $global:CLH_HISTORY_FILE) 'embed-cache.jsonl') -ErrorAction Ignore
    return 'forgot everything'
  }
  $needle = $text.ToLowerInvariant()
  $keep = @($items | Where-Object { -not ("$($_.r) $($_.c)".ToLowerInvariant().Contains($needle)) })
  if ($keep.Count) { _clh_write_history $keep } else { Remove-Item -LiteralPath $global:CLH_HISTORY_FILE -ErrorAction Ignore }
  "forgot $($items.Count - $keep.Count) of $($items.Count)"
}

function _clh_help {
  $P = $global:CLH_PREFIX
  "clh — plain English → shell commands  (model: $($global:CLH_MODEL))"
  ''
  'On the command line, then Enter:'
  '  {0,-24} {1}' -f "$P <request>", "generate a command, e.g.  $P find files over 100MB"
  '  {0,-24} {1}' -f "<command> $P <change>", "revise it, e.g.  Get-ChildItem $P only python files"
  '  {0,-24} {1}' -f "<command> ${P}?", "explain without running (or: ${P}? <command>)"
  '  {0,-24} {1}' -f "${P}fix", 'fix the last command you ran'
  '  {0,-24} {1}' -f "${P}help  ${P}settings", 'this page / change settings'
  @"

With a generated command on the line:
  Enter  run it       Tab  clear it       Ctrl+N  another suggestion
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

Settings (saved in $(_clh_tilde $global:CLH_CONFIG_FILE)):
"@
  foreach ($s in $global:_CLH_SETTINGS) { '  {0,-14} {1}' -f (_clh_short $s[0]), (_clh_tilde (_clh_get $s[0])) }
}

function clh {
  $cmd = if ($args.Count) { [string]$args[0] } else { 'help' }
  $rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] })
  switch ($cmd) {
    { $_ -in 'help', '-h', '--help' } { _clh_help }
    'config'   { _clh_config }
    'settings' { _clh_settings_ui }
    'set' {
      if ($rest.Count -lt 2) { Write-Error 'usage: clh set <name> <value>   (names: clh config)' -ErrorAction Continue; return }
      _clh_set $rest[0] ($rest[1..($rest.Count - 1)] -join ' ')
    }
    'reset' {
      if (-not $rest.Count) { Write-Error 'usage: clh reset <name>|--all' -ErrorAction Continue; return }
      _clh_reset_setting $rest[0]
    }
    'history' { if ($rest.Count) { _clh_history ([int]$rest[0]) } else { _clh_history } }
    'forget'  { _clh_forget ($rest -join ' ') }
    default   { Write-Error "clh: unknown command '$cmd' (try: clh help)" -ErrorAction Continue }
  }
}

# For tests/test_sync.zsh: the data that must match the other versions.
function _clh_dump_data {
  ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{
    settings = @(foreach ($s in $global:_CLH_SETTINGS) { [ordered]@{ n = $s[0]; t = $s[1]; d = $s[2] } })
    examples = _clh_pair_turns $global:_CLH_EXAMPLES
    fix_examples = _clh_pair_turns $global:_CLH_FIX_EXAMPLES
  })
}

# --- PSReadLine key handling ------------------------------------------------
#
# Enter is always handled by clh. Tab, Ctrl+N and Ctrl+C are only taken over
# while a generated command is pending, then given back, so completion
# cycling and the user's own bindings keep working.

$global:_CLH_HINT = "↵ run · ⇥ clear · ^N another · ' :: …' refine · ' ::?' explain"

function _clh_rl { [Microsoft.PowerShell.PSConsoleReadLine] }

function _clh_line {
  $line = $null; $cursor = $null
  [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
  $line
}

function _clh_set_line([string]$text) {
  $line = _clh_line
  [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $line.Length, $text)
  [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($text.Length)
}

function _clh_clear_row {
  [Console]::Write("`r" + (' ' * [math]::Max([Console]::BufferWidth - 1, 0)) + "`r")
}

# Transient status, overwritten by the next message.
function _clh_status([string]$text) { _clh_clear_row; [Console]::Write($text) }

# A lasting message where the prompt line was; the prompt is redrawn below.
function _clh_msg([string]$text, $color = $null) {
  _clh_clear_row
  if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
  [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, [Console]::CursorTop)
}

# Run a built-in PSReadLine function by name (the key's original binding).
function _clh_call([string]$fn) {
  if (-not $fn) { return }
  $m = [Microsoft.PowerShell.PSConsoleReadLine].GetMethod($fn, [type[]]@([Nullable[ConsoleKeyInfo]], [object]))
  if ($m) { [void]$m.Invoke($null, @($null, $null)) }
}

# The built-in function bound to a key: a name, '' if unbound, $null if it
# is a custom handler (which clh leaves alone).
function _clh_key_function([string]$chord) {
  $h = Get-PSReadLineKeyHandler -Chord $chord -ErrorAction Ignore | Select-Object -First 1
  if (-not $h) { return '' }
  $fn = [string]$h.Function
  if ([Microsoft.PowerShell.PSConsoleReadLine].GetMethod($fn, [type[]]@([Nullable[ConsoleKeyInfo]], [object]))) { return $fn }
  $null
}

# Take over ($true) or give back ($false) Tab, Ctrl+N and Ctrl+C.
function _clh_grab_keys([bool]$on) {
  foreach ($k in $global:_ClhOrigKeys.Keys) {
    $orig = $global:_ClhOrigKeys[$k]
    if ($null -eq $orig) { continue }
    if ($on) {
      Set-PSReadLineKeyHandler -Chord $k -BriefDescription "clh-$k" -ScriptBlock $global:_ClhKeyBlocks[$k]
    } elseif ($orig) {
      Set-PSReadLineKeyHandler -Chord $k -Function $orig
    } else {
      Remove-PSReadLineKeyHandler -Chord $k
    }
  }
}

function _clh_reset {
  if ($global:_CLH_PENDING) { _clh_grab_keys $false }
  $global:_CLH_PENDING = $false
  $global:_CLH_TURNS = @()
  $global:_CLH_SEEN = @()
  $global:_CLH_REQUEST = ''
}

# Put a generated command on the line and mark it pending.
function _clh_show([string]$cmd) {
  _clh_set_line $cmd
  if (-not $global:_CLH_PENDING) { _clh_grab_keys $true }
  $global:_CLH_PENDING = $true
  if ($cmd -match $global:_CLH_DANGER_RE) {
    _clh_msg "⚠  potentially destructive — review carefully · $($global:_CLH_HINT)" Red
  } else {
    _clh_msg $global:_CLH_HINT Cyan
  }
}

# Make sure Ollama is running, starting it if allowed. Shows progress.
function _clh_ensure_server {
  if (_clh_server_up) { return $true }
  if ($global:CLH_AUTOSTART -ne '1') {
    _clh_msg "clh: cannot reach Ollama at $($global:CLH_URL) — is 'ollama serve' running?"
    return $false
  }
  _clh_status '🚀 starting ollama… (the first start can take ~20s)'
  try { _clh_start_server; $true } catch { _clh_msg "$_"; $false }
}

# Generate from a conversation; on success show the command and keep the
# conversation for refine / Ctrl+N.
function _clh_run([double]$temp, [string]$query, [object[]]$pairs) {
  if (-not (_clh_ensure_server)) { return }
  _clh_status "⏳ thinking ($($global:CLH_MODEL))…"
  try { $cmd = _clh_complete $temp $query $pairs } catch { _clh_msg "$_"; return }
  $global:_CLH_TURNS = @($pairs) + @('assistant', $cmd)
  $global:_CLH_SEEN += $cmd
  _clh_show $cmd
}

# Was the last command a success? Uses the state saved just before it ran.
function _clh_last_ok([string]$cmd) {
  $h = Get-History -Count 1
  if (-not $h -or $h.Id -le $global:_CLH_BEFORE.HistoryId) { return $null }   # never ran
  if ([string]$h.ExecutionStatus -ne 'Completed') { return $false }
  $err = if ($global:Error.Count) { $global:Error[0] } else { $null }
  if (-not [object]::ReferenceEquals($err, $global:_CLH_BEFORE.Error)) { return $false }
  $first = ($cmd.Trim() -split '\s+')[0]
  $c = Get-Command -Name $first -ErrorAction Ignore | Select-Object -First 1
  if ($c -and $c.CommandType -eq 'Application' -and $global:LASTEXITCODE -ne 0) { return $false }
  $true
}

# Learn a stashed request / command pair once its command has finished.
function _clh_check_learn {
  $pair = $global:_CLH_LEARN_PAIR
  if (-not $pair) { return }
  $ok = _clh_last_ok $pair[1]
  if ($null -eq $ok) { return }
  $global:_CLH_LEARN_PAIR = $null
  if ($ok) { _clh_learn $pair[0] $pair[1] }
}

# Remember the state just before a command runs.
function _clh_mark_before {
  $h = Get-History -Count 1
  $global:_CLH_BEFORE = @{
    Error = if ($global:Error.Count) { $global:Error[0] } else { $null }
    HistoryId = if ($h) { $h.Id } else { 0 }
  }
}

# Enter.
function _clh_accept_line {
  _clh_check_learn
  $reply = _clh_parse (_clh_line)
  switch ($reply[0]) {
    'run' {
      # Learn the request with the command as run (edits included) if it succeeds.
      if ($global:_CLH_PENDING -and $global:_CLH_REQUEST) { $global:_CLH_LEARN_PAIR = @($global:_CLH_REQUEST, (_clh_line)) }
      _clh_reset
      _clh_mark_before
      _clh_call $(if ($global:_ClhOrigEnter) { $global:_ClhOrigEnter } else { 'AcceptLine' })
    }
    'new' {
      if (-not $reply[1]) { _clh_msg "usage: $($global:CLH_PREFIX) <describe the command you want>"; return }
      $global:_CLH_SEEN = @()
      $global:_CLH_REQUEST = $reply[1]
      _clh_run 0 $reply[1] @('user', (_clh_request_msg $reply[1]))
    }
    'refine' {
      if ($global:_CLH_PENDING -and $global:_CLH_TURNS.Count) {
        $turns = @($global:_CLH_TURNS[0..($global:_CLH_TURNS.Count - 2)]) + @($reply[1])   # respect manual edits
      } else {
        $global:_CLH_REQUEST = ''
        $turns = @('user', "$(_clh_context)`n`nRequest: run this command", 'assistant', $reply[1])
      }
      $global:_CLH_SEEN = @()
      $q = if ($global:_CLH_REQUEST) { $global:_CLH_REQUEST } else { $reply[1] }
      _clh_run 0 $q ($turns + @('user', (_clh_refine_msg $reply[2])))
    }
    'fix' {
      $h = Get-History -Count 1
      if (-not $h) { _clh_msg 'clh: no previous command to fix'; return }
      $last = $h.CommandLine.Trim()
      $err = ''
      if ($global:Error.Count -and -not [object]::ReferenceEquals($global:Error[0], $global:_CLH_BEFORE.Error)) {
        $err = [string]$global:Error[0]
      }
      $first = ($last -split '\s+')[0]
      $c = Get-Command -Name $first -ErrorAction Ignore | Select-Object -First 1
      $code = if ($c -and $c.CommandType -eq 'Application') { [int]$global:LASTEXITCODE } else { 0 }
      $global:_CLH_SEEN = @($last)
      $global:_CLH_REQUEST = ''
      _clh_run 0 $last @('user', (_clh_fix_msg $last $code $err))
    }
    'clh' {
      _clh_set_line "clh $($reply[1])"
      _clh_reset
      _clh_mark_before
      _clh_call 'AcceptLine'
    }
    'explain' {
      if (-not $reply[1]) { _clh_msg "usage: <command> $($global:CLH_PREFIX)?  or  $($global:CLH_PREFIX)? <command>"; return }
      $cmd = $reply[1]
      _clh_set_line $cmd
      if (-not (_clh_ensure_server)) { return }
      _clh_status '⏳ explaining…'
      try { $out = _clh_explain $cmd } catch { _clh_msg "$_"; return }
      if ($cmd -match $global:_CLH_DANGER_RE) { _clh_msg "⚠  $out" Red } else { _clh_msg "💡 $out" }
    }
  }
}

# Tab while a command is pending: clear it.
function _clh_tab {
  _clh_set_line ''
  _clh_reset
}

# Ctrl+N while a command is pending: another suggestion for its request.
function _clh_next {
  if ($global:_CLH_TURNS.Count -lt 4) { return }
  $turns = @($global:_CLH_TURNS[0..($global:_CLH_TURNS.Count - 3)])
  if (-not (_clh_ensure_server)) { return }
  $cmd = $null
  foreach ($try in 1, 2) {
    $ask = @($turns)
    $ask[-1] = "$($ask[-1])`nGive a different command than: $($global:_CLH_SEEN -join ' | ')"
    _clh_status '⏳ another suggestion…'
    $q = if ($global:_CLH_REQUEST) { $global:_CLH_REQUEST } else { _clh_line }
    try { $cmd = _clh_complete 0.8 $q $ask } catch { _clh_msg "$_"; return }
    if ($global:_CLH_SEEN -cnotcontains $cmd) { break }
  }
  if ($global:_CLH_SEEN -ccontains $cmd) { _clh_msg "no other suggestion · $($global:_CLH_HINT)"; return }
  $global:_CLH_SEEN += $cmd
  $global:_CLH_TURNS = $turns + @('assistant', $cmd)
  _clh_show $cmd
}

# Ctrl+C while a command is pending: drop the state, then cancel as usual.
function _clh_cancel {
  _clh_reset
  _clh_call $(if ($global:_ClhOrigKeys['Ctrl+c']) { $global:_ClhOrigKeys['Ctrl+c'] } else { 'CopyOrCancelLine' })
}

if ((Get-Module PSReadLine) -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
  if (-not $global:_ClhOrigKeys) {
    $global:_ClhOrigKeys = [ordered]@{}
    foreach ($k in 'Tab', 'Ctrl+n', 'Ctrl+c') { $global:_ClhOrigKeys[$k] = _clh_key_function $k }
    $global:_ClhOrigEnter = _clh_key_function 'Enter'
  }
  $global:_ClhKeyBlocks = @{
    'Tab'    = { param($key, $arg) _clh_tab }
    'Ctrl+n' = { param($key, $arg) _clh_next }
    'Ctrl+c' = { param($key, $arg) _clh_cancel }
  }
  Set-PSReadLineKeyHandler -Chord Enter -BriefDescription 'clh-accept-line' `
    -Description 'clh: generate, refine, explain or fix commands; otherwise accept the line' `
    -ScriptBlock { param($key, $arg) _clh_accept_line }

  # Load the model in the background so the first query is fast.
  if ($global:CLH_WARM -eq '1') {
    try {
      Add-Type -AssemblyName System.Net.Http -ErrorAction Ignore
      $global:_ClhWarmClient = New-Object System.Net.Http.HttpClient
      $global:_ClhWarmClient.Timeout = [TimeSpan]::FromSeconds(60)
      $json = ConvertTo-Json -Compress -InputObject @{ model = $global:CLH_MODEL; keep_alive = '30m' }
      $null = $global:_ClhWarmClient.PostAsync($global:CLH_URL.TrimEnd('/') + '/api/generate',
        (New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')))
    } catch { }
  }
}
