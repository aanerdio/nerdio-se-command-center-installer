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
#   1. Verifies the shared SharePoint tool folder is synced locally — both the
#      app\ subfolder AND the knowledge\ subfolder (setup.js needs
#      pod-assignments.json). If missing, lets the user open the SP site in a
#      browser to sync it, or point to a custom local path (persisted in
#      install-config.json).
#   2. Installs Node.js LTS via WinGet if missing.
#   3. Installs Claude Code (Anthropic.ClaudeCode) via WinGet if missing.
#   4. If %USERPROFILE%\OneDrive - Nerdio\SE-Command-Center\user.json is missing,
#      prompts the installer for name/email (validated against the shared
#      pod-assignments.json) and writes it.
#   4b. Seeds personal profile stubs (voice-profile.md, background.md) with
#       Nerdio-SE-baseline content — SE fills in personal specifics.
#   4c. Reminds the SE to connect Microsoft 365 integration in claude.ai
#       (non-blocking).
#   5. Creates the per-user PROD install at %LOCALAPPDATA%\Programs\SE-Command-Center\.
#   6. Robocopies the app code from shared\app\ into that folder.
#   7. Runs npm install.
#   8. Runs scripts\setup.js to generate config\pod-roster.json.
#   9. Registers the NSSM Windows service (or Scheduled Task) pointing at
#      the PROD install.
#
# Idempotent — safe to re-run. Won't clobber data\ or an existing user.json.
# Won't overwrite already-populated profile files.

$ErrorActionPreference = 'Stop'

$SP_SITE_URL = 'https://nerdio1013.sharepoint.com/sites/MSPSalesTeam290-SalesEngineering/Shared%20Documents/Forms/AllItems.aspx?id=%2Fsites%2FMSPSalesTeam290%2DSalesEngineering%2FShared%20Documents%2FSales%20Engineering&p=true&ga=1'
# Known OneDrive sync path variants — different Nerdio accounts sync SharePoint
# to different local folder names depending on their OneDrive configuration.
$CANDIDATE_SHARED_ROOTS = @(
  # Standard sync (most SEs): OneDrive - Nerdio
  (Join-Path $env:USERPROFILE 'OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center'),
  # Alternate sync (e.g. Marcos): Nerdio / Documents library
  (Join-Path $env:USERPROFILE 'Nerdio\MSP Sales Team - Sales Engineering - Documents\Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center')
)
$DEFAULT_SHARED_ROOT = $CANDIDATE_SHARED_ROOTS[0]

# Personal root also varies by OneDrive folder name — try both.
$CANDIDATE_PERSONAL_ROOTS = @(
  (Join-Path $env:USERPROFILE 'OneDrive - Nerdio\SE-Command-Center'),
  (Join-Path $env:USERPROFILE 'Nerdio\SE-Command-Center')
)
$PersonalRoot = $CANDIDATE_PERSONAL_ROOTS | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $PersonalRoot) { $PersonalRoot = $CANDIDATE_PERSONAL_ROOTS[0] }

$ProdDir        = Join-Path $env:LOCALAPPDATA 'Programs\SE-Command-Center'
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
# override, otherwise probe the known candidate paths. Returns $null if none
# have an app\ subfolder (caller then runs the sync UX).
function Resolve-SharedRoot {
  # 1. Explicit override in install-config.json wins.
  if (Test-Path $InstallConfig) {
    try {
      $cfg = Get-Content $InstallConfig -Raw | ConvertFrom-Json
      if ($cfg.shared_root -and (Test-Path (Join-Path $cfg.shared_root 'app'))) {
        return $cfg.shared_root
      }
    } catch {}
  }
  # 2. Probe each known OneDrive path variant.
  foreach ($candidate in $CANDIDATE_SHARED_ROOTS) {
    if (Test-Path (Join-Path $candidate 'app')) { return $candidate }
  }
  return $null
}

