# autopilot launcher for Windows (PowerShell / cmd).
#
# autopilot is a bash tool, so this shim forwards your command to bash — either WSL
# or Git Bash — passing every argument through unchanged (spaces and quotes in a goal
# are preserved via PowerShell's @args splatting).
#
# Prerequisite: install autopilot itself INSIDE that bash environment first —
#   WSL:      curl -fsSL https://raw.githubusercontent.com/tsiresymila1/autopilot/main/install.sh | bash
#   Git Bash: the same command in a Git Bash terminal
#
# Pick the backend with AUTOPILOT_WIN_BASH = wsl | gitbash (default: auto — WSL first).

$ErrorActionPreference = 'Stop'
$prefer = $env:AUTOPILOT_WIN_BASH
$tryWsl = ($prefer -ne 'gitbash')
$tryGit = ($prefer -ne 'wsl')

if ($tryWsl -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  wsl.exe autopilot @args         # output streams straight to your console
  exit $LASTEXITCODE
}

if ($tryGit) {
  $bash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $bash) { $bash = (Get-Command bash.exe -ErrorAction SilentlyContinue).Source }
  if ($bash) {
    # 'autopilot "$@"' runs the bash script; args after $0 become "$@", preserved.
    & $bash -lc 'autopilot "$@"' autopilot @args
    exit $LASTEXITCODE
  }
}

Write-Error "autopilot: needs WSL or Git Bash. Install one, then install autopilot inside it — see https://github.com/tsiresymila1/autopilot#windows"
exit 1
