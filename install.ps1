# Install clh for PowerShell: installs Ollama if it is missing (winget, scoop,
# choco or Ollama's setup on Windows), pulls the model and dot-sources clh.ps1
# from your profile.
#
#   pwsh -ExecutionPolicy Bypass -File install.ps1        from a checkout
#   irm https://raw.githubusercontent.com/himanshusingh335/command-line-helper/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm <same url>))) -Uninstall    with options
#
# Options: -Model NAME, -NoModel, -Yes (don't ask), -Uninstall (remove the
# profile hook; leaves Ollama, the model and history).
# Environment: CLH_MODEL, CLH_URL (a remote Ollama: nothing is installed for it).
# For tests: CLH_SRC_URL (repo zip); install.sh's variables are passed on to it.
#
# Keep this file ASCII without a BOM. Windows PowerShell 5.1's `irm` decodes it
# as Latin-1, which turns a BOM into "i>>?" glued to the first "#", and the whole
# script fails to parse. (clh.ps1 is different: it is read from disk and needs
# its BOM.)
param([string]$Model, [switch]$NoModel, [switch]$Yes, [switch]$Uninstall)

# Everything runs in a child scope: with `irm | iex` the script runs in the
# user's session, which must not pick up our variables or ErrorActionPreference.
# Errors are thrown, never `exit`, which would close that session.
& {
  param([string]$Model, [bool]$NoModel, [bool]$Yes, [bool]$Uninstall)
  $ErrorActionPreference = 'Stop'
  $repo = 'himanshusingh335/command-line-helper'
  # -Model, else CLH_MODEL, else the model saved with `clh set model`, else the default.
  $modelNote = ''
  if (-not $Model) { $Model = $env:CLH_MODEL }
  if (-not $Model) {
    $cfg = if ($env:CLH_CONFIG_FILE) { $env:CLH_CONFIG_FILE }
           elseif (($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows) { Join-Path $env:APPDATA 'clh\config.json' }
           else { Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'clh/config.json' }
    try { $Model = "$(([IO.File]::ReadAllText($cfg) | ConvertFrom-Json).CLH_MODEL)".Trim() } catch { }
    if ($Model) { $modelNote = ' (saved with clh set)' }
  }
  if (-not $Model) { $Model = 'qwen2.5-coder:1.5b' }
  $url = if ($env:CLH_URL) { $env:CLH_URL } else { 'http://localhost:11434' }
  $srcUrl = if ($env:CLH_SRC_URL) { $env:CLH_SRC_URL } else { "https://github.com/$repo/archive/refs/heads/main.zip" }
  $isWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
  $data = if ($isWin) { Join-Path $env:LOCALAPPDATA 'clh' }
          elseif ($env:XDG_DATA_HOME) { Join-Path $env:XDG_DATA_HOME 'clh' }
          else { Join-Path $HOME '.local/share/clh' }
  $begin = '# >>> command-line-helper >>>'
  $end = '# <<< command-line-helper <<<'

  function step([string]$m) { Write-Host '==> ' -ForegroundColor Cyan -NoNewline; Write-Host $m }
  function warn([string]$m) { Write-Host "warning: $m" -ForegroundColor Yellow }
  function have([string]$c) { [bool](Get-Command $c -ErrorAction Ignore) }

  # Profiles to hook: this edition's, plus the other edition's on Windows when
  # it is installed (Windows PowerShell 5.1 and PowerShell 7 have separate ones).
  function profiles {
    $p = @($PROFILE.CurrentUserCurrentHost)
    if ($isWin) {
      $dir = Split-Path -Parent $p[0]; $docs = Split-Path -Parent $dir; $name = Split-Path -Leaf $p[0]
      if ((Split-Path -Leaf $dir) -eq 'WindowsPowerShell') { if (have pwsh) { $p += Join-Path (Join-Path $docs 'PowerShell') $name } }
      elseif (have powershell) { $p += Join-Path (Join-Path $docs 'WindowsPowerShell') $name }
    }
    , $p
  }

  # Replace the clh block in a profile with $lines (none: remove it). Also drops
  # what older installers added: the comment line and ". '...clh.ps1'".
  function set_hook([string]$file, [string[]]$lines) {
    if (-not (Test-Path -LiteralPath $file)) {
      if (-not $lines) { return }
      New-Item -ItemType File -Path $file -Force | Out-Null
    }
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false; $blank = 0
    foreach ($l in @(Get-Content -LiteralPath $file)) {
      if ($skip) { if ($l -eq $end) { $skip = $false }; continue }
      if ($l -eq $begin) { $skip = $true; $blank = 0; continue }
      if ($l -eq '# command-line-helper (:: <request>)') { $blank = 0; continue }
      if ($l -match "^\. '.*clh\.ps1'$") { continue }
      if ($l -eq '') { $blank++; continue }
      while ($blank) { $out.Add(''); $blank-- }
      $out.Add($l)
    }
    while ($blank) { $out.Add(''); $blank-- }
    if ($lines) {
      if ($out.Count) { $out.Add('') }
      $out.Add($begin); foreach ($l in $lines) { $out.Add($l) }; $out.Add($end)
    }
    # UTF-8 with BOM, which Windows PowerShell 5.1 reads correctly.
    [IO.File]::WriteAllLines($file, $out.ToArray(), (New-Object System.Text.UTF8Encoding $true))
  }

  if ($Uninstall) {
    foreach ($p in (profiles)) {
      if ((Test-Path -LiteralPath $p) -and (Select-String -LiteralPath $p -Pattern 'clh\.ps1' -Quiet)) {
        set_hook $p @(); step "removed clh from $p"
      }
    }
    $src = Join-Path $data 'src'
    if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Recurse -Force; step "removed $src" }
    Write-Host "done. Ollama, its models and your learned commands ($data) were left in place."
    return
  }

  # ---- what is needed --------------------------------------------------------

  $hostport = ($url -replace '^[a-z]+://', '') -replace '/.*$', ''
  $localOllama = $hostport -match '^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?$'

  $here = if ($PSScriptRoot) { $PSScriptRoot } else { '' }
  $remote = -not ($here -and (Test-Path -LiteralPath (Join-Path $here 'clh.ps1')))
  $src = if ($remote) { Join-Path $data 'src' } else { $here }

  $ollamaHow = $null
  if ($localOllama -and -not (have ollama)) {
    $ollamaHow = if (-not $isWin) { 'install.sh' }
                 elseif (have winget) { 'winget' } elseif (have scoop) { 'scoop' }
                 elseif (have choco) { 'choco' } else { 'setup' }
  }
  # The policy a normal session gets (not this one's, which -ExecutionPolicy
  # Bypass may have changed). Undefined everywhere means Restricted on Windows.
  $policy = 'Unrestricted'
  if ($isWin) {
    $policy = 'Undefined'
    foreach ($s in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
      $v = "$(Get-ExecutionPolicy -Scope $s)"
      if ($v -ne 'Undefined') { $policy = $v; break }
    }
  }
  $fixPolicy = $policy -in @('Restricted', 'AllSigned', 'Undefined')
  $needReadLine = -not (Get-Module -ListAvailable PSReadLine)
  $profileList = profiles

  step "clh installer - PowerShell $($PSVersionTable.PSVersion) on $(if ($isWin) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' })"
  if ($ollamaHow) { Write-Host "  install Ollama ($ollamaHow)" }
  if ($needReadLine) { Write-Host '  install the PSReadLine module' }
  if ($fixPolicy) { Write-Host "  set execution policy to RemoteSigned for your user (now $policy), so your profile can load" }
  if ($remote) { Write-Host "  download clh to $src" }
  if (-not $NoModel) { Write-Host "  pull model $Model$modelNote" }
  foreach ($p in $profileList) { Write-Host "  add clh to $p" }
  if (-not $Yes -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $a = Read-Host 'Continue? [Y/n]'
    if ($a -and $a -notmatch '^[Yy]') { Write-Host 'cancelled'; return }
  }

  # ---- install ---------------------------------------------------------------

  if ($fixPolicy) {
    try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; step 'execution policy set to RemoteSigned' }
    catch { warn "couldn't change the execution policy ($($_.Exception.Message)); your profile may not load" }
  }
  if ($needReadLine) {
    step 'installing PSReadLine'
    try { Install-Module PSReadLine -Scope CurrentUser -Force -SkipPublisherCheck }
    catch { warn "PSReadLine install failed: $($_.Exception.Message)" }
  }

  if ($remote) {
    step "downloading clh to $src"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("clh-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'src.zip'
    if ($srcUrl -like 'file://*') { Copy-Item -LiteralPath ([Uri]$srcUrl).LocalPath $zip }
    else {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
      Invoke-WebRequest -UseBasicParsing $srcUrl -OutFile $zip
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp
    $top = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    if (-not $top -or -not (Test-Path (Join-Path $top.FullName 'clh.ps1'))) { throw "no clh.ps1 in $srcUrl" }
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Recurse -Force }
    Move-Item -LiteralPath $top.FullName $src
    Remove-Item -LiteralPath $tmp -Recurse -Force
    # Downloaded files are marked as from the internet; RemoteSigned would refuse them.
    if ($isWin) { Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File }
  }

  if ($ollamaHow) {
    step "installing Ollama ($ollamaHow)"
    switch ($ollamaHow) {
      'winget' { winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements }
      'scoop' { scoop install ollama }
      'choco' { choco install ollama -y }
      # install.sh knows the package managers and what Ollama's script needs.
      'install.sh' { sh (Join-Path $src 'install.sh') --ollama-only --yes }
      'setup' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $exe = Join-Path ([IO.Path]::GetTempPath()) 'OllamaSetup.exe'
        Invoke-WebRequest -UseBasicParsing 'https://ollama.com/download/OllamaSetup.exe' -OutFile $exe
        Start-Process -FilePath $exe -ArgumentList '/VERYSILENT', '/NORESTART' -Wait
      }
    }
    if ($isWin) {
      # Pick up the new PATH without opening a new window.
      $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
      $dir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
      if ((Test-Path $dir) -and ($env:Path -notlike "*$dir*")) { $env:Path += ";$dir" }
    }
    if (-not (have ollama)) { throw 'Ollama install failed; get it from https://ollama.com/download and re-run' }
  }

  # ---- model -----------------------------------------------------------------

  function ollama_list {
    $old = $env:OLLAMA_HOST; $env:OLLAMA_HOST = $hostport
    try { $o = @(ollama list 2>$null); if ($LASTEXITCODE -eq 0) { , $o } else { $null } }
    finally { $env:OLLAMA_HOST = $old }
  }
  if (-not $NoModel) {
    if (-not $localOllama) {
      try {
        $tags = Invoke-RestMethod -Uri "$($url.TrimEnd('/'))/api/tags" -TimeoutSec 5
        if (@($tags.models.name) -notcontains $Model) {
          step "pulling $Model on $url"
          Invoke-RestMethod -Uri "$($url.TrimEnd('/'))/api/pull" -Method Post -Body (@{ model = $Model; stream = $false } | ConvertTo-Json) | Out-Null
        }
      } catch { warn "couldn't pull $Model on ${url}: $($_.Exception.Message)" }
    } else {
      $list = ollama_list
      if ($null -eq $list) {
        $log = Join-Path $HOME '.ollama/clh-serve.log'
        step "starting ollama serve (log: $log)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force | Out-Null
        $old = $env:OLLAMA_HOST; $env:OLLAMA_HOST = $hostport
        try {
          if ($isWin) { Start-Process -FilePath ollama -ArgumentList 'serve' -WindowStyle Hidden | Out-Null }
          # A direct call: Start-Process joins -ArgumentList unquoted, so sh would get just "nohup".
          else { sh -c "nohup ollama serve >>'$log' 2>&1 </dev/null &" }
        } finally { $env:OLLAMA_HOST = $old }
        $deadline = (Get-Date).AddSeconds(60)
        while ($null -eq $list -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500; $list = ollama_list }
        if ($null -eq $list) { warn "ollama serve didn't come up; see $log" }
      }
      if ($null -ne $list) {
        $names = @($list | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })
        if ($names -contains $Model -or $names -contains "${Model}:latest") { step "model $Model is already installed" }
        else {
          step "pulling $Model"
          $old = $env:OLLAMA_HOST; $env:OLLAMA_HOST = $hostport
          try { ollama pull $Model } finally { $env:OLLAMA_HOST = $old }
          if ($LASTEXITCODE -ne 0) { warn "pull failed; later run: ollama pull $Model" }
        }
      }
    }
  }

  # ---- hook into the profile ---------------------------------------------------

  $line = ". '$((Join-Path $src 'clh.ps1') -replace "'", "''")'"
  foreach ($p in $profileList) { set_hook $p @($line); step "added clh to $p" }
  Write-Host ''
  step 'done. Open a new PowerShell window, or run: . $PROFILE'
  Write-Host 'then try:  :: list files changed in the last day'
  Write-Host 'If your profile sets PSReadLine''s edit mode, keep the clh block after that line.'
} $Model $NoModel.IsPresent $Yes.IsPresent $Uninstall.IsPresent
