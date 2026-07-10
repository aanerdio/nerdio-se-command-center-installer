# Nerdio SE Command Center

Pod-wide Sales Engineering command center for the Nerdio MSP SE team. Runs locally as a Windows service on every SE's laptop. Pulls pipeline data from Salesforce CSV reports (curated by the pod leads) and layers on live calendar, email, and post-call context.

- **Dashboard:** `http://localhost:3131`
- **Docs:** [OVERVIEW.md](OVERVIEW.md) — features & workflow · [QUICK-REFERENCE.md](QUICK-REFERENCE.md) — one-page cheat sheet · [ARCHITECTURE.md](ARCHITECTURE.md) — technical reference
- **Source repo (DEV):** [aanerdio/se-command-center](https://github.com/aanerdio/se-command-center) — where features are built
- **Releases:** [Releases page](https://github.com/aanerdio/nerdio-se-command-center/releases) — each release has a source zip

---

## What it does

Six-tab dashboard that unifies your SE workday:

- **Home** — Schedule (today + next business day) with meeting prep, Needs Attention inbox with one-click reply drafting
- **Opportunities** — pipeline grouped by tech-validation stage, one-click account briefs
- **Accounts** — per-account Q&A, brief history, technical notes
- **Post-Call** — upload a transcript → get Salesforce technical notes + follow-up email
- **Feedback** — log partner enhancement requests / bugs to the shared tracker
- **Settings** — pod roster, refresh cadences, service status

All data lives locally in per-user OneDrive; team pipeline data comes from a shared SharePoint folder.

---

## Install (first time)

**Prerequisites:**
- Windows 11
- Elevated PowerShell

Node.js, the Claude CLI, and NSSM are all installed automatically via WinGet by the installer. You do **not** need to sync SharePoint first — the installer will walk you through that if the shared tool folder isn't already on disk.

**Steps** (elevated PowerShell):

```powershell
$tmp = "$env:TEMP\install.ps1"
Invoke-WebRequest -Uri 'https://github.com/aanerdio/nerdio-se-command-center/releases/latest/download/install.ps1' -OutFile $tmp
powershell -ExecutionPolicy Bypass -File $tmp
```

The installer:
1. Locates the shared SharePoint tool folder — if it's missing, offers to open the SP site in your browser (click **Sync**) or accept a custom local path.
2. Installs Node.js LTS and Claude Code via WinGet if not already present.
3. Shows a numbered menu of SEs (from the shared `pod-assignments.json`) — pick yours to confirm identity.
4. Writes `%USERPROFILE%\OneDrive - Nerdio\SE-Command-Center\user.json`.
5. Copies the app into `%LOCALAPPDATA%\Programs\SE-Command-Center\`.
6. Runs `npm install` and generates your `pod-roster.json`.
7. Registers the **SE Dashboard** NSSM Windows service and starts it.

Idempotent — safe to re-run.

Open the dashboard at **http://localhost:3131**.

---

## Update to the latest version

When Anthony or Marcos publishes a new release, run one of these from an elevated PowerShell:

```powershell
# A) From your PROD install directory (normal case):
cd $env:LOCALAPPDATA\Programs\SE-Command-Center
.\update.ps1
```

```powershell
# B) Re-download the updater from GitHub (if your local copy is broken or missing):
$tmp = "$env:TEMP\update.ps1"
Invoke-WebRequest -Uri 'https://github.com/aanerdio/nerdio-se-command-center/releases/latest/download/update.ps1' -OutFile $tmp
powershell -ExecutionPolicy Bypass -File $tmp
```

The script compares `version.json`, mirrors the shared code into your PROD install, runs `npm install` only if `package.json` changed, and restarts the service. Safe to re-run.

Use `.\update.ps1 -Force` to sync even when versions match.

---

## Service management

```powershell
Get-Service 'SE Dashboard'                 # status
Restart-Service 'SE Dashboard'
Stop-Service 'SE Dashboard'
Start-Service 'SE Dashboard'
```

Logs: `%LOCALAPPDATA%\Programs\SE-Command-Center\service\logs\dashboard.log` (NSSM-rotated at 5 MB).

---

## Where your data lives

| What | Where |
|---|---|
| **Shared team data** (pipeline store, pod roster) | `%USERPROFILE%\OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center\` |
| **Your personal state** (dashboard runtime, account briefs, uploads) | `%USERPROFILE%\OneDrive - Nerdio\SE-Command-Center\` |
| **The app itself** | `%LOCALAPPDATA%\Programs\SE-Command-Center\` |

Only Anthony + Marcos can write to the shared pipeline store — everyone else's dashboard reads it. The auto-refresh runs on your machine but only writes when you're on the allow-list.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `localhost:3131` won't load | `Get-Service 'SE Dashboard'` — if not Running, `Restart-Service 'SE Dashboard'` |
| Pipeline tab empty | The shared store may be stale. Ask Anthony or Marcos to run `/se-sf-sync`, or wait for the 8:30 AM auto-refresh. |
| Dashboard shows the wrong SE | Edit `$env:USERPROFILE\OneDrive - Nerdio\SE-Command-Center\user.json` and restart the service. |
| "user.json missing" on startup | Re-run `.\install.ps1` from your PROD install dir — it'll prompt for your SE identity. |
| Service won't start after update | Check `service\logs\dashboard.log`; verify Node.js is on PATH for the service account. |
| `sf-pipeline-store.json not found` | The shared SharePoint folder isn't synced. Confirm `%USERPROFILE%\OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center\data\` exists and contains the file. |
| Skill stuck / spinner won't clear | POST to `/api/cancel-processing` or delete `data\processing.json` under your personal `SE-Command-Center\`. Check `logs\skill-*.log`. |
| Meeting Prep tab shows no SF link | Match failed — the meeting may need to be manually associated. Check the calendar event's attendee list. |

For deeper issues see the full troubleshooting reference in the DEV repo README, or ping Anthony / Marcos.

---

## Getting help

- **Bug or enhancement request:** ping the SE channel or use `/log-feedback` in Claude
- **Questions about the platform:** OVERVIEW.md and QUICK-REFERENCE.md cover the day-to-day workflow
- **Source code:** [aanerdio/se-command-center](https://github.com/aanerdio/se-command-center)
