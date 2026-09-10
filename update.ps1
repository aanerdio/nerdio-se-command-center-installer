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

# An update is more than the version stamp: robocopy, npm install, the skill
# retire pass, and the task restart all follow it. Interrupt the run after the
# stamp -- Ctrl-C, a reboot, OneDrive yanking a file mid-copy -- and the local
# version already reads as the new one while the install is half-migrated. The
# next run then compared equal versions, printed "Already up to date" and exited
# 0, which is indistinguishable from a healthy install and is how a broken PROD
# went unnoticed from 21 Aug to 4 Sep.
#
# The marker is written BEFORE the stamp and cleared only after the dashboard has
# been observed serving. So its presence means "the last attempt did not finish",
# and that forces a full re-run regardless of what the versions say.
$Marker = Join-Path $RepoRoot '.update-in-progress'
$resuming = Test-Path $Marker
if ($resuming) {
  $mv = ''
  try { $mv = (Get-Content $Marker -Raw | ConvertFrom-Json).target_version } catch {}
  Write-Host "  A previous update did not complete$(if ($mv) { " (target $mv)" }) — re-running it." -ForegroundColor Yellow
}

if (-not $Force -and -not $resuming -and $sharedVersion -eq $localVersion) {
  Write-Host "Already up to date." -ForegroundColor Green
  exit 0
}

# --- Track changes we care about ---
$localPkgHash  = if (Test-Path (Join-Path $RepoRoot 'package.json')) {
  (Get-FileHash (Join-Path $RepoRoot 'package.json') -Algorithm SHA256).Hash
} else { '' }
# The pod-assignments snapshot hash used to live here. It compared the shared
# pod-assignments.json against config\pod-assignments.snapshot.json to decide
# whether to regenerate config\pod-roster.json. Both files are gone: roster.js
# derives the roster in memory from the shared file on every read, memoized on
# mtime, so there is nothing to regenerate and nothing to keep in sync. The
# snapshot's own format comment pointed at services\pod-refresh.js, which was
# deleted in the same change.
#
# The check was also nearly always meaningless: pod-assignments.json reaches
# every SE continuously through OneDrive, not through update.ps1, so by the time
# an update ran the "change" had usually been live for days.

# --- Stop the running dashboard ---
# Stopping the TASK is not the same as stopping the SERVER, and conflating them is
# why PROD could run two-day-old code through repeated "successful" updates.
#
# The task launches service\start-dashboard.ps1 under pwsh, which runs node as a
# child. Stop-ScheduledTask kills pwsh but can leave the node grandchild alive and
# still bound to 3131. The task then reports 'Ready' while the old server keeps
# serving, so:
#   - the next update's `if ($task.State -eq 'Running')` is FALSE and never even
#     tries to stop anything, and
#   - Start-ScheduledTask launches start-dashboard.ps1, which is a singleton: it
#     sees 3131 already in use, logs "refusing to start a duplicate" and exits 0.
# Files update, the task reports success, and the process serving the dashboard is
# never replaced. Observed live on 2026-09-10: node PID from 09-09 still holding
# 3131 after two updates.
#
# So: stop the task unconditionally (its state tells us nothing useful), then kill
# whatever actually owns the port and wait for it to release.
$wasRunning = $false
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  if ($task.State -eq 'Running') { $wasRunning = $true }
  Write-Host "  Stopping scheduled task..." -ForegroundColor DarkGray
  try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}
  Start-Sleep -Seconds 2
}

# Port 3131 only — never 3132. A developer's DEV server is a separate process that
# this script has no business touching.
$portFreed = $true
try {
  $listener = Get-NetTCPConnection -LocalPort 3131 -State Listen -ErrorAction SilentlyContinue
  if ($listener) {
    $wasRunning = $true
    foreach ($procId in ($listener.OwningProcess | Select-Object -Unique)) {
      $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if (-not $p) { continue }
      Write-Host "  Stopping dashboard process $procId ($($p.ProcessName), started $($p.StartTime))..." -ForegroundColor DarkGray
      try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {
        Write-Host "  WARN: could not stop PID $procId — $($_.Exception.Message)" -ForegroundColor Yellow
      }
    }
    # Wait for the socket to actually clear; a bind race here would make the new
    # server exit and hand the port straight back to nothing.
    $portFreed = $false
    $waitUntil = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $waitUntil) {
      if (-not (Get-NetTCPConnection -LocalPort 3131 -State Listen -ErrorAction SilentlyContinue)) { $portFreed = $true; break }
      Start-Sleep -Milliseconds 500
    }
    if (-not $portFreed) {
      Write-Host "  WARN: port 3131 is still held after 15s. The new server will refuse to start." -ForegroundColor Yellow
    }
  }
} catch {}