function Save-SharedRootOverride {
  param([string]$Path)
  if (-not (Test-Path $PersonalRoot)) {
    New-Item -ItemType Directory -Force -Path $PersonalRoot | Out-Null
  }
  $cfg = [ordered]@{ shared_root = $Path; saved_at = (Get-Date).ToString('o') }
  [System.IO.File]::WriteAllText($InstallConfig, ($cfg | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
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
    [string]$FriendlyName,
    [switch]$TryUserScopeFirst
  )
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "  ERROR: winget not found. Install App Installer from the Microsoft Store, then re-run." -ForegroundColor Red
    return $false
  }

  if ($TryUserScopeFirst) {
    Write-Host "  Installing $FriendlyName per-user via WinGet ($PackageId --scope user)..." -ForegroundColor DarkGray
    & winget install --id $PackageId -e --silent --scope user --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0) -or ($LASTEXITCODE -eq -1978335189)
    if ($ok) { Refresh-Path; return $true }
    Write-Host "  Per-user scope failed (exit $LASTEXITCODE) — trying machine-wide install..." -ForegroundColor DarkGray
  }

  Write-Host "  Installing $FriendlyName via WinGet ($PackageId)..." -ForegroundColor DarkGray
  & winget install --id $PackageId -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
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
  # Note: @(... | ConvertFrom-Json) is broken in Windows PowerShell 5.1 — it wraps the
  # whole array as a single element. Parse into a variable first, then wrap with @().
  $podsParsed = Get-Content $PodAssignmentsPath -Raw | ConvertFrom-Json
  $pods = @($podsParsed)

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
  # Use no-BOM UTF-8. PowerShell 5.1's -Encoding UTF8 writes a BOM that breaks
  # Node.js JSON.parse — use .NET directly to guarantee no BOM.
  [System.IO.File]::WriteAllText($UserJsonPath, $userJsonText, [System.Text.UTF8Encoding]::new($false))
  Write-Host ""
  Write-Host "  Wrote $UserJsonPath" -ForegroundColor Green
  Write-Host $userJsonText -ForegroundColor DarkGray
  Write-Host ""
}

Write-Host "=== SE Command Center — first-time install ===" -ForegroundColor Cyan
Write-Host ""

# --- Run mode selection ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
  Write-Host "  Running as Administrator." -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  How should the dashboard run after install?" -ForegroundColor Cyan
  Write-Host "    [1]  Windows Service (recommended) — auto-starts at boot, runs via NSSM"
  Write-Host "    [2]  Scheduled Task (per-user) — starts at your logon, no system-wide service"
  Write-Host ""
  do {
    $modeChoice = (Read-Host "  Choice (1/2, default=1)").Trim()
  } until ($modeChoice -in '', '1', '2')
  $runMode = if ($modeChoice -eq '2') { 'task' } else { 'service' }
  Write-Host ""
} else {
  Write-Host "  No admin privileges detected." -ForegroundColor Yellow
  Write-Host "  Dashboard will be installed as a Scheduled Task (starts at your logon)." -ForegroundColor DarkGray
  Write-Host "  To use a Windows Service instead, re-run this installer as Administrator." -ForegroundColor DarkGray
  Write-Host ""
  $runMode = 'task'
}

# --- [1/9] Shared SharePoint folder ---
Write-Host "[1/9] Locating shared SharePoint folder..." -ForegroundColor Cyan
$SharedRoot = Resolve-SharedRoot
if (-not $SharedRoot) {
  $SharedRoot = Prompt-SharedRoot
}
$SharedApp       = Join-Path $SharedRoot 'app'
$SharedKnowledge = Join-Path $SharedRoot 'knowledge'
$PodAssignments  = Join-Path $SharedRoot 'knowledge\domain\pod-assignments.json'
Write-Host "  Shared root: $SharedRoot" -ForegroundColor Green

# Ensure personal root exists so we can pin it below alongside the shared root.
# (It's also created lazily later by Prompt-CreateUserJson / profile seed, but
# pinning needs the folder to physically exist first.)
if (-not (Test-Path $PersonalRoot)) {
  New-Item -ItemType Directory -Force -Path $PersonalRoot | Out-Null
}

