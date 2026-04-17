#!/bin/bash
# Autonomous Executor — Project Setup Script
# Usage: ./setup.sh <project-name> <project-root> [port] [--with-qa] [--qa-type android|web|game]
#
# Examples:
#   ./setup.sh poem-of-the-day ~/Projects/poem-of-the-day 3003
#   ./setup.sh galactic-idle ~/Projects/galactic-idle 3000 --with-qa --qa-type game

set -e

PROJECT="${1:?Usage: $0 <project-name> <project-root> [port] [--with-qa] [--qa-type android|web|game]}"
PROJECT_ROOT="${2:?Usage: $0 <project-name> <project-root> [port]}"
PORT="${3:-3000}"

# Optional QA flags
WITH_QA=false
QA_TYPE="android"
for arg in "$@"; do
  case "$arg" in
    --with-qa) WITH_QA=true ;;
    --qa-type) QA_TYPE="$arg" ;;
  esac
done
# Re-parse properly
WITH_QA=false
QA_TYPE="android"
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --with-qa) WITH_QA=true ;;
    --qa-type)
      QA_TYPE="${2:?}"
      shift
      ;;
  esac
  shift
done

LOCK_FILE="/Users/jonathan/.openclaw/workspace/reports/${PROJECT}-gsd.lock"
SKILL_DIR="/Users/jonathan/.openclaw/skills/autonomous-executor"
MEMORY_DIR="/Users/jonathan/.openclaw/workspace/memory"
DISCORD_USER_ID="148191845040652288"

# Validate project root
if [ ! -d "$PROJECT_ROOT" ]; then
  echo "ERROR: project root does not exist: $PROJECT_ROOT"
  exit 1
fi

# Ensure reports + memory dirs
mkdir -p "$(dirname "$LOCK_FILE")"
mkdir -p "$MEMORY_DIR"

# Create lock file
touch "$LOCK_FILE"
echo "0" > "$LOCK_FILE"
echo "✓ Lock file created: $LOCK_FILE"

# ---- STEP 1: Git remote (REQUIRED — no excuses) ----
echo ""
echo "=== Git Remote Setup ==="
if git -C "$PROJECT_ROOT" remote get-url origin &>/dev/null; then
  echo "✓ Git remote already configured: $(git -C "$PROJECT_ROOT" remote get-url origin)"
else
  echo "⚠ No git remote configured."
  echo ""
  echo "  1. Create a GitHub repo at: https://github.com/new"
  echo "     (Repo name: $PROJECT)"
  echo ""
  echo "  2. Then run:"
  echo "     cd $PROJECT_ROOT"
  echo "     git remote add origin https://github.com/YOUR_USERNAME/$PROJECT.git"
  echo "     git push -u origin main"
  echo ""
  echo "  ⚠ The executor will not push commits until a remote is configured!"
  echo ""
fi

# ---- STEP 2: Ensure acp.defaultAgent is set ----
echo ""
echo "=== OpenClaw ACP Config ==="
OC_CONFIG="$HOME/.openclaw/openclaw.json"
if grep -q '"defaultAgent"' "$OC_CONFIG" 2>/dev/null; then
  echo "✓ acp.defaultAgent already configured"
else
  echo "⚠ Adding acp.defaultAgent to openclaw.json..."
  # Backup first
  cp "$OC_CONFIG" "$OC_CONFIG.bak.$(date +%s)"
  # Add acp.defaultAgent after the opening brace
  sed -i '' 's/^{/{\n  "acp": {\n    "defaultAgent": "main"\n  },/' "$OC_CONFIG"
  echo "✓ Added acp.defaultAgent: \"main\" to openclaw.json"
  echo "  (backup saved as $OC_CONFIG.bak.*)"
fi

# ---- STEP 3: Check for STATE.md ----
echo ""
echo "=== Project State ==="
STATE_FILE="$PROJECT_ROOT/.planning/STATE.md"
if [ -f "$STATE_FILE" ]; then
  echo "✓ STATE.md found: $STATE_FILE"
  echo "  Current phase: $(grep -m1 'Current phase:' "$STATE_FILE" | sed 's/.*phase: *//' || echo 'unknown')"
