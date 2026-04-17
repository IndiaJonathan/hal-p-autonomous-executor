# Autonomous Executor Skill

**Skill:** `autonomous-executor`
**Type:** Orchestration / Process Automation
**What it does:** Wakes up on a cron schedule, reads project state, decides what to execute, builds it, and reports back.

---

## When to Use This Skill

Use this when:
- You want to build a full project overnight without sitting in front of it
- You need an autonomous agent that can own a backlog and drive it forward
- You want a "set and forget" build system that pings you only when it needs you
- You need a persistent executor that survives session boundaries

**Don't use this for:** one-off tasks, things that need a human in the loop every step, or projects where the next action is always obvious (just do it directly instead).

---

## What Gets Built

The skill sets up a **cron-driven autonomous executor** that:

```
Cron fires (every 3 minutes)
  → HAL-P wakes in isolated session (MiniMax model)
    → Health check (is the service up?)
    → Read project STATE.md — know where you are
    → Read ROADMAP.md — know what's next
    → Survey existing codebase — know what's already built
    → Check git log — know what's been committed
    → DECIDE:
      If service is down → restart it, DM "🔧 Backend was down, restarted"
      If clear next work exists → execute it directly
      If heavy multi-file work needed → spawn Claude Code subprocess
      If Phase N is done → advance to Phase N+1, DM "✅ Phase N complete"
      If blocked on a real question → DM the human with the question
    → After every action:
      git add → git commit → git push
      Update STATE.md with what was done
      Save progress to memory/YYYY-MM-DD.md
    → Release lock (10 min timeout)
    → Reply DONE
```

---

## Quick Start

```bash
# 1. Set up a new project with STATE.md + ROADMAP.md

# 2. Run the setup script
~/.openclaw/skills/autonomous-executor/scripts/setup.sh \
  my-project \
  ~/Projects/my-project \
  3000

# 3. Remove token budget constraint (tell HAL-P in chat)
# "Token usage is not a concern. Go nuts. I want a product by morning."

# 4. Wake up to a working project
```

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  OpenClaw Cron (every 3 minutes)                    │
│  Session: isolated, MiniMax-M2.7                    │
└─────────────────────┬────────────────────────────────┘
                      │
                      ▼
         ┌────────────────────────────┐
         │  Lock file check            │
         │  /reports/{project}-gsd.lock│
         │  age < 600s (10 min) → skip│
         │  age >= 600s → stale       │
         └──────────────┬─────────────┘
                          │ stale
                          ▼
         ┌────────────────────────────┐
         │  Health check              │
         │  GET /health → restart if  │
         │  DOWN, DM Discord         │
         └──────────────┬─────────────┘
                          │ healthy
                          ▼
         ┌────────────────────────────┐
         │  Survey state               │
         │  STATE.md + ROADMAP.md +     │
         │  codebase + git log        │
         └──────────────┬─────────────┘
                          │
                          ▼
         ┌────────────────────────────┐
         │  Decide + execute           │
         │  Direct: small fixes, tests │
         │  Spawn: heavy multi-file    │
         │  Phase done? → DM + advance │
         └──────────────┬─────────────┘
                          │
                          ▼
         ┌────────────────────────────┐
         │  After work               │
         │  git add → commit → push   │
         │  Update STATE.md + memory   │
         │  Release lock (10 min)     │
         └────────────────────────────┘
```

---

## Core Scripts

### `setup.sh` — One-command project setup

```bash
~/.openclaw/skills/autonomous-executor/scripts/setup.sh \
  PROJECT_NAME \
  /path/to/project \
  PORT
```

Does:
1. Creates lock file
2. **Adds `acp.defaultAgent: "main"` to `openclaw.json`** (fixes sessions_spawn)
3. Prompts for git remote setup (required before pushing)
4. Validates STATE.md + ROADMAP.md exist
5. Creates basic STATE.md + ROADMAP.md if missing
6. Builds the executor task prompt
7. Creates the cron job

### `executor.sh` — Lock manager CLI

```bash
./executor.sh start    # acquire lock if stale
./executor.sh status   # show lock age + status
./executor.sh stop     # release lock
./executor.sh force    # force-lock regardless of age
./executor.sh health   # check backend health
```

---

## Lock File — Concurrency Control

```
~/.openclaw/workspace/reports/{PROJECT}-gsd.lock
```

Format: Unix timestamp of when lock was acquired.

- Lock age **< 600s (10 min)** → executor still running → skip
- Lock age **>= 600s** → stale → safe to proceed

**10-minute lock** is the tuned default. Stale = executor crashed or finished. Safe to run.

Override via environment:
```bash
EXECUTOR_LOCK_TIMEOUT=1800 ./executor.sh start  # 30 min for heavy builds
```

---

## sessions_spawn — Critical Config

**CRITICAL:** Without `agentId: "main"`, sessions_spawn fails every time.

```bash
Error: spawn_failed — Failed to spawn agent command: main
```

The `setup.sh` automatically adds this to your `openclaw.json`:
```json
{
  "acp": {
    "defaultAgent": "main"
  }
}
```

To verify it's set:
```bash
grep -A1 '"acp"' ~/.openclaw/openclaw.json
```

Working sessions_spawn call:
```bash
openclaw sessions spawn \
  --runtime "acp" \
  --agentId "main" \
  --model "minimax/MiniMax-M2.7" \
  --cwd "/path/to/project" \
  --runTimeoutSeconds 10800 \
  --task "YOUR TASK" \
  --mode "run"
