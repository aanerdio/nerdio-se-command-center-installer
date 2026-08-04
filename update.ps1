# update.ps1
# Syncs the SE Command Center from the shared SharePoint distribution to this
# machine's local install and restarts the Scheduled Task.
#
# Every SE runs this. Anthony + Marcos publish via .\scripts\publish.ps1.
#
# Usage (no admin needed for normal updates):
#   .\update.ps1              # from your PROD install directory
#   .\update.ps1 -Force        # sync even if versions match
#
# One-time exception: if this machine was originally installed as a Windows
# service (pre-cutover NSSM install), the first update after cutover needs to
# run elevated ONCE so the legacy service can be removed and the Scheduled
# Task registered in its place. All subsequent updates run unelevated.
#
# Or re-download the latest updater from GitHub if your local copy is broken:
#   $tmp = "$env:TEMP\update.ps1"
#   Invoke-WebRequest -Uri 'https://github.com/aanerdio/nerdio-se-command-center-installer/releases/latest/download/update.ps1' -OutFile $tmp
#   powershell -ExecutionPolicy Bypass -File $tmp
#
# Safe to re-run. Preserves: data\, logs\, config\pod-roster.json, node_modules\.

param(
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$TaskName = 'SE Dashboard'   # same string used as legacy service name

# Known OneDrive sync path variants — probe in order, first match wins.
$CANDIDATE_SHARED_ROOTS = @(
  (Join-Path $env:USERPROFILE 'OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center'),
  (Join-Path $env:USERPROFILE 'Nerdio\MSP Sales Team - Sales Engineering - Documents\Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center')
)

# Personal root varies by OneDrive folder name — try both.
$PersonalRoot = @(
  (Join-Path $env:USERPROFILE 'OneDrive - Nerdio\SE-Command-Center'),
  (Join-Path $env:USERPROFILE 'Nerdio\SE-Command-Center')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $PersonalRoot) { $PersonalRoot = Join-Path $env:USERPROFILE 'OneDrive - Nerdio\SE-Command-Center' }

$InstallConfig = Join-Path $PersonalRoot 'install-config.json'

# --- Load install-config.json (optional shared_root override) ---
$SharedRoot = $null
$legacyRunMode = $null   # remembered so we can rewrite the config after migration
if (Test-Path $InstallConfig) {
  try {
    $cfg = Get-Content $InstallConfig -Raw | ConvertFrom-Json
    if ($cfg.run_mode) { $legacyRunMode = $cfg.run_mode }
    if ($cfg.shared_root -and (Test-Path (Join-Path $cfg.shared_root 'app'))) {
      $SharedRoot = $cfg.shared_root
    }
  } catch {}
}
# Fall back to candidate probe if no override resolved.
if (-not $SharedRoot) {
  $SharedRoot = $CANDIDATE_SHARED_ROOTS | Where-Object { Test-Path (Join-Path $_ 'app') } | Select-Object -First 1
}

$SharedApp  = Join-Path $SharedRoot 'app'
$SharedVer  = Join-Path $SharedApp 'version.json'
$LocalVer   = Join-Path $RepoRoot 'version.json'
$SharedPod  = Join-Path $SharedRoot 'knowledge\domain\pod-assignments.json'

# DEV safety guard: refuse to overwrite the git-tracked DEV workspace.
# Anthony/Marcos use publish.ps1 from DEV → then update.ps1 from PROD.
if ($RepoRoot -like 'C:\Claude\Projects\SE-Command-Center*') {
  Write-Host "REFUSING: update.ps1 was invoked from the DEV workspace at $RepoRoot." -ForegroundColor Red
  Write-Host "  This script is meant to run from the PROD install ($env:LOCALAPPDATA\Programs\SE-Command-Center)." -ForegroundColor DarkGray
  Write-Host "  From DEV, use .\scripts\publish.ps1 to push to shared, then run .\update.ps1 from PROD." -ForegroundColor DarkGray
  exit 10
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- One-time migration: pre-cutover installs registered SE Dashboard as a
# --- Windows service via NSSM. Detect and remove it, then register the task.
$legacyService = Get-Service -Name $TaskName -ErrorAction SilentlyContinue
if ($legacyService) {
  Write-Host ''
  Write-Host "  Legacy Windows service '$TaskName' detected — migrating to Scheduled Task..." -ForegroundColor Yellow
  if (-not $isAdmin) {
    Write-Host "  ERROR: removing the legacy service requires admin — this ONE update needs elevation." -ForegroundColor Red
    Write-Host "  Right-click PowerShell -> Run as Administrator, cd $RepoRoot, and re-run .\update.ps1." -ForegroundColor DarkGray
    Write-Host "  After the migration, all future updates run unelevated." -ForegroundColor DarkGray
    exit 1
  }
  if ($legacyService.Status -eq 'Running') {
    Write-Host "    Stopping service..." -ForegroundColor DarkGray
    Stop-Service -Name $TaskName -Force
    Start-Sleep -Seconds 2
  }
  # Prefer NSSM (matches how it was registered); fall back to sc.exe delete.
  $nssm = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
  if ($nssm) {
    & $nssm remove $TaskName confirm | Out-Null
  } else {
    & sc.exe delete $TaskName | Out-Null
  }
  Start-Sleep -Seconds 1
  Write-Host "    Legacy service removed." -ForegroundColor Green

  Write-Host "    Registering Scheduled Task..." -ForegroundColor DarkGray
  & (Join-Path $RepoRoot 'service\install-task.ps1')
  Write-Host "  Migration complete — future updates no longer need admin." -ForegroundColor Green
  Write-Host ''
} elseif ($legacyRunMode -eq 'service') {
  # Config still says service but the service is gone (e.g. removed manually).
  # Register the task if it's missing, then let the config rewrite below fix
  # the stale run_mode value.
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $task) {
    Write-Host "  install-config.json says run_mode='service' but no service is installed." -ForegroundColor Yellow
    Write-Host "  Registering Scheduled Task now..." -ForegroundColor DarkGray
    & (Join-Path $RepoRoot 'service\install-task.ps1')
  }
}

# --- Sanity checks ---
if (-not (Test-Path $SharedApp)) {
  Write-Host "FATAL: shared app folder not found: $SharedApp" -ForegroundColor Red
  Write-Host "  Ensure the SE SharePoint site is synced and has an app\ folder published." -ForegroundColor DarkGray
  exit 2
}
if (-not (Test-Path $SharedVer)) {
  Write-Host "FATAL: version.json missing from shared app folder." -ForegroundColor Red
  exit 2
}

# --- Compare versions ---
$sharedVersion = (Get-Content $SharedVer -Raw | ConvertFrom-Json).version
$localVersion  = if (Test-Path $LocalVer) {
  (Get-Content $LocalVer -Raw | ConvertFrom-Json).version
} else { '0.0.0' }

Write-Host "  Local:  $localVersion"
Write-Host "  Shared: $sharedVersion"

if (-not $Force -and $sharedVersion -eq $localVersion) {
  Write-Host "Already up to date." -ForegroundColor Green
  exit 0
}

# --- Track changes we care about ---
$localPkgHash  = if (Test-Path (Join-Path $RepoRoot 'package.json')) {
  (Get-FileHash (Join-Path $RepoRoot 'package.json') -Algorithm SHA256).Hash
} else { '' }
# Read the hash stored inside the snapshot JSON (matches services/pod-refresh.js format:
# { hash, checked_at, source }). If missing or unparseable, treat as changed.
$snapshotPath = Join-Path $RepoRoot 'config\pod-assignments.snapshot.json'
$localPodHash = if (Test-Path $snapshotPath) {
  try { ((Get-Content $snapshotPath -Raw | ConvertFrom-Json).hash).ToLower() } catch { '' }
} else { '' }
$sharedPodHash = if (Test-Path $SharedPod) {
  (Get-FileHash $SharedPod -Algorithm SHA256).Hash.ToLower()
} else { '' }

# --- Stop scheduled task ---
$wasRunning = $false
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq 'Running') {
  Write-Host "  Stopping scheduled task..." -ForegroundColor DarkGray
  Stop-ScheduledTask -TaskName $TaskName
  $wasRunning = $true
  Start-Sleep -Seconds 2
}

