# Nerdio SE Command Center

Pod-wide Sales Engineering command center for the Nerdio MSP SE team. Runs locally on every SE's laptop as a per-user Scheduled Task that starts at logon — no admin needed. Pulls pipeline data from Salesforce CSV reports (curated by the pod leads) and layers on live calendar, email, and post-call context.

- **Dashboard:** `http://localhost:3131`
- **Docs:** [OVERVIEW.md](OVERVIEW.md) — features & workflow · [QUICK-REFERENCE.md](QUICK-REFERENCE.md) — one-page cheat sheet · [ARCHITECTURE.md](ARCHITECTURE.md) — technical reference
- **Source repo (DEV):** [aanerdio/se-command-center](https://github.com/aanerdio/se-command-center) — where features are built
- **Releases:** [Installer releases](https://github.com/aanerdio/nerdio-se-command-center-installer/releases) — public repo with `install.ps1` + `update.ps1` assets on every release

---

## What it does

Six-tab dashboard that unifies your SE workday:

- **Home** — Schedule (today + next business day) with meeting prep, Needs Attention inbox with one-click reply drafting
- **Opportunities** — pipeline grouped by tech-validation stage, one-click account briefs
- **Accounts** — per-account Q&A, brief history, technical notes
- **Post-Call** — upload a transcript → get Salesforce technical notes + follow-up email
- **Feedback** — log partner enhancement requests / bugs to the shared tracker
- **Settings** — pod roster, refresh cadences, task status

All data lives locally in per-user OneDrive; team pipeline data comes from a shared SharePoint folder.

---

## Install (first time)

**Prerequisites:**
- Windows 11
- A normal (non-elevated) PowerShell — admin is only needed once if you're migrating from an older Windows-service install
- **Microsoft 365 integration enabled in claude.ai** (see below — needed for calendar, emails, and meeting invites)

Node.js and the Claude CLI are installed automatically via WinGet by the installer. You do **not** need to sync SharePoint first — the installer will walk you through that if the shared tool folder isn't already on disk.

### Enable the Microsoft 365 integration in claude.ai

This is the only external service the dashboard talks to. One-time setup, ~30 seconds:

1. Open **[https://claude.ai/settings/integrations](https://claude.ai/settings/integrations)** in a browser signed into your Nerdio account.
2. Find **Microsoft 365** and click **Enable** (or **Connect**).
3. Complete the browser OAuth prompt with your `@getnerdio.com` account.
4. Confirm the integration shows as **Connected**.

That's it — the dashboard's calendar, emails, meeting invites, and email drafting all flow through this integration. If the connection ever breaks, the dashboard's data widgets stop refreshing until you re-enable it here.

**No other MCPs required.** The dashboard does **not** need the local Outlook COM MCP, HubSpot MCP, or any Entra app registration.

**Steps** (normal PowerShell — no admin):

```powershell
$tmp = "$env:TEMP\install.ps1"
Invoke-WebRequest -Uri 'https://github.com/aanerdio/nerdio-se-command-center-installer/releases/latest/download/install.ps1' -OutFile $tmp
powershell -ExecutionPolicy Bypass -File $tmp
```

The installer:
1. Detects any legacy `SE Dashboard` Windows service from an older install and removes it (this one step needs admin — the installer will tell you to re-run elevated if it finds one).
2. Locates the shared SharePoint tool folder — if it's missing, offers to open the SP site in your browser (click **Sync**) or accept a custom local path.
3. Installs Node.js LTS and Claude Code via WinGet if not already present.
4. Shows a numbered menu of SEs (from the shared `pod-assignments.json`) — pick yours to confirm identity.
5. Writes `%USERPROFILE%\OneDrive - Nerdio\SE-Command-Center\user.json`.
6. Copies the app into `%LOCALAPPDATA%\Programs\SE-Command-Center\`.
7. Runs `npm install` and generates your `pod-roster.json`.
8. Registers the **SE Dashboard** per-user Scheduled Task (triggered at your logon, battery-safe) and starts it.

Idempotent — safe to re-run.

Open the dashboard at **http://localhost:3131**.

---

## Update to the latest version

When Anthony or Marcos publishes a new release, run one of these from a normal (non-elevated) PowerShell:

```powershell
# A) From your PROD install directory (normal case):
cd $env:LOCALAPPDATA\Programs\SE-Command-Center
.\update.ps1
```

```powershell
# B) Re-download the updater from GitHub (if your local copy is broken or missing):
$tmp = "$env:TEMP\update.ps1"
Invoke-WebRequest -Uri 'https://github.com/aanerdio/nerdio-se-command-center-installer/releases/latest/download/update.ps1' -OutFile $tmp
powershell -ExecutionPolicy Bypass -File $tmp
```

The script compares `version.json`, mirrors the shared code into your PROD install, runs `npm install` only if `package.json` changed, and restarts the Scheduled Task. Safe to re-run.

Use `.\update.ps1 -Force` to sync even when versions match.

**One-time migration:** if your machine was installed before the switch to Scheduled Task (i.e. still has an `SE Dashboard` Windows service), the *first* `update.ps1` after cutover has to run elevated so it can remove the old service and register the new task. Every update after that runs unelevated.

---

## Task management

```powershell
Get-ScheduledTask   -TaskName 'SE Dashboard' | Get-ScheduledTaskInfo   # status
Start-ScheduledTask -TaskName 'SE Dashboard'
Stop-ScheduledTask  -TaskName 'SE Dashboard'
.\service\status.ps1                                                   # full health check
```

Logs: `%LOCALAPPDATA%\Programs\SE-Command-Center\service\logs\dashboard.log` (rotates at 5 MB, 5 archives kept).

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
| `localhost:3131` won't load | `Get-ScheduledTask 'SE Dashboard'` — if State is not Running/Ready, `Start-ScheduledTask 'SE Dashboard'`. Or run `.\service\status.ps1` for a full picture. |
| Pipeline tab empty | The shared store may be stale. Ask Anthony or Marcos to run `/se-sf-sync`, or wait for the 8:30 AM auto-refresh. |
| Dashboard shows the wrong SE | Edit `$env:USERPROFILE\OneDrive - Nerdio\SE-Command-Center\user.json`, then `Stop-ScheduledTask 'SE Dashboard'; Start-ScheduledTask 'SE Dashboard'`. |
| "user.json missing" on startup | Re-run `.\install.ps1` from your PROD install dir — it'll prompt for your SE identity. |
| Task won't start after update | Check `service\logs\dashboard.log`; verify `node` is on your user PATH. |
| `sf-pipeline-store.json not found` | The shared SharePoint folder isn't synced. Confirm `%USERPROFILE%\OneDrive - Nerdio\MSP Sales Team - Sales Engineering - Sales Engineering\00 - Team Resources\Claude\Tools\se-command-center\data\` exists and contains the file. |
| Skill stuck / spinner won't clear | POST to `/api/cancel-processing` or delete `data\processing.json` under your personal `SE-Command-Center\`. Check `logs\skill-*.log`. |
| Meeting Prep says "skipped" | The skill decided the meeting isn't SE work — internal Nerdio meeting, no SF opp, wrong stage (still Discovery), or the opp is already closed. Reason line explains why. Click **Run Anyway** if you want to force full prep. |
| Meeting Prep shows red **NO OPPORTUNITY** banner | Prep ran but no SF opp matched. Either you clicked Run Anyway, or attendee domains didn't hit anything in `sf-pipeline-store.json`. Double-check the account before pasting the SF note. |
| Needs Attention: nothing happens on "Reply in Outlook" | The button copies the drafted body to your clipboard and opens the original message in Outlook Web. Ctrl+V into the reply pane. If nothing opens, check your browser's popup blocker. |
| Calendar / Emails widgets stay empty | Verify the Microsoft 365 integration is still connected at [claude.ai/settings/integrations](https://claude.ai/settings/integrations). All calendar/email data flows through it. |

For deeper issues see the full troubleshooting reference in the DEV repo README, or ping Anthony / Marcos.

---

## Getting help

- **Bug or enhancement request:** ping the SE channel or use `/log-feedback` in Claude
- **Questions about the platform:** OVERVIEW.md and QUICK-REFERENCE.md cover the day-to-day workflow
- **Source code:** [aanerdio/se-command-center](https://github.com/aanerdio/se-command-center)
