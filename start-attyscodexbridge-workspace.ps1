param(
  [ValidateSet('menu', 'default', 'read-only', 'workspace-write', 'approval', 'full-access')]
  [string]$LaunchProfile = 'menu'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $repoRoot '.telecodex'
$logDir = Join-Path $stateDir 'logs'
$envFile = Join-Path $repoRoot '.env'
$entrypoint = Join-Path $repoRoot 'dist\index.js'
$eventLog = Join-Path $stateDir 'process-events.jsonl'

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-JsonLine {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  Ensure-Directory -Path (Split-Path -Parent $Path)
  ($Value | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $Path -Encoding utf8
}

function Add-PathEntry {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $separator = [System.IO.Path]::PathSeparator
  $entries = @($env:Path -split [regex]::Escape([string]$separator) | Where-Object { $_ })
  if ($entries -notcontains $Path) {
    $env:Path = ($Path, $env:Path) -join $separator
  }
}

function Get-LauncherLaunchProfiles {
  $defaultSandboxMode = if ($env:CODEX_SANDBOX_MODE) { $env:CODEX_SANDBOX_MODE } else { 'workspace-write' }
  $defaultApprovalPolicy = if ($env:CODEX_APPROVAL_POLICY) { $env:CODEX_APPROVAL_POLICY } else { 'never' }

  $profiles = @(
    [pscustomobject]@{
      Id = 'default'
      Label = 'Default from .env'
      SandboxMode = $defaultSandboxMode
      ApprovalPolicy = $defaultApprovalPolicy
      Description = 'Uses CODEX_SANDBOX_MODE and CODEX_APPROVAL_POLICY from .env.'
      Unsafe = ($defaultSandboxMode -eq 'danger-full-access')
    },
    [pscustomobject]@{
      Id = 'read-only'
      Label = 'Read only'
      SandboxMode = 'read-only'
      ApprovalPolicy = 'never'
      Description = 'Codex can inspect, but should not write files.'
      Unsafe = $false
    },
    [pscustomobject]@{
      Id = 'workspace-write'
      Label = 'Workspace write'
      SandboxMode = 'workspace-write'
      ApprovalPolicy = 'never'
      Description = 'Codex can write inside the active workspace without approval prompts.'
      Unsafe = $false
    },
    [pscustomobject]@{
      Id = 'approval'
      Label = 'Workspace write with approval'
      SandboxMode = 'workspace-write'
      ApprovalPolicy = 'on-request'
      Description = 'Codex can work in the workspace and may ask before elevated actions.'
      Unsafe = $false
    },
    [pscustomobject]@{
      Id = 'full-access'
      Label = 'Full access'
      SandboxMode = 'danger-full-access'
      ApprovalPolicy = 'on-request'
      Description = 'Codex can access outside the workspace. Use only when explicitly needed.'
      Unsafe = $true
    }
  )

  return $profiles
}

function Select-LauncherLaunchProfile {
  param(
    [Parameter(Mandatory = $true)]$Profiles,
    [Parameter(Mandatory = $true)][string]$RequestedProfile
  )

  if ($RequestedProfile -ne 'menu') {
    return $Profiles | Where-Object { $_.Id -eq $RequestedProfile } | Select-Object -First 1
  }

  Write-Host ''
  Write-Host 'AttysCodexBridge inditasi jogosultsag:'
  for ($index = 0; $index -lt $Profiles.Count; $index++) {
    $profile = $Profiles[$index]
    $marker = if ($profile.Unsafe) { ' [UNSAFE]' } else { '' }
    Write-Host ("{0}. {1} - {2} / {3}{4}" -f ($index + 1), $profile.Label, $profile.SandboxMode, $profile.ApprovalPolicy, $marker)
    Write-Host ("   {0}" -f $profile.Description)
  }

  $timeoutSeconds = 15
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  Write-Host -NoNewline ("Valasztas [1] ({0}s timeout): " -f $timeoutSeconds)

  while ((Get-Date) -lt $deadline) {
    try {
      if ($Host.UI.RawUI.KeyAvailable) {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host $key.Character

        if ($key.VirtualKeyCode -eq 13 -or [string]::IsNullOrWhiteSpace([string]$key.Character)) {
          return $Profiles[0]
        }

        $choice = 0
        if ([int]::TryParse([string]$key.Character, [ref]$choice) -and $choice -ge 1 -and $choice -le $Profiles.Count) {
          return $Profiles[$choice - 1]
        }

        Write-Host 'Ervenytelen valasztas.'
        Write-Host -NoNewline ("Valasztas [1] ({0}s timeout): " -f $timeoutSeconds)
        $deadline = (Get-Date).AddSeconds($timeoutSeconds)
      }
    } catch {
      Write-Host ''
      Write-Host 'Nem interaktiv inditas, default profil valasztva.'
      return $Profiles[0]
    }

    Start-Sleep -Milliseconds 100
  }

  Write-Host ''
  Write-Host 'Nincs valasztas, default profil indul.'
  return $Profiles[0]
}

function Confirm-UnsafeLaunchProfile {
  param([Parameter(Mandatory = $true)]$Profile)

  if (-not $Profile.Unsafe) {
    return
  }

  Write-Host ''
  Write-Host 'FIGYELEM: a valasztott profil danger-full-access modot allit be.'
  $confirmation = Read-Host 'Ird be pontosan: FULL ACCESS'
  if ($confirmation -ne 'FULL ACCESS') {
    throw 'Full access launch cancelled.'
  }
}

Ensure-Directory -Path $stateDir
Ensure-Directory -Path $logDir

if (-not (Test-Path -LiteralPath $envFile)) {
  Write-JsonLine -Path $eventLog -Value @{
    at = (Get-Date).ToUniversalTime().ToString('o')
    type = 'launcher_failed'
    pid = $PID
    detail = @{ reason = 'missing_env'; path = $envFile }
  }
  throw "Missing .env file: $envFile"
}

if (-not (Test-Path -LiteralPath $entrypoint)) {
  Write-JsonLine -Path $eventLog -Value @{
    at = (Get-Date).ToUniversalTime().ToString('o')
    type = 'launcher_failed'
    pid = $PID
    detail = @{ reason = 'missing_entrypoint'; path = $entrypoint }
  }
  throw "Missing built entrypoint: $entrypoint. Run npm run build first."
}

Get-Content -LiteralPath $envFile | ForEach-Object {
  if ($_ -match '^[A-Z0-9_]+=') {
    $key, $value = $_.Split('=', 2)
    Set-Item -Path ("Env:" + $key) -Value $value
  }
}

$launcherProfiles = @(Get-LauncherLaunchProfiles)
$selectedLauncherProfile = Select-LauncherLaunchProfile -Profiles $launcherProfiles -RequestedProfile $LaunchProfile
if (-not $selectedLauncherProfile) {
  throw "Unknown launch profile: $LaunchProfile"
}

if ($LaunchProfile -eq 'menu') {
  Confirm-UnsafeLaunchProfile -Profile $selectedLauncherProfile
}
$env:CODEX_SANDBOX_MODE = $selectedLauncherProfile.SandboxMode
$env:CODEX_APPROVAL_POLICY = $selectedLauncherProfile.ApprovalPolicy

Write-Host ("Starting AttysCodexBridge with {0}: {1} / {2}" -f $selectedLauncherProfile.Label, $selectedLauncherProfile.SandboxMode, $selectedLauncherProfile.ApprovalPolicy)

Add-PathEntry -Path (Join-Path $repoRoot 'node_modules\.bin')
if ($env:APPDATA) {
  Add-PathEntry -Path (Join-Path $env:APPDATA 'npm')
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutLog = Join-Path $logDir "bot-$stamp.out.log"
$stderrLog = Join-Path $logDir "bot-$stamp.err.log"
$startPath = Join-Path $stateDir 'bot-start.json'

Set-Location $repoRoot
$process = Start-Process -FilePath 'node' `
  -ArgumentList @($entrypoint) `
  -WorkingDirectory $repoRoot `
  -RedirectStandardOutput $stdoutLog `
  -RedirectStandardError $stderrLog `
  -WindowStyle Hidden `
  -PassThru

Set-Content -LiteralPath (Join-Path $stateDir 'bot.pid') -Value $process.Id -Encoding utf8
@{
  schemaVersion = 1
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  launcherPid = $PID
  botPid = $process.Id
  repoRoot = $repoRoot
  entrypoint = $entrypoint
  stdoutLog = $stdoutLog
  stderrLog = $stderrLog
  launchProfile = @{
    id = $selectedLauncherProfile.Id
    label = $selectedLauncherProfile.Label
    sandboxMode = $selectedLauncherProfile.SandboxMode
    approvalPolicy = $selectedLauncherProfile.ApprovalPolicy
    unsafe = $selectedLauncherProfile.Unsafe
  }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $startPath -Encoding utf8

Write-JsonLine -Path $eventLog -Value @{
  at = (Get-Date).ToUniversalTime().ToString('o')
  type = 'launcher_started'
  pid = $PID
  detail = @{
    botPid = $process.Id
    stdoutLog = $stdoutLog
    stderrLog = $stderrLog
    launchProfile = @{
      id = $selectedLauncherProfile.Id
      label = $selectedLauncherProfile.Label
      sandboxMode = $selectedLauncherProfile.SandboxMode
      approvalPolicy = $selectedLauncherProfile.ApprovalPolicy
      unsafe = $selectedLauncherProfile.Unsafe
    }
  }
}

Write-JsonLine -Path $eventLog -Value @{
  at = (Get-Date).ToUniversalTime().ToString('o')
  type = 'launcher_detached'
  pid = $PID
  detail = @{
    botPid = $process.Id
    stdoutLog = $stdoutLog
    stderrLog = $stderrLog
  }
}

exit 0