# Files On-Demand safeguard. Both SE roots live in OneDrive; if any content is
# left as cloud-only placeholders, downstream steps (setup.js reading
# pod-assignments.json, robocopy of app\, skills reading the profile) can fail
# with "file not found" even though it "exists" in OneDrive. Pinning both roots
# with `attrib +p` is the programmatic equivalent of right-click ->
# "Always keep on this device". Idempotent — pinning already-pinned files is a
# no-op — so safe to re-run.
Write-Host "  Pinning OneDrive folders (Always keep on this device)..." -ForegroundColor DarkGray
& attrib.exe +p $SharedRoot   /s /d 2>$null | Out-Null
& attrib.exe +p $PersonalRoot /s /d 2>$null | Out-Null

# Even with the pin in place, OneDrive materializes files asynchronously.
# setup.js needs pod-assignments.json specifically — wait up to 60s for it.
if (-not (Test-Path $PodAssignments)) {
  Write-Host "  Waiting for OneDrive to sync knowledge\ subfolder (up to 60s)..." -ForegroundColor Yellow
  $deadline = (Get-Date).AddSeconds(60)
  while (-not (Test-Path $PodAssignments) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }
}
if (-not (Test-Path $PodAssignments)) {
  Write-Host ""
  Write-Host "  ERROR: pod-assignments.json is missing at:" -ForegroundColor Red
  Write-Host "    $PodAssignments" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  The 'app\' folder is synced but 'knowledge\' is not. This is usually" -ForegroundColor Yellow
  Write-Host "  a OneDrive selective-sync issue — the installer pinned the folder to" -ForegroundColor Yellow
  Write-Host "  force download but OneDrive didn't materialize it in time." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  Fix (manual):" -ForegroundColor Cyan
  Write-Host "    1. In the Explorer window that just opened, right-click 'knowledge'" -ForegroundColor DarkGray
  Write-Host "    2. Select 'Always keep on this device'" -ForegroundColor DarkGray
  Write-Host "    3. Wait for the sync (blue circle turns to a green check)" -ForegroundColor DarkGray
  Write-Host "    4. Re-run install.ps1" -ForegroundColor DarkGray
  Write-Host ""
  # Open File Explorer at the shared root so the user can act immediately.
  explorer.exe $SharedRoot
  exit 10
}

# --- [2/9] Node.js (auto-install via WinGet if missing) ---
Write-Host ""
Write-Host "[2/9] Verifying Node.js..." -ForegroundColor Cyan
Refresh-Path
$node = Get-Command node -ErrorAction SilentlyContinue
# Also check common per-user install locations (WinGet --scope user, nvm-windows)
if (-not $node) {
  $candidatePaths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
    (Join-Path $env:APPDATA 'nvm\node.exe'),
    'C:\Program Files\nodejs\node.exe'
  )
  foreach ($p in $candidatePaths) {
    if (Test-Path $p) { $node = Get-Item $p; break }
  }
}
if (-not $node) {
  Write-Host "  Node.js not found — attempting install..." -ForegroundColor Yellow
  $installed = Install-WingetPackage -PackageId 'OpenJS.NodeJS.LTS' -FriendlyName 'Node.js LTS' -TryUserScopeFirst
  if (-not $installed) {
    if (-not $isAdmin) {
      Write-Host "  FATAL: Could not install Node.js without admin." -ForegroundColor Red
      Write-Host "  Options:" -ForegroundColor DarkGray
      Write-Host "    - Ask IT to install Node.js LTS" -ForegroundColor DarkGray
      Write-Host "    - Re-run this installer as Administrator" -ForegroundColor DarkGray
      Write-Host "    - Install manually: winget install OpenJS.NodeJS.LTS --scope user" -ForegroundColor DarkGray
    } else {
      Write-Host "  FATAL: Node.js install failed. Install manually from https://nodejs.org and re-run." -ForegroundColor Red
    }
    exit 4
  }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    # Try per-user location after install
    $perUserNode = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'
    if (Test-Path $perUserNode) { $node = Get-Item $perUserNode }
  }
  if (-not $node) {
    Write-Host "  FATAL: node still not on PATH after install. Open a new PowerShell and re-run." -ForegroundColor Red
    exit 4
  }
}
$nodeVersion = if ($node -is [System.IO.FileInfo]) { & $node.FullName --version } else { & node --version }
Write-Host "  node: $(if ($node -is [System.IO.FileInfo]) { $node.FullName } else { $node.Source }) ($nodeVersion)" -ForegroundColor Green

