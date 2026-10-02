# Install clh for PowerShell: check Ollama, pull the model, and dot-source
# clh.ps1 from your profile.
#   pwsh -ExecutionPolicy Bypass -File install.ps1      (Windows PowerShell: powershell ...)
$ErrorActionPreference = 'Stop'
$model = if ($env:CLH_MODEL) { $env:CLH_MODEL } else { 'qwen2.5-coder:1.5b' }

if (-not (Get-Command ollama -ErrorAction Ignore)) {
  Write-Host 'missing dependency: ollama (winget install Ollama.Ollama, or https://ollama.com/download)'
  exit 1
}
if (-not (Get-Module -ListAvailable PSReadLine)) {
  Write-Host 'warning: PSReadLine is not installed; clh needs it for its keys (Install-Module PSReadLine)'
}

$have = @(ollama list | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })
if ($have -notcontains $model) {
  Write-Host "pulling $model…"
  ollama pull $model
}

$line = ". '$(Join-Path $PSScriptRoot 'clh.ps1')'"
if (-not (Test-Path -LiteralPath $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
if (@(Get-Content -LiteralPath $PROFILE) -contains $line) {
  Write-Host "already in $PROFILE"
} else {
  Add-Content -LiteralPath $PROFILE -Value "`n# command-line-helper (:: <request>)`n$line"
  Write-Host "added to $PROFILE"
}
Write-Host 'done — open a new PowerShell window or run: . $PROFILE'
