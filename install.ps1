# install.ps1 — First-time SE Command Center install for a new SE.
#
# Download this file from the latest GitHub Release and run it from an
# elevated PowerShell:
#
#   $tmp = "$env:TEMP\install.ps1"
#   Invoke-WebRequest -Uri 'https://github.com/aanerdio/nerdio-se-command-center-installer/releases/latest/download/install.ps1' -OutFile $tmp
#   powershell -ExecutionPolicy Bypass -File $tmp
#
# You do NOT need to sync SharePoint first — this script prompts you to
# sync (or point at a custom path) if the shared tool folder is missing.
#
# What it does:
#   1. Verifies the shared SharePoint tool folder is synced locally, or lets
#      the user open the SP site in a browser to sync it, or point to a
#      custom local path (persisted in install-config.json).
#   2. Installs Node.js LTS via WinGet if missing.
#   3. Installs Claude Code (Anthropic.ClaudeCode) via WinGet if missing.
#   4. If %USERPROFILE%\OneDrive - Nerdio\SE-Command-Center\user.json is missing,
#      prompts the installer for name/email (validated against the shared
#      pod-assignments.json) and writes it.
#   5. Creates the per-user PROD install at %LOCALAPPDATA%\Programs\SE-Command-Center\.
#   6. Robocopies the app code from shared\app\ into that folder.
#   7. Runs npm install.
#   8. Runs scripts\setup.js to generate config\pod-roster.json.
#   9. Registers the NSSM Windows service pointing at the PROD install.
#
# Idempotent — safe to re-run. Won't clobber data\ or an existing user.json.

$ErrorActionPreference = 'Stop'

