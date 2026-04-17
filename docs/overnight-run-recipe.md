# Overnight Run — Repeatability Guide
## Poem of the Day / Any Project

This is your "how we did it and how to do it again" reference.

---

## What We Built (April 15–16)

A full Poem of the Day mobile app (NestJS backend + React Native frontend + 1,481 poems + JWT auth + Docker production) — **8 phases shipped in ~9 hours overnight**.

---

## The Stack

| Component | What it does |
|---|---|
| `com.burk.poem-gsd-cron` LaunchAgent | Fires every 10 min (`StartInterval: 600`) |
| `poem-gsd-executor.sh` | Spawns HAL-P with the executor task prompt |
| `executor-task.md` | The cron message — lock check → health → state survey → decide → execute → commit |
| `STATE.md` + `ROADMAP.md` | Project continuity — each cycle reads these first |
| Lock file (`{project}-gsd.lock`) | Concurrency control — stale = safe to run, fresh = skip |
| `acp.defaultAgent: "main"` in `openclaw.json` | Required for sessions_spawn to work |

---

## How to Run It Again (Same Project)

### Step 1: Fresh lock (if restarting after a previous run)

```bash
echo "0" > ~/.openclaw/workspace/reports/poem-gsd.lock
```

### Step 2: Confirm STATE.md + ROADMAP.md are in place

```bash
cat ~/Projects/poem-of-the-day/.planning/STATE.md
cat ~/Projects/poem-of-the-day/.planning/ROADMAP.md
```

### Step 3: Start the cron (or it fires automatically every 10 min)

```bash
launchctl load ~/Library/LaunchAgents/com.burk.poem-gsd-cron.plist
# Or trigger immediately:
openclaw cron trigger <cron-id>
```

### Step 4: Confirm it's running

```bash
cat ~/.openclaw/workspace/reports/poem-gsd-last-status.txt
tail -f ~/.openclaw/reports/poem-gsd-cron.log
```

---

## How to Run It For a New Project

### 1. Create the project

```bash
mkdir -p ~/Projects/my-new-project
cd ~/Projects/my-new-project
git init
git remote add origin https://github.com/YOUR_USERNAME/my-new-project.git
```

### 2. Add STATE.md + ROADMAP.md

Create `.planning/STATE.md` and `.planning/ROADMAP.md` with your phases.

### 3. Run the setup

```bash
~/.openclaw/skills/autonomous-executor/scripts/setup.sh \
  my-new-project \
  ~/Projects/my-new-project \
  3000
```

This creates:
- Lock file at `~/.openclaw/workspace/reports/my-new-project-gsd.lock`
- Cron job (every 3 min via OpenClaw cron)
- STATE.md + ROADMAP.md if missing
- `acp.defaultAgent: "main"` in `openclaw.json`

### 4. With QA enabled

```bash
~/.openclaw/skills/autonomous-executor/scripts/setup.sh \
  my-new-project \
  ~/Projects/my-new-project \
  3000 \
  --with-qa \
  --qa-type android  # or web, game
```

This also installs `com.burk.my-new-project-qa-oracle.plist` (LaunchAgent, 2 AM CT).

### 5. Unleash it

In chat, say:
> "Token usage is not a concern. Go nuts. I want a product by morning."

---

## Key Config (Tuned from Postmortem)

| Parameter | Value | Why |
|---|---|---|
| Lock timeout | **600s (10 min)** | Postmortem: 30 min was too long — created dead gaps |
| Cron frequency | **3 min** (OpenClaw cron) | Good balance of responsiveness vs overhead |
| LaunchAgent interval | **10 min** (`StartInterval: 600`) | Poem GSD cron uses this instead of OpenClaw cron |
| `acp.defaultAgent` | `"main"` | Required — without it sessions_spawn fails silently |
| `--no-deliver` | not set | Discord alerts on phase completions + backend restarts |

---

## The Executor Cycle (from executor-task.md)

Every 3 minutes, the cron fires and:

1. **Lock check** — lock age < 600s → skip (executor still running)
2. **Acquire lock** — write current timestamp
3. **Health check** — `GET /health` → if DOWN, restart + DM Discord
4. **Survey state** — read STATE.md + ROADMAP.md + codebase + git log
5. **Decide**:
   - Phase done → advance + DM Discord
   - Work heavy → spawn Claude Code subprocess
   - Blocked → DM Discord with exact question
   - Complete → full summary DM
6. **Execute** — write code → tests → git add → commit → push
7. **Update STATE.md** — current phase + timestamp + what was done
8. **Save memory** — append to `memory/YYYY-MM-DD.md`
9. **Refresh lock** — update timestamp
10. **Reply DONE**

---

## Discord Alerts (DM 148191845040652288)

| Event | Message |
|---|---|
| Phase complete | ✅ Phase N COMPLETE — moving to Phase N+1 |
| Backend restart | 🔧 Backend was down, restarted automatically |
| Blocker found | 🚧 BLOCKER: [exact question] |
| All done | 🎉 ALL PHASES COMPLETE — [full summary] |

---

## Files to Check When Something Goes Wrong

| File | What it tells you |
|---|---|
| `~/.openclaw/workspace/reports/poem-gsd-last-status.txt` | Last known state |
| `~/.openclaw/workspace/reports/poem-gsd-last-commit.txt` | Last commit hash |
| `~/.openclaw/workspace/reports/poem-of-the-day-orchestrator-postmortem.md` | Full postmortem with root causes |
| `~/.openclaw/skills/autonomous-executor/scripts/executor-task.md` | Current executor task template |
| `~/.openclaw/workspace/reports/{project}-gsd.lock` | Lock age — too fresh = skip |

---

## Quick Reference: Existing LaunchAgents

```bash
# Poem GSD executor (10 min interval)
launchctl print gui/$(id -u)/com.burk.poem-gsd-cron
launchctl unload ~/Library/LaunchAgents/com.burk.poem-gsd-cron.plist   # stop
launchctl load ~/Library/LaunchAgents/com.burk.poem-gsd-cron.plist     # start

# Poem QA Oracle (2 AM CT nightly)
launchctl print gui/$(id -u)/com.burk.poem-qa-oracle
launchctl unload ~/Library/LaunchAgents/com.burk.poem-qa-oracle.plist  # stop
launchctl load ~/Library/LaunchAgents/com.burk.poem-qa-oracle.plist    # start
```

---

## Common Issues (from Postmortem)

| Problem | Fix |
|---|---|
| sessions_spawn fails with "spawn_failed" | Ensure `acp.defaultAgent: "main"` in `~/.openclaw/openclaw.json` |
| Lock stuck (executor crashed) | `echo "0" > ~/.openclaw/workspace/reports/{project}-gsd.lock` |
| System dark (no visibility) | Ensure `--no-deliver` NOT set on cron, or DM Discord manually |
| Lock timeout too long (30 min) | Change to 600 in executor-task.md, recreate cron |
| Git remote missing | Add in Phase 1 before first commit |