```

---

## Discord Visibility — Phase Alerts

The executor DM's Discord for events that matter:

| Event | DM contains |
|---|---|
| Phase complete | ✅ Phase N COMPLETE — moving to Phase N+1 |
| Backend restart | 🔧 Backend was down, restarted |
| Blocker found | 🚧 BLOCKER: [exact question] |
| All done | 🎉 ALL PHASES COMPLETE — [full summary] |

You only hear from it when something significant happens. No message noise.

Discord user ID: `148191845040652288` (IndiaVenom)

---

## STATE.md — The Continuity File

Every project maintains this at `{PROJECT}/.planning/STATE.md`:

```markdown
# STATE — {Project Name}

## Project State
- **Current phase:** N (description)
- **Mode:** yolo
- **Last updated:** YYYY-MM-DD HH:MM

## Active Decisions
- Stack: ...
- Database: ...

## Blockers
- None

## Recent Activity
- YYYY-MM-DD HH:MM: What was done
```

The executor reads this first on every wake. It's how every cycle knows where the project is without a long context handoff.

---

## Tuning

| Parameter | Default | Tune when |
|---|---|---|
| Lock timeout | **600s (10 min)** | 1800s for heavy Claude Code sessions |
| Cron frequency | 3 min | 10 min for slow builds |
| Health check cooldown | 5 min | Prevents restart spam |

### Token Budget

Remove constraints for maximum velocity:
> "Token usage is not a concern. Go nuts. I want a product by morning."

---

## What to Do When sessions_spawn Fails

If sessions_spawn fails, the system falls back to **HAL-P self-execution** — which is reliable and productive. The Poem of the Day project was built almost entirely this way.

**Fix:** Ensure `acp.defaultAgent: "main"` is in `~/.openclaw/openclaw.json`.

---

## Project Readiness Checklist

Before starting an overnight build:

- [x] `acp.defaultAgent: "main"` set in `openclaw.json` (setup.sh adds this)
- [ ] Git repo initialized with remote set (`git remote add origin <url>`)
- [ ] Lock file created: `touch ~/.openclaw/workspace/reports/{PROJECT}-gsd.lock`
- [ ] STATE.md initialized at `{PROJECT}/.planning/STATE.md`
- [ ] ROADMAP.md with phases defined
- [ ] Health endpoint implemented (`GET /health`)
- [ ] Docker compose works: `docker compose up -d`
- [ ] Cron created with `setup.sh` or `openclaw cron create`
- [ ] Token budget unconstrained: "go nuts, I want a product by morning"
- [ ] QA agent LaunchAgent installed (`com.burk.{project}-qa-agent.plist`, every 30 min) — if `--with-qa` was used
- [ ] Plane project ID configured in executor task (`PLANE_PROJECT_ID` variable) — if QA loop is desired

---

## Anti-Patterns

1. **Don't run the executor on the main session** — use `--session isolated`
2. **Don't skip the health check** — backend downtime is common; self-healing is the most valuable automation
3. **Don't skip STATE.md updates** — without them, every cycle is blind
4. **Don't let the lock timeout be too short** — you'll get overlapping executions
5. **Don't run without git push** — commits pile up and you can't verify what's shipped
6. **Don't set token budget constraints** — it makes the executor timid and slow

---

## Overnight Run Recipe

How we ran the Poem of the Day overnight build — and how to repeat it.
See **docs/overnight-run-recipe.md** for:
- Step-by-step repeatability guide
- LaunchAgent configs (10-min GSD cron, 2 AM QA oracle)
- Key tuned parameters (lock timeout: 600s, not 1800s)
- Common issues + fixes from the postmortem
- Quick reference for existing LaunchAgents

## QA Delivery Annex

Every project built by the autonomous executor can include an **automated QA gate** that runs after each build cycle, files Plane tickets automatically, and sends Discord summaries.

See **docs/qa-delivery-annex.md** for:
- QA architecture and check catalog
- **Android QA Debugging Playbook** — shell `input tap` vs uiautomator2, dumpsys crash detection, monkey seed avoidance, boot-complete wait, swipe-vs-tap for RN onboarding
- **Periodic QA agent** — every 30 min spawn script + LaunchAgent setup; files Plane tickets on failures
- **Plane ticket → Executor loop** — executor pulls new QA tickets each cycle, injects into STATE.md, executes fix, marks resolved, DMs Discord on fix
- Plane ticket pattern for bug filing
- QA script templates (Python + shell orchestrator)
- Nightly QA oracle setup guide
- Discord QA summary format (failures only — no noise on clean runs)

## Mobile App Annex

For React Native / Expo Android apps, see **docs/mobile-app-delivery-annex.md** for:
- `EXPO_PUBLIC_API_URL` — must be set before APK build (the #1 cause of "API calls fail on phone")
- `APP_URL` — must be set for magic link / email verification URLs
- Cloudflared tunnel port config — update when backend port changes
- APK download via backend instead of GitHub releases
- Onboarding-first navigator pattern (not auth-first)
- Android build environment setup (JDK 21, Android SDK)
- Pre-delivery checklist for Android apps