# --- Mark the update as in flight ---
# Written before the first destructive step. See the $Marker comment above.
try {
  $markerBody = [ordered]@{
    target_version = $sharedVersion
    from_version   = $localVersion
    started_at     = (Get-Date).ToString('o')
    host           = $env:COMPUTERNAME
  } | ConvertTo-Json
  [System.IO.File]::WriteAllText($Marker, $markerBody, [System.Text.UTF8Encoding]::new($false))
} catch {
  Write-Host "  WARN: could not write $Marker — a partial update will not be detected." -ForegroundColor Yellow
}

# --- Sync from shared ---
# .update-in-progress is in /XF for the same reason version.json is: under /MIR,
# a file present in the destination but not the source is DELETED. Excluding it
# blocks the delete as well as the copy, so the marker survives its own sync.
Write-Host "Syncing from $SharedApp..." -ForegroundColor Cyan
$rc = robocopy $SharedApp $RepoRoot /MIR `
  /XD node_modules data logs .git .vscode `
  /XF version.json .update-in-progress `
  /NFL /NDL /NP /R:2 /W:1
if ($LASTEXITCODE -ge 8) {
  Write-Host "FATAL: robocopy failed with exit code $LASTEXITCODE" -ForegroundColor Red
  if ($wasRunning) { Start-ScheduledTask -TaskName $TaskName }
  exit $LASTEXITCODE
}
Copy-Item -Path $SharedVer -Destination $LocalVer -Force

# --- Retire per-user copies of the managed skills ---
# This used to MIRROR every skill from <ProdDir>\skills into ~\.claude\skills.
# It now does the opposite: it removes them.
#
# Skills no longer ship inside app\. publish.ps1 sends them to
# <SHARED_ROOT>\.claude\skills, which is the PROJECT SCOPE a PROD skill run
# already resolves against -- server.js spawns claude.exe with cwd = SHARED_ROOT.
# So all 12 are reachable with no local copy at all, and a local copy is actively
# harmful: two copies resolve under one skill name and which one wins is not
# predictable. That is how the shared folder sat two months stale while the
# current versions lived somewhere else.
#
# ~\.claude\skills stays as the home for an SE's own /slash-command skills. Those
# are personal and this never touches them -- only names that appear in the
# published set are removed.
#
# A junction is the DEV setup (~\.claude\skills\<skill> linked back to the repo)
# and is left alone.
$SkillsSrc = Join-Path $SharedRoot '.claude\skills'
$UserSkillsDst = Join-Path $env:USERPROFILE '.claude\skills'
if ((Test-Path $SkillsSrc) -and (Test-Path $UserSkillsDst)) {
  $retired = 0
  $skipped = 0
  foreach ($name in (Get-ChildItem $SkillsSrc -Directory).Name) {
    $dst = Join-Path $UserSkillsDst $name
    if (-not (Test-Path $dst)) { continue }
    if ((Get-Item $dst -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      Write-Host "  Skipping $name — junction to DEV workspace." -ForegroundColor DarkGray
      $skipped++
      continue
    }
    Remove-Item $dst -Recurse -Force
    $retired++
  }
  if ($retired -gt 0) {
    Write-Host "  Removed $retired duplicate skill copies from ~\.claude\skills — they are served from the shared folder now." -ForegroundColor DarkGray
  }
  if ($skipped -gt 0) {
    Write-Host "  Skills: $skipped skipped (DEV junctions)." -ForegroundColor DarkGray
  }
}

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

# --- Health check: can this machine still derive a roster? ---
# This block used to be "regenerate pod-roster.json if the pod-assignments hash
# changed". There is nothing to regenerate any more, but setup.js is still worth
# running: it calls deriveRoster() and fails loudly on a missing user.json, an
# unsynced SharePoint folder, or an SE with no pod assignment -- each of which
# otherwise surfaces much later as an empty dashboard with no obvious cause.
#
# Run unconditionally rather than on a hash, since the old trigger keyed on a file
# that reaches every SE through OneDrive rather than through update.ps1.
#
# A WARNING here, not a failure. install.ps1 treats the same check as fatal, which
# is right at install time; on an update it usually means OneDrive has not finished
# syncing yet, and blocking an otherwise-good update on that helps nobody.
Write-Host ""
Write-Host "Verifying roster derivation..." -ForegroundColor Cyan
Push-Location $RepoRoot
try {
  node scripts\setup.js
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARN: the roster could not be derived on this machine." -ForegroundColor Yellow
    Write-Host "  The update itself succeeded. Usually this means the shared SharePoint" -ForegroundColor DarkGray
    Write-Host "  folder is still syncing -- re-run 'npm run setup' once it has." -ForegroundColor DarkGray
  }
} finally { Pop-Location }

# --- Restart scheduled task ---
$taskStarted = $false
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  Write-Host "  Starting scheduled task..." -ForegroundColor Cyan
  Start-ScheduledTask -TaskName $TaskName
  Start-Sleep -Seconds 2
  $task = Get-ScheduledTask -TaskName $TaskName
  Write-Host "  Task state: $($task.State)" -ForegroundColor Green
  $taskStarted = $true
} else {
  Write-Host "  Scheduled task not installed. Run .\service\install-task.ps1 to register it." -ForegroundColor Yellow
}

# --- Confirm the dashboard is actually serving the new version ---
# Starting the task proves only that Task Scheduler accepted the request. It does
# not prove node started, that anything bound 3131, or that the code now serving
# is the code we just copied. Without this the script ended on an optimistic
# "Updated to X" whether or not X was running -- so a failed update looked exactly
# like a successful one.
#
# Failure here is a WARNING, not an exit code: the files on disk are correct and
# re-running would not help. But the marker is deliberately LEFT IN PLACE so the
# next run repeats the update rather than short-circuiting on matching versions.
$serving = $null
$healthy = $false
if ($taskStarted) {
  Write-Host ""
  Write-Host "Waiting for the dashboard to answer on 3131..." -ForegroundColor Cyan
  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    try {
      $d = Invoke-RestMethod -Uri 'http://localhost:3131/api/diagnostics' -TimeoutSec 3 -ErrorAction Stop
      $serving = $d.version.version
      $healthy = $true
      break
    } catch {
      # Not listening yet. node takes a few seconds, and on a cold OneDrive the
      # first roster read can take longer.
      Start-Sleep -Seconds 2
    }
  }
}

if ($healthy) {
  if ($serving -eq $sharedVersion) {
    Write-Host "  Serving $serving — confirmed." -ForegroundColor Green
    try { Remove-Item $Marker -Force -ErrorAction Stop } catch {}
  } else {
    # Files updated but the running process reports something else. Usually the
    # old process never exited and is still holding the port.
    Write-Host "  WARN: the dashboard answered but reports version '$serving', not '$sharedVersion'." -ForegroundColor Yellow
    Write-Host "  An older process is probably still holding port 3131. Check with:" -ForegroundColor DarkGray
    Write-Host "    Get-Process node | Select-Object Id,StartTime" -ForegroundColor DarkGray
    Write-Host "  The update will be re-run next time until this resolves." -ForegroundColor DarkGray
  }
} elseif ($taskStarted) {
  Write-Host "  WARN: nothing answered on http://localhost:3131 within 45s." -ForegroundColor Yellow
  Write-Host "  The files were updated, but the dashboard is not serving them." -ForegroundColor DarkGray
  Write-Host "  Check the task and the log:" -ForegroundColor DarkGray
  Write-Host "    Get-ScheduledTask -TaskName '$TaskName' | Select-Object State" -ForegroundColor DarkGray
  Write-Host "    Get-Content '$RepoRoot\logs\server.log' -Tail 30" -ForegroundColor DarkGray
  Write-Host "  The update will be re-run next time until this resolves." -ForegroundColor DarkGray
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

if (-not $taskStarted) {
  # Nothing to health-check against. The file sync is complete and the missing
  # task is reported loudly above, so don't leave the marker to force a pointless
  # re-sync on every future run.
  try { Remove-Item $Marker -Force -ErrorAction Stop } catch {}
}

Write-Host ''
if ($healthy -and $serving -eq $sharedVersion) {
  Write-Host "Updated to $sharedVersion and confirmed serving." -ForegroundColor Green
} elseif ($taskStarted) {
  # Say what is actually true. The old unconditional "Updated to X" was the line
  # that made a dead dashboard read as a successful update.
  Write-Host "Files updated to $sharedVersion, but the dashboard was NOT confirmed serving." -ForegroundColor Yellow
} else {
  Write-Host "Files updated to $sharedVersion. Register the scheduled task to run it." -ForegroundColor Yellow
}
Write-Host "Dashboard: http://localhost:3131"
