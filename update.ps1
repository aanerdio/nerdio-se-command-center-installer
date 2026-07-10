# update.ps1
# Syncs the SE Command Center from the shared SharePoint distribution to this
# machine's local install and restarts the Windows service.
#
# Every SE runs this. Anthony + Marcos publish via .\scripts\publish.ps1.
#
# Usage (elevated PowerShell required — needs to Stop/Start-Service):
#   .\update.ps1              # from your PROD install directory
#   .\update.ps1 -Force        # sync even if versions match
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

$RepoRoot   = $PSScriptRoot
$SharedRoot = Join-Path $env:USERPROFILE `
  'OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center'
$SharedApp  = Join-Path $SharedRoot 'app'
$SharedVer  = Join-Path $SharedApp 'version.json'
$LocalVer   = Join-Path $RepoRoot 'version.json'
$SharedPod  = Join-Path $SharedRoot 'knowledge\domain\pod-assignments.json'
$ServiceName = 'SE Dashboard'

# DEV safety guard: refuse to overwrite the git-tracked DEV workspace.
# Anthony/Marcos use publish.ps1 from DEV → then update.ps1 from PROD.
if ($RepoRoot -like 'C:\Claude\Projects\SE-Command-Center*') {
  Write-Host "REFUSING: update.ps1 was invoked from the DEV workspace at $RepoRoot." -ForegroundColor Red
  Write-Host "  This script is meant to run from the PROD install ($env:LOCALAPPDATA\Programs\SE-Command-Center)." -ForegroundColor DarkGray
  Write-Host "  From DEV, use .\scripts\publish.ps1 to push to shared, then run .\update.ps1 from PROD." -ForegroundColor DarkGray
  exit 10
}

# --- Elevation check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host 'ERROR: run this from an elevated PowerShell (needs Stop/Start-Service).' -ForegroundColor Red
  exit 1
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

# --- Stop service ---
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$svcWasRunning = $false
if ($svc -and $svc.Status -eq 'Running') {
  Write-Host "  Stopping service..." -ForegroundColor DarkGray
  Stop-Service -Name $ServiceName -Force
  $svcWasRunning = $true
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
  if ($svcWasRunning) { Start-Service -Name $ServiceName }
  exit $LASTEXITCODE
}
Copy-Item -Path $SharedVer -Destination $LocalVer -Force

# --- Re-install dependencies if package.json changed ---
$newPkgHash = (Get-FileHash (Join-Path $RepoRoot 'package.json') -Algorithm SHA256).Hash
if ($localPkgHash -ne $newPkgHash) {
  Write-Host "  package.json changed — running npm install..." -ForegroundColor Cyan
  Push-Location $RepoRoot
  try { npm install } finally { Pop-Location }
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
    Set-Content -Path $snapshotPath -Value $snapshotJson -Encoding UTF8 -Force
  } finally { Pop-Location }
}

# --- Restart service ---
if ($svc) {
  Write-Host "  Starting service..." -ForegroundColor Cyan
  Start-Service -Name $ServiceName
  Start-Sleep -Seconds 2
  $svc = Get-Service -Name $ServiceName
  Write-Host "  Service status: $($svc.Status)" -ForegroundColor Green
} else {
  Write-Host "  Service not installed yet. Run .\service\install-service.ps1 to register it." -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Updated to $sharedVersion." -ForegroundColor Green
Write-Host "Dashboard: http://localhost:3131"
