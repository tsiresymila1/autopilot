# Install the autopilot Windows launcher (autopilot.cmd + autopilot.ps1) onto your
# user PATH, so you can type `autopilot ...` in cmd or PowerShell. Run from the repo:
#   powershell -ExecutionPolicy Bypass -File win\install.ps1
#
# This installs only the launcher shim. autopilot itself is a bash tool — install it
# inside WSL or Git Bash with the curl one-liner (see the repo README, Windows section).

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dir = Join-Path $env:USERPROFILE '.autopilot-bin'

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $src 'autopilot.cmd') $dir -Force
Copy-Item (Join-Path $src 'autopilot.ps1') $dir -Force
Write-Host "launcher copied to $dir"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $dir) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$dir", 'User')
  Write-Host "added $dir to your user PATH — open a NEW terminal for it to take effect"
} else {
  Write-Host "$dir already on PATH"
}

Write-Host ""
Write-Host "Next: install autopilot inside WSL or Git Bash (it is a bash tool):"
Write-Host "  curl -fsSL https://raw.githubusercontent.com/tsiresymila1/autopilot/main/install.sh | bash"
Write-Host "Then, in a new cmd/PowerShell:  autopilot doctor"