$SP_SITE_URL = 'https://nerdio1013.sharepoint.com/sites/MSPSalesTeam290-SalesEngineering/Shared%20Documents/Forms/AllItems.aspx?id=%2Fsites%2FMSPSalesTeam290%2DSalesEngineering%2FShared%20Documents%2FSales%20Engineering&p=true&ga=1'
$DEFAULT_SHARED_ROOT = Join-Path $env:USERPROFILE `
  'OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center'

$ProdDir        = Join-Path $env:LOCALAPPDATA 'Programs\SE-Command-Center'
$PersonalRoot   = Join-Path $env:USERPROFILE 'OneDrive - Nerdio\SE-Command-Center'
$UserJson       = Join-Path $PersonalRoot 'user.json'
$InstallConfig  = Join-Path $PersonalRoot 'install-config.json'

# Refresh PATH in the current process — winget-installed CLIs write to
# machine/user PATH env vars, but the running shell already snapshotted them.
function Refresh-Path {
  $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = @($machinePath, $userPath) -join ';'
}

# Load $SharedRoot from install-config.json if the user previously set an
# override, otherwise use the default OneDrive path. Returns $null if the
# resolved path doesn't contain \app\ (caller then runs the sync UX).
function Resolve-SharedRoot {
  $root = $DEFAULT_SHARED_ROOT
  if (Test-Path $InstallConfig) {
    try {
      $cfg = Get-Content $InstallConfig -Raw | ConvertFrom-Json
      if ($cfg.shared_root -and (Test-Path $cfg.shared_root)) {
        $root = $cfg.shared_root
      }
    } catch {}
  }
  if (Test-Path (Join-Path $root 'app')) { return $root }
  return $null
}

function Save-SharedRootOverride {
  param([string]$Path)
  if (-not (Test-Path $PersonalRoot)) {
    New-Item -ItemType Directory -Force -Path $PersonalRoot | Out-Null
  }
  $cfg = [ordered]@{ shared_root = $Path; saved_at = (Get-Date).ToString('o') }
  ($cfg | ConvertTo-Json) | Set-Content -Path $InstallConfig -Encoding UTF8
  Write-Host "  Saved override to $InstallConfig" -ForegroundColor DarkGray
}

function Prompt-SharedRoot {
  Write-Host ""
  Write-Host "  Shared SharePoint folder not found at:" -ForegroundColor Yellow
  Write-Host "    $DEFAULT_SHARED_ROOT" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Options:" -ForegroundColor Cyan
  Write-Host "    [1]  Open the SharePoint site in your browser — click 'Sync' in the top ribbon, wait for it to appear in File Explorer, then re-run this installer."
  Write-Host "    [2]  Enter a custom local path (if you've synced the site to a non-default OneDrive location)."
  Write-Host "    [3]  Abort."
  Write-Host ""
  do {
    $choice = (Read-Host "  Choice (1-3)").Trim()
  } until ($choice -in '1','2','3')

  switch ($choice) {
    '1' {
      Write-Host ""
      Write-Host "  Opening SharePoint site..." -ForegroundColor Cyan
      Start-Process $SP_SITE_URL
      Write-Host "  In the SP page: click 'Sync' at the top. When File Explorer shows the folder locally, re-run install.ps1." -ForegroundColor Yellow
      exit 0
    }
    '2' {
      do {
        $custom = (Read-Host "  Full path to your synced se-command-center folder (ends in \se-command-center)").Trim().Trim('"')
        if (-not (Test-Path (Join-Path $custom 'app'))) {
          Write-Host "  '$custom\app\' doesn't exist. Try again." -ForegroundColor Red
          $custom = $null
        }
      } while (-not $custom)
      Save-SharedRootOverride -Path $custom
      return $custom
    }
    '3' { exit 3 }
  }
}

# Idempotent winget install for a package ID. Returns $true on success (or if
# already installed), $false on failure.
function Install-WingetPackage {
  param(
    [string]$PackageId,
    [string]$FriendlyName
  )
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "  ERROR: winget not found. Install App Installer from the Microsoft Store, then re-run." -ForegroundColor Red
    return $false
  }
  Write-Host "  Installing $FriendlyName via WinGet ($PackageId)..." -ForegroundColor DarkGray
  & winget install --id $PackageId -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
  # winget returns 0 on install, 2316632107 (0x8A15002B) if already installed.
  $ok = ($LASTEXITCODE -eq 0) -or ($LASTEXITCODE -eq -1978335189)
  if (-not $ok) {
    Write-Host "  WinGet exited $LASTEXITCODE for $PackageId" -ForegroundColor Yellow
  }
  Refresh-Path
  return $ok
}

function Prompt-CreateUserJson {
  param([string]$UserJsonPath, [string]$PodAssignmentsPath, [string]$PersonalRootPath)

  Write-Host ""
  Write-Host "  user.json missing — let's create it now." -ForegroundColor Yellow
  Write-Host ""

  # Load the SE list from the shared pod-assignments.json.
  if (-not (Test-Path $PodAssignmentsPath)) {
    Write-Host "  FATAL: pod-assignments.json missing at $PodAssignmentsPath" -ForegroundColor Red
    Write-Host "  Cannot identify SEs without it. Ask Anthony or Marcos." -ForegroundColor DarkGray
    exit 6
  }
  $pods = @(Get-Content $PodAssignmentsPath -Raw | ConvertFrom-Json)

  # Pretty-print the numbered menu
  Write-Host "  Which SE is this install for?" -ForegroundColor Cyan
  Write-Host ""
  for ($i = 0; $i -lt $pods.Count; $i++) {
    $p = $pods[$i]
    $roleLabel = if ($p.role -eq 'manager') { 'Manager' } else { "Pod $($p.pod), $($p.region) $($p.product)" }
    $line = "    [{0}]  {1,-20}  <{2,-30}>  {3}" -f ($i + 1), $p.se, $p.email, $roleLabel
    Write-Host $line
  }
  Write-Host ""

  # Prompt for a valid number
  do {
    $raw = (Read-Host "  Enter number (1-$($pods.Count))").Trim()
    $n = 0
    $ok = [int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $pods.Count
    if (-not $ok) { Write-Host "  '$raw' isn't a valid choice. Enter a number between 1 and $($pods.Count)." -ForegroundColor Red }
  } until ($ok)

  $picked = $pods[$n - 1]
  $name    = $picked.se
  $email   = $picked.email
  $sfOwner = $name  # SF owner defaults to canonical SE name; edit user.json later if it differs.

  Write-Host ""
  Write-Host "  Selected:" -ForegroundColor Cyan
  Write-Host "    Name:  $name"
  Write-Host "    Email: $email"
  Write-Host ""
  $confirm = (Read-Host '  Proceed? (Y/n)').Trim().ToLower()
  if ($confirm -eq 'n' -or $confirm -eq 'no') {
    Write-Host "  Aborted. Re-run install.ps1 to try again." -ForegroundColor Yellow
    exit 7
  }

  # Ensure the personal root exists
  if (-not (Test-Path $PersonalRootPath)) {
    New-Item -ItemType Directory -Force -Path $PersonalRootPath | Out-Null
  }

  $userObj = [ordered]@{
    name          = $name
    email         = $email
    sf_owner_name = $sfOwner
  }
  $userJsonText = $userObj | ConvertTo-Json
  Set-Content -Path $UserJsonPath -Value $userJsonText -Encoding UTF8
  Write-Host ""
  Write-Host "  Wrote $UserJsonPath" -ForegroundColor Green
  Write-Host $userJsonText -ForegroundColor DarkGray
  Write-Host ""
}

Write-Host "=== SE Command Center — first-time install ===" -ForegroundColor Cyan
Write-Host ""

# --- Elevation ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "ERROR: run this from an elevated PowerShell (needs to register the Windows service)." -ForegroundColor Red
  Write-Host "  Right-click PowerShell → Run as Administrator, then re-run:" -ForegroundColor DarkGray
  Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor DarkGray
  exit 1
}

# --- [1/9] Shared SharePoint folder ---
Write-Host "[1/9] Locating shared SharePoint folder..." -ForegroundColor Cyan
$SharedRoot = Resolve-SharedRoot
if (-not $SharedRoot) {
  $SharedRoot = Prompt-SharedRoot
}
$SharedApp      = Join-Path $SharedRoot 'app'
$PodAssignments = Join-Path $SharedRoot 'knowledge\domain\pod-assignments.json'
Write-Host "  Shared root: $SharedRoot" -ForegroundColor Green

# --- [2/9] Node.js (auto-install via WinGet if missing) ---
Write-Host ""
Write-Host "[2/9] Verifying Node.js..." -ForegroundColor Cyan
Refresh-Path
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Host "  Node.js not found — installing OpenJS.NodeJS.LTS..." -ForegroundColor Yellow
  if (-not (Install-WingetPackage -PackageId 'OpenJS.NodeJS.LTS' -FriendlyName 'Node.js LTS')) {
    Write-Host "  FATAL: Node.js install failed. Install manually from https://nodejs.org and re-run." -ForegroundColor Red
    exit 4
  }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    Write-Host "  FATAL: node still not on PATH after install. Open a new PowerShell and re-run." -ForegroundColor Red
    exit 4
  }
}
Write-Host "  node: $($node.Source) ($((node --version)))" -ForegroundColor Green

# --- [3/9] Claude Code (auto-install via WinGet if missing) ---
Write-Host ""
Write-Host "[3/9] Verifying Claude Code..." -ForegroundColor Cyan
Refresh-Path
$claudeBin = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$claudeOnPath = Get-Command claude -ErrorAction SilentlyContinue
if ((-not (Test-Path $claudeBin)) -and (-not $claudeOnPath)) {
  Write-Host "  Claude Code not found — installing Anthropic.ClaudeCode..." -ForegroundColor Yellow
  if (-not (Install-WingetPackage -PackageId 'Anthropic.ClaudeCode' -FriendlyName 'Claude Code')) {
    Write-Host "  WARNING: Claude Code install failed. Dashboard will run but AI features stay disabled until installed." -ForegroundColor Yellow
  } else {
    $claudeOnPath = Get-Command claude -ErrorAction SilentlyContinue
  }
}
if (Test-Path $claudeBin) {
  Write-Host "  claude.exe: $claudeBin" -ForegroundColor Green
} elseif ($claudeOnPath) {
  Write-Host "  claude: $($claudeOnPath.Source)" -ForegroundColor Green
} else {
  Write-Host "  WARNING: claude not found. AI features disabled." -ForegroundColor Yellow
}

# --- [4/9] user.json ---
Write-Host ""
Write-Host "[4/9] Verifying user.json..." -ForegroundColor Cyan
if (-not (Test-Path $UserJson)) {
  Prompt-CreateUserJson -UserJsonPath $UserJson -PodAssignmentsPath $PodAssignments -PersonalRootPath $PersonalRoot
} else {
  Write-Host "  user.json: $UserJson (existing)" -ForegroundColor Green
}

# --- [5/9] Create PROD install dir ---
Write-Host ""
Write-Host "[5/9] Creating PROD install dir..." -ForegroundColor Cyan
if (-not (Test-Path $ProdDir)) {
  New-Item -ItemType Directory -Force -Path $ProdDir | Out-Null
  Write-Host "  Created: $ProdDir" -ForegroundColor Green
} else {
  Write-Host "  Exists: $ProdDir" -ForegroundColor DarkGray
}

# --- [6/9] Robocopy from shared\app\ ---
Write-Host ""
Write-Host "[6/9] Copying code from shared\app\..." -ForegroundColor Cyan
robocopy $SharedApp $ProdDir /MIR /XD node_modules data logs .git .vscode /XF pod-roster.json /NFL /NDL /NP /R:2 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) {
  Write-Host "  FATAL: robocopy failed with exit code $LASTEXITCODE" -ForegroundColor Red
  exit 5
}
Write-Host "  Done." -ForegroundColor Green

# --- [7/9] npm install ---
Write-Host ""
Write-Host "[7/9] Running npm install..." -ForegroundColor Cyan
Push-Location $ProdDir
try {
  npm install --silent 2>&1 | Out-Null
} finally { Pop-Location }
Write-Host "  Done." -ForegroundColor Green

# --- [8/9] setup.js ---
Write-Host ""
Write-Host "[8/9] Generating pod-roster.json..." -ForegroundColor Cyan
Push-Location $ProdDir
try {
  node scripts\setup.js
} finally { Pop-Location }

# --- [9/9] Register NSSM service ---
Write-Host ""
Write-Host "[9/9] Registering NSSM Windows service..." -ForegroundColor Cyan
Push-Location $ProdDir
try {
  & (Join-Path $ProdDir 'service\install-service.ps1')
} finally { Pop-Location }

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host "  PROD install: $ProdDir"
Write-Host "  Dashboard:    http://localhost:3131"
Write-Host ""
Write-Host "For future updates, run:  .\update.ps1  from $ProdDir (elevated)."