# --- [3/9] Claude Code (auto-install via WinGet if missing) ---
Write-Host ""
Write-Host "[3/9] Verifying Claude Code..." -ForegroundColor Cyan
Refresh-Path
$claudeBin = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$claudeOnPath = Get-Command claude -ErrorAction SilentlyContinue
if ((-not (Test-Path $claudeBin)) -and (-not $claudeOnPath)) {
  Write-Host "  Claude Code not found — installing Anthropic.ClaudeCode..." -ForegroundColor Yellow
  if (-not (Install-WingetPackage -PackageId 'Anthropic.ClaudeCode' -FriendlyName 'Claude Code' -TryUserScopeFirst)) {
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

# --- [4b/9] Seed personal profile stubs (voice-profile.md, background.md) ---
# SE Command Center skills (se-email-reply, se-post-call-refine-email,
# se-post-call-sf-update) read voice + background from the personal profile
# folder. We seed them with Nerdio-SE-baseline content — the universal
# conventions (email rules, vocabulary, role, audience) are populated so the
# skills have something real to work with even before the SE personalizes,
# while personal specifics (tone, experience, territory, strengths) stay as
# <angle-bracket> prompts.
Write-Host ""
Write-Host "[4b/9] Seeding personal profile stubs..." -ForegroundColor Cyan
$ProfileDir = Join-Path $PersonalRoot 'profile'
if (-not (Test-Path $ProfileDir)) {
  New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
}

$voiceTemplate = @'
# Voice Profile — <Your Name>

The SE Command Center reads this file when drafting emails, SF notes, and
follow-ups on your behalf. Fill it in so those outputs sound like you.

**Below is the Nerdio SE communication baseline pulled from our templates and
guides. Some of it is convention (keep it); some is personal preference
(change freely).**

## Email — universal rules (keep)
- Never open with "Hope this finds you well" or "Hope you're doing well."
- One topic per email. If you have two topics, send two emails.
- Answer first, then context. Don't build up to the point.
- Standalone email (starts a thread): open with the person's first name for
  known contacts (`Libis,`) or `Good morning` / `Good afternoon` for first
  contact. Close with `Thank you,` above your name.
- Mid-thread reply: no opener, no closer. Answer directly. Only add a label
  for an attachment (e.g. `Cost Estimate` on the file line).
- Always CC the PSM on customer-facing follow-ups.

## Email — personal tone
<Direct? Warm? Formal? Two or three sentences. Include what NOT to sound like.>

## Vocabulary
- **Partner** (not customer) when talking to MSPs.
- **PoV** (not POC, not "proof of concept").
- **Session host** (not VM) when talking about AVD hosts.
- **NMM** (not "Nerdio Manager for MSP" in shorthand after first reference).
- **Pod** (not team) for the sales unit.
- Avoid: "leverage", "synergy", "circle back", "reach out" as a verb, "utilize".

## Signature phrases
<Openers and closers you use consistently. Examples: "Following up on...",
"Quick recap from our call —", "Let me know if this misses anything.">

## Formatting habits
- Short paragraphs (2–3 sentences).
- Bullets when comparing options or listing 3+ items.
- No emoji in customer-facing writing.
- Bold sparingly — for the one number or thing you want them to remember.

## On calls
- Answer first, then explain.
- Check in after major sections ("Any questions around X?" before moving on).
- Don't defend a high cost estimate — pull a lever, show the new number.
- If asked about commercials on a call, quote AVD retail ($12/user) and hand
  the pricing conversation to the PSM.

## Boundaries
- If you don't know, say so. No hedging with "I believe" or "I think it might."
- If it's outside our product (their Azure tenant config, their M365 tenant
  policy edge case), say what you can and can't help with directly.

## Examples
<Paste 2–3 short emails you actually sent and are happy with. These anchor your
personal voice better than any description above.>
'@

$backgroundTemplate = @'
# Background — <Your Name>

Context about you, your role, and what you bring to customer conversations.
The SE Command Center reads this file so skills frame technical content in
your emails, SF notes, and briefs the way you'd want them framed.

**Edit anything below to match you. The role/audience sections are Nerdio SE
defaults and should stay mostly true. The personal sections need your input.**

## Role
Sales Engineer at Nerdio, MSP Sales Team. Pre-sales technical owner for the
opportunities in my pod — engaged once an opp is qualified in Salesforce with a
clear technical need. Primary responsibilities:

- AVD Cost Estimates (scoping sessions using the Nerdio Cost Estimator)
- Technical demos (AVD, M365)
- Proof of Value engagements (structured validation)
- Objection handling (Citrix, native Azure, "why Nerdio")
- Clean technical handoff to the Go-Live Engineering (GLE) team at close

I own **technical validation, not commercials.** MSP pricing, discounts, and
licensing volume conversations go to the PSM. The only price I quote directly
is AVD retail: **$12/user/month**.

## Audience
Managed Service Providers (MSPs) — technical evaluators, ops leads, and CTOs.
They care about multi-tenant management, per-tenant margin, and reducing manual
Azure work. They're not end-user IT and they're not Enterprise IT — the tone
should reflect a peer-to-peer technical conversation.

## Primary domain
<AVD / M365 / both — most SEs specialize over time.>

## Experience
<Years in the industry, roles before Nerdio, relevant certifications
(AZ-140, MS-100, etc.), any past MSP-side experience.>

## Territory / pod
<Region (NA-East, NA-West, EMEA, APAC) and pod number. Should match your
entry in pod-assignments.json.>

## Strengths
<Topics where you're the go-to on the pod. Examples: image management at scale,
FSLogix profile design, NMM RBAC modeling, M365 tenant carving, PoV facilitation.
Two or three is plenty.>

## What I defer on
<What you route to someone else instead of answering yourself. Common ones for
new SEs: deep M365 policy edge cases, novel PowerShell, product roadmap
timelines, licensing commercials (always PSM).>
'@

$profileFiles = @(
  @{ Path = (Join-Path $ProfileDir 'voice-profile.md'); Content = $voiceTemplate      },
  @{ Path = (Join-Path $ProfileDir 'background.md');    Content = $backgroundTemplate }
)
$profileSeededAny = $false
foreach ($f in $profileFiles) {
  if (-not (Test-Path $f.Path)) {
    [System.IO.File]::WriteAllText($f.Path, $f.Content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "    Seeded: $(Split-Path $f.Path -Leaf)" -ForegroundColor Green
    $profileSeededAny = $true
  } else {
    Write-Host "    Exists: $(Split-Path $f.Path -Leaf)" -ForegroundColor DarkGray
  }
}
Write-Host "  Personal profile: $ProfileDir" -ForegroundColor Green

# --- [4c/9] Microsoft 365 MCP reminder ---
# The dashboard's calendar, emails, meeting invites, and email drafting all flow
# through the claude.ai-hosted Microsoft 365 integration. It's a one-time browser
# OAuth per SE. Non-blocking — the installer just reminds the SE to do it.
Write-Host ""
Write-Host "[4c/9] Microsoft 365 integration in claude.ai..." -ForegroundColor Cyan
Write-Host "    The dashboard's calendar, emails, and Reply-in-Outlook flow all go through" -ForegroundColor DarkGray
Write-Host "    the M365 integration on claude.ai. If you haven't enabled it yet:" -ForegroundColor DarkGray
Write-Host ""
Write-Host "      1. Open https://claude.ai/settings/integrations" -ForegroundColor Yellow
Write-Host "      2. Find 'Microsoft 365' and click Enable / Connect" -ForegroundColor Yellow
Write-Host "      3. Complete the browser OAuth prompt with your @getnerdio.com account" -ForegroundColor Yellow
Write-Host ""
Write-Host "    Non-blocking — dashboard installs fine either way, but data widgets will" -ForegroundColor DarkGray
Write-Host "    stay empty until this integration is connected." -ForegroundColor DarkGray

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
  npm install --silent
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  FATAL: npm install failed (exit $LASTEXITCODE)" -ForegroundColor Red
    exit 8
  }
} finally { Pop-Location }
Write-Host "  Done." -ForegroundColor Green

