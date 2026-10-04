# Installer test for install.ps1, run in the clh-pwsh container (pwsh on Linux)
# with the repo at /clh (read-only). Ollama's install script is replaced by
# fake-ollama-install.sh. Prints ok / not ok lines; exits 1 on any failure.
$ErrorActionPreference = 'Stop'
$model = 'qwen2.5-coder:1.5b'
# tests/run.sh points CLH_URL at the host's Ollama; this test needs a local (fake) one.
Remove-Item Env:CLH_URL, Env:CLH_MODEL -ErrorAction Ignore
$begin = '# >>> command-line-helper >>>'
$env:FAKE_OLLAMA_STATE = Join-Path $HOME '.fake-ollama'
$env:CLH_OLLAMA_SCRIPT = 'file:///clh/tests/install/fake-ollama-install.sh'
$calls = Join-Path $env:FAKE_OLLAMA_STATE 'calls'
$prof = $PROFILE.CurrentUserCurrentHost
$script:fail = 0
function check([string]$d, [scriptblock]$b) {
  $r = try { & $b } catch { $false }
  if ($r) { "ok - $d" } else { "not ok - $d"; $script:fail = 1 }
}
function blocks { if (Test-Path $prof) { @(Get-Content $prof | Where-Object { $_ -eq $begin }).Count } else { 0 } }
# run NAME COMMAND: run pwsh with COMMAND, show its output on failure.
function run([string]$d, [string]$cmd) {
  $out = pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) { "ok - $d" } else { "not ok - $d (exit $LASTEXITCODE)"; $out -split "`n" | ForEach-Object { "  # $_" }; $script:fail = 1 }
}
# Does a new interactive-style session (profile loaded) have clh?
function loads { (pwsh -NonInteractive -Command 'if (Get-Command _clh_accept_line -ErrorAction Ignore) { "yes" }' 2>$null) -contains 'yes' }

"# pwsh $($PSVersionTable.PSVersion), profile $prof"
run 'install from checkout' '& /clh/install.ps1 -Yes'
check 'ollama installed' { [bool](Get-Command ollama -ErrorAction Ignore) }
check 'ollama serve started' { (Get-Content $calls) -contains 'serve' }
check 'model pulled' { (Get-Content $calls) -contains "pull $model" }
check 'one clh block in the profile' { (blocks) -eq 1 }
check 'block dot-sources the checkout' { (Get-Content $prof) -contains ". '/clh/clh.ps1'" }
check 'clh loads in a new session' { loads }

run 'second run' '& /clh/install.ps1 -Yes'
check 'still one clh block' { (blocks) -eq 1 }
check 'model not pulled again' { @(Get-Content $calls | Where-Object { $_ -like 'pull *' }).Count -eq 1 }

New-Item -ItemType Directory -Path (Split-Path -Parent $prof) -Force | Out-Null
Set-Content $prof @('$KEEP = 1', '', '# command-line-helper (:: <request>)', ". '/old/place/clh.ps1'", 'Set-Alias ll Get-ChildItem')
run 'migrate old-style hook' '& /clh/install.ps1 -Yes'
check 'old line removed' { -not (Select-String -LiteralPath $prof -Pattern '/old/place' -Quiet) }
check 'user lines kept' { $c = Get-Content $prof; ($c -contains '$KEEP = 1') -and ($c -contains 'Set-Alias ll Get-ChildItem') }
check 'one clh block after migration' { (blocks) -eq 1 }

# Windows PowerShell 5.1's irm decodes the download as Latin-1, so the script
# must survive that: no BOM and nothing outside ASCII. The iex tests below read
# it the same way.
$bytes = [IO.File]::ReadAllBytes('/clh/install.ps1')
check 'install.ps1 is ASCII without a BOM' { -not ($bytes | Where-Object { $_ -gt 127 }) }
$latin1 = '[Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes(''/clh/install.ps1''))'

# irm | iex: no checkout next to the script, so the repo zip is downloaded.
$pkg = Join-Path ([IO.Path]::GetTempPath()) 'clh-pkg'
New-Item -ItemType Directory -Path "$pkg/command-line-helper-main" -Force | Out-Null
Copy-Item /clh/clh.ps1, /clh/install.ps1, /clh/install.sh "$pkg/command-line-helper-main/"
Compress-Archive -Path "$pkg/command-line-helper-main" -DestinationPath "$pkg/src.zip" -Force
$src = Join-Path $HOME '.local/share/clh/src'
run 'install via iex' "`$env:CLH_SRC_URL = 'file://$pkg/src.zip'; $latin1 | Invoke-Expression; if (`$ErrorActionPreference -ne 'Continue') { throw 'leaked ErrorActionPreference' }"
check "repo downloaded to $src" { Test-Path "$src/clh.ps1" }
check 'block dot-sources the download' { (Get-Content $prof) -contains ". '$src/clh.ps1'" }
check 'one clh block after iex install' { (blocks) -eq 1 }
check 'clh loads from the download' { loads }

run 'uninstall via scriptblock' "& ([scriptblock]::Create(($latin1))) -Uninstall"
check 'uninstall removes the block' { (blocks) -eq 0 }
check 'uninstall removes the download' { -not (Test-Path $src) }
check 'uninstall keeps user lines' { (Get-Content $prof) -contains '$KEEP = 1' }

# A model saved with `clh set model` is the one pulled, unless -Model says otherwise.
New-Item -ItemType Directory -Path (Join-Path $HOME '.config/clh') -Force | Out-Null
Set-Content (Join-Path $HOME '.config/clh/config.json') '{ "CLH_MODEL": "saved model:2b " }'
run 'install with a saved model' '& /clh/install.ps1 -Yes'
check 'saved model pulled' { (Get-Content $calls) -contains 'pull saved model:2b' }
run 'install with -Model' '& /clh/install.ps1 -Yes -Model other:1b'
check '-Model wins over the saved model' { (Get-Content $calls) -contains 'pull other:1b' }
exit $script:fail