else
  echo "⚠ WARNING: STATE.md not found at $STATE_FILE"
  echo "  The executor needs this to track progress. Creating basic one..."
  mkdir -p "$PROJECT_ROOT/.planning"
  cat > "$STATE_FILE" << EOF
# STATE — $PROJECT

## Project State
- **Initialized:** $(date +%Y-%m-%d)
- **Current phase:** 1 (foundation)
- **Mode:** yolo
- **Last updated:** $(date +%Y-%m-%d)

## Active Decisions
- Stack: (fill in)
- Database: (fill in)

## Blockers
- None

## Recent Activity
- $(date +%Y-%m-%d): Project initialized
EOF
  echo "✓ Created basic STATE.md"
fi

# ---- STEP 4: Check for ROADMAP.md ----
echo ""
echo "=== Project Roadmap ==="
ROADMAP_FILE="$PROJECT_ROOT/.planning/ROADMAP.md"
if [ -f "$ROADMAP_FILE" ]; then
  echo "✓ ROADMAP.md found: $ROADMAP_FILE"
  PHASE_COUNT=$(grep -c "^## Phase" "$ROADMAP_FILE" 2>/dev/null || echo "0")
  echo "  Phases: $PHASE_COUNT"
else
  echo "⚠ WARNING: ROADMAP.md not found at $ROADMAP_FILE"
  echo "  Creating a basic 3-phase roadmap..."
  mkdir -p "$PROJECT_ROOT/.planning"
  cat > "$ROADMAP_FILE" << 'ROADMAP'
# ROADMAP — TODO

## Phase 1: Foundation
**Goal:** Stand up the project structure — backend + frontend scaffold, database, CI.

- Initialize backend (NestJS / Express / Fastify — choose one)
- Initialize frontend
- Set up database schema
- Configure Docker Compose
- Set up CI pipeline
- Write README

## Phase 2: Core Features
**Goal:** Implement the core feature set.

- Feature 1
- Feature 2
- Feature 3

## Phase 3: Polish & Ship
**Goal:** Ship a presentable v1.

- Polish UI/UX
- Error handling
- Production hardening
- Deploy
ROADMAP
  echo "✓ Created basic ROADMAP.md"
fi

# ---- STEP 5: Health endpoint check ----
echo ""
echo "=== Backend Health Check ==="
echo -n "Checking health endpoint on port $PORT... "
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/health" 2>/dev/null | grep -q "200"; then
  echo "✓ Backend is healthy"
else
  echo "⚠ Backend not responding on port $PORT"
  echo "  (or /health endpoint not implemented yet)"
fi

# ---- STEP 6: Build executor task prompt ----
echo ""
echo "=== Building Executor Task ==="
TASK_FILE="/tmp/${PROJECT}-executor-task.txt"
cat > "$TASK_FILE" << TASK_EOF
You are the autonomous executor for the $PROJECT project.

PROJECT_ROOT: $PROJECT_ROOT
LOCK_FILE: $LOCK_FILE
STATE_FILE: $STATE_FILE
ROADMAP_FILE: $ROADMAP_FILE
MEMORY_FILE: $MEMORY_DIR/\$(date +%Y-%m-%d).md
HEALTH_URL: http://localhost:$PORT/health
DISCORD_DM_ID: $DISCORD_USER_ID

LOCK TIMEOUT: 600s (10 min). Lock age < 600s means executor is still running → reply DONE.

YOUR JOB every wake cycle:
1. Check lock: NOW=\$(date +%s); LOCK_AGE=\$(stat -f%Sm -t%s "$LOCK_FILE" 2>/dev/null || echo "0"); AGE=\$((NOW - LOCK_AGE))
   If AGE < 600: reply DONE immediately
2. Acquire lock: echo "\$NOW" > "$LOCK_FILE"
3. Health check: curl -s http://localhost:$PORT/health
   If DOWN: restart the service, then DM Discord: "🔧 Backend was down, restarted automatically."