# --- [8/9] setup.js ---
Write-Host ""
Write-Host "[8/9] Generating pod-roster.json..." -ForegroundColor Cyan
Push-Location $ProdDir
try {
  node scripts\setup.js
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  FATAL: setup.js failed (see errors above). Fix user.json and re-run install.ps1." -ForegroundColor Red
    exit 9
  }
} finally { Pop-Location }

# --- [9/9] Register service or scheduled task ---
Write-Host ""
if ($runMode -eq 'service') {
  Write-Host "[9/9] Registering Windows service (NSSM)..." -ForegroundColor Cyan
  Push-Location $ProdDir
  try {
    & (Join-Path $ProdDir 'service\install-service.ps1')
  } finally { Pop-Location }
} else {
  Write-Host "[9/9] Registering Scheduled Task (per-user, at logon)..." -ForegroundColor Cyan
  Push-Location $ProdDir
  try {
    & (Join-Path $ProdDir 'service\install-task.ps1')
  } finally { Pop-Location }
}

# --- Persist run_mode to install-config.json ---
$cfgExisting = $null
if (Test-Path $InstallConfig) {
  try { $cfgExisting = Get-Content $InstallConfig -Raw | ConvertFrom-Json } catch {}
}
$savedSharedRoot = if ($cfgExisting -and $cfgExisting.shared_root) { $cfgExisting.shared_root } else { $SharedRoot }
$cfgNew = [ordered]@{
  shared_root = $savedSharedRoot
  run_mode    = $runMode
  saved_at    = (Get-Date).ToString('o')
}
[System.IO.File]::WriteAllText($InstallConfig, ($cfgNew | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host "  PROD install: $ProdDir"
Write-Host "  Dashboard:    http://localhost:3131"
Write-Host "  Run mode:     $runMode"
Write-Host ""

# Profile personalization reminder — call it out prominently because empty or
# default profile files degrade the quality of every skill that reads them.
Write-Host "  One more step — personalize your SE profile:" -ForegroundColor Yellow
Write-Host "    profile\voice-profile.md   — how you write (tone, vocab, formatting)" -ForegroundColor Yellow
Write-Host "    profile\background.md      — who you are (role, experience, focus)" -ForegroundColor Yellow
Write-Host "  Both were seeded with Nerdio-SE defaults. Edit them so emails and SF" -ForegroundColor DarkGray
Write-Host "  notes sound like YOU, not the template." -ForegroundColor DarkGray
Write-Host "  Location: $ProfileDir" -ForegroundColor DarkGray
if ($profileSeededAny) {
  # Open File Explorer on the profile folder so the SE lands on the files to
  # edit. Bare `explorer.exe` (not Start-Process) so the window opens in the
  # user's normal, unelevated shell session even if install.ps1 is elevated.
  explorer.exe $ProfileDir
  Write-Host "  (opened for you in Explorer)" -ForegroundColor DarkGray
}
Write-Host ""

if ($runMode -eq 'task') {
  Write-Host "  The dashboard starts automatically at your next logon."
  Write-Host "  To start it now:  Start-ScheduledTask 'SE Dashboard'"
  Write-Host ""
  Write-Host "For future updates, run:  .\update.ps1  from $ProdDir (no admin needed)."
} else {
  Write-Host "For future updates, run:  .\update.ps1  from $ProdDir (elevated)."
}