# --- Sync from shared ---
Write-Host "Syncing from $SharedApp..." -ForegroundColor Cyan
$rc = robocopy $SharedApp $RepoRoot /MIR `
  /XD node_modules data logs .git .vscode `
  /XF pod-roster.json pod-assignments.snapshot.json version.json `
  /NFL /NDL /NP /R:2 /W:1
if ($LASTEXITCODE -ge 8) {
  Write-Host "FATAL: robocopy failed with exit code $LASTEXITCODE" -ForegroundColor Red
  if ($wasRunning) { Start-ScheduledTask -TaskName $TaskName }
  exit $LASTEXITCODE
}
Copy-Item -Path $SharedVer -Destination $LocalVer -Force

# --- Re-install dependencies if package.json changed ---
$newPkgHash = (Get-FileHash (Join-Path $RepoRoot 'package.json') -Algorithm SHA256).Hash
if ($localPkgHash -ne $newPkgHash) {
  Write-Host "  package.json changed — running npm install..." -ForegroundColor Cyan
  Push-Location $RepoRoot
  try {
    npm install
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  FATAL: npm install failed (exit $LASTEXITCODE)" -ForegroundColor Red
      Pop-Location
      if ($wasRunning) { Start-ScheduledTask -TaskName $TaskName }
      exit 8
    }
  } finally { Pop-Location }
}

# --- Re-run setup.js if pod-assignments changed ---
if ($sharedPodHash -ne $localPodHash) {
  Write-Host "  pod-assignments changed — regenerating pod-roster.json..." -ForegroundColor Cyan
  Push-Location $RepoRoot
  try {
    node scripts\setup.js
    # Write snapshot in the {hash, checked_at, source} format shared with services/pod-refresh.js
    $snapshotJson = @{
      hash       = $sharedPodHash
      checked_at = (Get-Date).ToString('o')
      source     = $SharedPod
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($snapshotPath, $snapshotJson, [System.Text.UTF8Encoding]::new($false))
  } finally { Pop-Location }
}

# --- Restart scheduled task ---
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  Write-Host "  Starting scheduled task..." -ForegroundColor Cyan
  Start-ScheduledTask -TaskName $TaskName
  Start-Sleep -Seconds 2
  $task = Get-ScheduledTask -TaskName $TaskName
  Write-Host "  Task state: $($task.State)" -ForegroundColor Green
} else {
  Write-Host "  Scheduled task not installed. Run .\service\install-task.ps1 to register it." -ForegroundColor Yellow
}

# --- Rewrite install-config.json so run_mode is 'task' post-migration ---
if ($legacyRunMode -ne 'task') {
  try {
    $cfgFinal = [ordered]@{
      shared_root = $SharedRoot
      run_mode    = 'task'
      saved_at    = (Get-Date).ToString('o')
    }
    [System.IO.File]::WriteAllText($InstallConfig, ($cfgFinal | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
  } catch {}
}

Write-Host ''
Write-Host "Updated to $sharedVersion." -ForegroundColor Green
Write-Host "Dashboard: http://localhost:3131"