4. Read STATE.md and ROADMAP.md
5. Survey existing code (ls \$PROJECT_ROOT/apps/*/src/ or similar)
6. Check git log (git -C \$PROJECT_ROOT log --oneline -5)
7. DECIDE:
   - If Phase N done but Phase N+1 not started: start Phase N+1, DM Discord: "✅ Phase N COMPLETE — [brief summary]. Moving to Phase N+1."
   - If Phase N in progress: execute highest-priority next task
   - If work is heavy (multi-file generation, large refactor): spawn Claude Code subprocess
   - If blocked on real question only human can answer: DM Discord with exact question, then work around if possible
   - If project complete: DM Discord with full completion summary
8. Execute: write code → run tests → git add → commit → push
9. Update STATE.md with what was completed and the timestamp
10. Save to memory/\$(date +%Y-%m-%d).md
11. Refresh lock: echo "\$(date +%s)" > "$LOCK_FILE"
12. Reply: brief status of what was done, current state, what's next

RULES:
- NEVER idle. Finish one task, start the next.
- No token budget concerns — use whatever you need.
- Keep tests green. Best practices.
- If stuck, work around it.
- Only escalate to human for questions with NO reasonable workaround.
- Save memory at the end of EVERY run.
- DM Discord for: phase completions, backend restarts, real blockers.

DISCORD ALERTS — DM $DISCORD_USER_ID for:
  ✅ Phase completion: "✅ Phase N COMPLETE — [brief summary]"
  🚧 Blocker: "🚧 BLOCKER: [exact question]"
  🔧 Backend restart: "🔧 Backend was down, restarted"
  🎉 All done: "🎉 ALL PHASES COMPLETE! [full summary]"

Start now. Read state first.
TASK_EOF

echo "✓ Executor task prompt built"

# ---- STEP 7: Create the cron ----
echo ""
echo "=== Creating Cron Job ==="
CRON_MSG=$(cat "$TASK_FILE")
CRON_RESULT=$(openclaw cron create \
  --name "$PROJECT — Autonomous Executor (3min)" \
  --description "Drives $PROJECT forward every 3min — execute, commit, self-heal, DM Discord on phase completions" \
  --every "3m" \
  --session "isolated" \
  --model "minimax/MiniMax-M2.7" \
  --no-deliver \
  --message "$CRON_MSG" 2>&1)

CRON_ID=$(echo "$CRON_RESULT" | grep -o '"id": "[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$CRON_ID" ]; then
  echo "✓ Cron job created: $CRON_ID"
else
  echo "⚠ Cron result: $CRON_RESULT"
fi

# ---- STEP 8: QA setup (optional) ----
if [ "$WITH_QA" = true ]; then
  echo ""
  echo "=== QA Setup ($QA_TYPE) ==="
  PROJECT_DIR="$PROJECT_ROOT"
  QA_DIR="$PROJECT_ROOT/scripts/qa"
  mkdir -p "$QA_DIR"

  # Determine PLANE_PROJECT_ID based on project name
  case "$PROJECT" in
    poem-of-the-day) PLANE_PROJECT_ID="1612c33a-28de-4d76-bd82-d5022e88eddb" ;;
    galactic-idle)   PLANE_PROJECT_ID="f6a30f7c-26d8-4b4e-8f3a-c8b6e7d29e12" ;;
    *)               PLANE_PROJECT_ID="1612c33a-28de-4d76-bd82-d5022e88eddb" ;;
  esac

  case "$QA_TYPE" in
    android)
      # Copy Poem of the Day QA as base template
      if [ -f "$HOME/Projects/poem-of-the-day/scripts/qa/poem_qa.py" ]; then
        cp "$HOME/Projects/poem-of-the-day/scripts/qa/poem_qa.py" "$QA_DIR/qa_runner.py"
        echo "✓ Copied Android QA runner (from poem-of-the-day)"
      else
        echo "⚠ Poem of the Day QA not found — create qa_runner.py manually"
      fi
      ;;
    web)
      # Web QA scaffold — customize per project
      cat > "$QA_DIR/qa_runner.py" << 'PYEOF'
#!/usr/bin/env python3
"""Web QA Runner — customize per project"""
import subprocess, json, sys
from pathlib import Path

REPORTS_DIR = "/Users/jonathan/.openclaw/workspace/reports"

def log(m): print(f"[QA] {m}")
def run_cmd(c, check=False):
    r = subprocess.run(c, capture_output=True, text=True)
    if check and r.returncode != 0: raise RuntimeError(f"Failed: {' '.join(c)}")
    return r

def main():
    checks = {}
    # TODO: implement checks
    # - Page load (200)
    # - JS error-free load
    # - Auth flow (signup/signin)
    # - Core feature page accessible
    checks["page_load"] = "pass"  # placeholder
    checks["api_health"] = "pass"  # placeholder

    Path(f"{REPORTS_DIR}/qa-report.json").write_text(
        json.dumps({"checks": checks}, indent=2)
    )
    sys.exit(0 if all(v == "pass" for v in checks.values()) else 1)

if __name__ == "__main__":
    main()
PYEOF
      echo "✓ Created web QA runner scaffold"
      ;;
    game)
      # Game QA scaffold — customize per project
      cat > "$QA_DIR/qa_runner.py" << 'PYEOF'
#!/usr/bin/env python3
"""Game QA Runner — customize per project"""
import subprocess, json, sys
from pathlib import Path

REPORTS_DIR = "/Users/jonathan/.openclaw/workspace/reports"

def log(m): print(f"[QA] {m}")

def main():
    checks = {}
    # TODO: implement checks
    # - Game page loads
    # - Core UI elements visible
    # - No JS errors / white screen
    # - Save/load (if applicable)
    checks["game_load"] = "pass"  # placeholder

    Path(f"{REPORTS_DIR}/qa-report.json").write_text(
        json.dumps({"checks": checks}, indent=2)
    )
    sys.exit(0 if all(v == "pass" for v in checks.values()) else 1)

if __name__ == "__main__":
    main()
PYEOF
      echo "✓ Created game QA runner scaffold"
      ;;
  esac

  # Nightly orchestrator
  NIGHTLY_SCRIPT="$QA_DIR/nightly-qa-oracle.sh"
  cat > "$NIGHTLY_SCRIPT" << SHELLEOF
#!/bin/bash
set -euo pipefail
PROJECT_DIR="$PROJECT_ROOT"
SCRIPTS_DIR="$PROJECT_DIR/scripts/qa"
REPORTS_DIR="/Users/jonathan/.openclaw/workspace/reports"
LOG_FILE="$REPORTS_DIR/{project}-qa-oracle.log"
STATE_FILE="$REPORTS_DIR/{project}-qa-oracle-state.json"
LOCK_FILE="$REPORTS_DIR/{project}-qa-oracle.lock"
LOCK_TIMEOUT=900

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    age=$(stat -f%Sm -t%s "$LOCK_FILE" 2>/dev/null || echo "0")
    [ $(($(date +%s) - age)) -lt "$LOCK_TIMEOUT" ] && return 1
  fi
  echo "$(date +%s)" > "$LOCK_FILE"
}

main() {
  log "=== QA Oracle START ==="
  acquire_lock || { log "SKIP: lock active"; exit 0; }
  python3 "$SCRIPTS_DIR/qa_runner.py" >> "$LOG_FILE" 2>&1 || true
  log "=== QA Oracle DONE ==="
}
main "$@"
SHELLEOF
  chmod +x "$PROJECT_DIR/scripts/qa/nightly-qa-oracle.sh"
  echo "✓ Created nightly-qa-oracle.sh"

  # LaunchAgent plist
  PLIST_PATH="$HOME/Library/LaunchAgents/com.burk.$PROJECT-qa-oracle.plist"
  cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.burk.$PROJECT-qa-oracle</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$PROJECT_DIR/scripts/qa/nightly-qa-oracle.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
  <key>WorkingDirectory</key><string>$QA_DIR</string>
</dict>
</plist>
PLIST_EOF
  launchctl load "$PLIST_PATH" 2>/dev/null || true
  echo "✓ LaunchAgent: $PLIST_PATH (runs 2 AM CT daily)"
fi

# ---- STEP 9: 30-min QA agent (periodic bug finder) ----
SPAWN_SCRIPT="$PROJECT_DIR/scripts/qa/spawn-qa-agent.sh"
cat >> "$SPAWN_SCRIPT" << QAAGENTEOF
#!/bin/bash
set -euo pipefail
PROJECT="{project}"
PROJECT_DIR="$PROJECT_ROOT"
SCRIPTS_DIR="\$PROJECT_DIR/scripts/qa"
REPORTS_DIR="/Users/jonathan/.openclaw/workspace/reports"
LOG_FILE="\$REPORTS_DIR/{project}-qa-agent.log"
STATUS_FILE="/Users/jonathan/.openclaw/workspace/mahoodles-dashboard/data/{project}-qa-agent-status.json"
LOCK_FILE="\$REPORTS_DIR/{project}-qa-agent.lock"
LOCK_TIMEOUT=1200

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

acquire_lock() {
  [ -f "$LOCK_FILE" ] && [ $(($(date +%s) - $(stat -f%Sm -t%s "$LOCK_FILE" 2>/dev/null || echo 0))) -lt "$LOCK_TIMEOUT" ] && return 1
  echo "$(date +%s)" > "$LOCK_FILE"
}

acquire_lock || { log "SKIP: QA agent still running"; exit 0; }
log "QA agent firing"
python3 "$QA_SCRIPT" >> "$LOG_FILE" 2>&1 || true
log "QA agent done"
QAAGENTEOF
chmod +x "$PROJECT_DIR/scripts/qa/spawn-qa-agent.sh"
echo "✓ 30-min QA agent script created"

# Install 30-min QA agent LaunchAgent
QA_AGENT_PLIST="$HOME/Library/LaunchAgents/com.burk.$PROJECT-qa-agent.plist"
cat > "$QA_AGENT_PLIST" << QA_PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.burk.$PROJECT-qa-agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$PROJECT_DIR/scripts/qa/spawn-qa-agent.sh</string>
  </array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$REPORTS_DIR/{project}-qa-agent.log</string>
  <key>StandardErrorPath</key><string>$REPORTS_DIR/{project}-qa-agent.log</string>
</dict>
</plist>
QA_PLIST_EOF
launchctl load "$QA_AGENT_PLIST" 2>/dev/null || true
echo "✓ 30-min QA agent LaunchAgent: $QA_AGENT_PLIST"
echo "  (fires every 30 min — files Plane tickets, no Discord noise on clean runs)"

# ---- SUMMARY ----
echo ""
echo "═══════════════════════════════════════════════"
echo "  ✓ SETUP COMPLETE — $PROJECT"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Project:    $PROJECT"
echo "  Root:       $PROJECT_ROOT"
echo "  Lock:       $LOCK_FILE"
echo "  Port:       $PORT"
echo "  Cron ID:    ${CRON_ID:-unknown}"
if [ "$WITH_QA" = true ]; then
  echo "  QA:         enabled ($QA_TYPE)"
  echo "  QA Oracle:  2:00 AM CT daily"
else
  echo "  QA:         not enabled (use --with-qa to add)"
fi
echo ""
echo "  To fire immediately (skip lock wait):"
echo "    echo '0' > $LOCK_FILE"
echo ""
echo "  To check executor status:"
echo "    ~/.openclaw/skills/autonomous-executor/scripts/executor.sh status"
echo ""
echo "  To trigger manually:"
echo "    openclaw cron trigger $CRON_ID"
echo ""
echo "  To remove the cron later:"
echo "    openclaw cron delete $CRON_ID"
echo ""
echo "  See docs/qa-delivery-annex.md for QA setup details"
echo "═══════════════════════════════════════════════"