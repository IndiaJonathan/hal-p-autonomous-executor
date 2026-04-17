# Autonomous Executor — HAL-P Task Prompt Template
# Usage: paste this into openclaw cron create --message

# VARIABLES (substitute per project)
PROJECT_ROOT="{PROJECT_ROOT}"         # e.g. /Users/jonathan/Projects/poem-of-the-day
LOCK_FILE="{LOCK_FILE}"              # e.g. /Users/jonathan/.openclaw/workspace/reports/poem-gsd.lock
STATE_FILE="{PROJECT_ROOT}/.planning/STATE.md"
ROADMAP_FILE="{PROJECT_ROOT}/.planning/ROADMAP.md"
MEMORY_FILE="/Users/jonathan/.openclaw/workspace/memory/$(date +%Y-%m-%d).md"
HEALTH_URL="http://localhost:{PORT}/health"   # e.g. http://localhost:3003/health
GIT_DIR="{PROJECT_ROOT}"

# TIMESTAMP
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")

# ============================================================
# STEP 1: Lock check
# ============================================================
NOW=$(date +%s)
LOCK_AGE=$(stat -f%Sm -t%s "$LOCK_FILE" 2>/dev/null || echo "0")
AGE=$((NOW - LOCK_AGE))
LOCK_TIMEOUT=600    # 10 min — stale means safe to run

if [ "$AGE" -lt "$LOCK_TIMEOUT" ]; then
  echo "DONE — executor still active (lock age: ${AGE}s)"
  exit 0
fi

# ============================================================
# STEP 2: Acquire lock
# ============================================================
echo "$NOW" > "$LOCK_FILE"

# ============================================================
# STEP 3: Health check + self-heal
# ============================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "200" ]; then
  echo "[$TIMESTAMP] Backend DOWN (HTTP $HTTP_CODE), restarting..." >> /tmp/health-check.log
  cd "$PROJECT_ROOT" && docker compose up -d
  sleep 5
  # DM Discord: backend restart
  echo "🔧 Backend was down (HTTP $HTTP_CODE), restarted automatically."
fi

# ============================================================
# STEP 4: Survey state
# ============================================================
echo "[$TIMESTAMP] Executor waking — checking state..." >> /tmp/executor.log

CURRENT_PHASE=$(grep -m1 "Current phase:" "$STATE_FILE" 2>/dev/null | sed 's/.*phase: *//' | tr -d '* ' || echo "unknown")
LAST_UPDATED=$(grep -m1 "Last updated:" "$STATE_FILE" 2>/dev/null | sed 's/.*updated: *//' || echo "unknown")
BLOCKERS=$(grep -A5 "## Blockers" "$STATE_FILE" 2>/dev/null | grep -v "Blockers" | grep -v "^$" | head -5 || echo "None")
LAST_COMMIT_MSG=$(git -C "$GIT_DIR" log -1 --oneline 2>/dev/null | cut -d' ' -f2- || echo "no commits")
CURRENT_COMMIT=$(git -C "$GIT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")

# ============================================================
# STEP 5: Check phase completion
# ============================================================
# Read ROADMAP to see what the current phase's goal is
PHASE_GOAL=$(grep -A5 "## Phase $CURRENT_PHASE" "$ROADMAP_FILE" 2>/dev/null | grep "^**Goal:" | sed 's/.*Goal: *//' || echo "")
TOTAL_PHASES=$(grep -c "^## Phase" "$ROADMAP_FILE" 2>/dev/null || echo "unknown")

# If we just finished the last item in the current phase → phase complete
# Detect by checking if all "checklist" items from ROADMAP phase are done
# (simplified: check if STATE.md phase marker changed since last commit)

# ============================================================
# STEP 6: Decide what to do
# ============================================================
# Decision tree:
# - If BLOCKERS → DM human with exact blocker question, work around if possible
# - If backend was down → report restart (already captured above)
# - If Phase N done, Phase N+1 not started → start Phase N+1, DM "Phase N complete"
# - If Phase N in progress → find highest-priority next item and execute
# - If all phases complete → full completion summary, DM

# ============================================================
# STEP 7: Execute
# ============================================================
# For heavy multi-file work (spawn Claude Code with sessions_spawn):
#   openclaw sessions spawn \
#     --runtime "acp" \
#     --agentId "main" \
#     --model "minimax/MiniMax-M2.7" \
#     --cwd "$PROJECT_ROOT" \
#     --runTimeoutSeconds 10800 \
#     --task "YOUR TASK HERE" \
#     --mode "run"
#
# NOTE: sessions_spawn REQUIRES --agentId "main" or acp.defaultAgent set in config.
# Without it, all spawn attempts fail: "spawn_failed — Failed to spawn agent command: main"

# For direct execution: write code → run tests → verify → commit → push
# cd $PROJECT_ROOT/apps/backend
# npm run build && npm run test

# ============================================================
# STEP 8: After work
# ============================================================
# git -C "$GIT_DIR" add -A
# git -C "$GIT_DIR" commit -m "feat: description $(date '+%Y-%m-%d %H:%M')"
# git -C "$GIT_DIR" push

# Update STATE.md:
# - Mark current phase
# - Update last updated timestamp
# - Log what was completed

# Save memory:
# cat >> "$MEMORY_FILE" << EOF
# ## $TIMESTAMP
# - Completed: [what you did]
# - Phase: [N]
# - Next: [what comes next]
# EOF

---
# APP DELIVERY REMINDERS (if building a mobile app)
# - EXPO_PUBLIC_API_URL must be set BEFORE building the APK: export EXPO_PUBLIC_API_URL=https://your-domain.com
# - After APK build: verify bundle has no localhost refs: python3 -c "import zipfile,re..."
# - APP_URL on backend must be set for magic link emails (not localhost)
# - Cloudflared tunnel config: update ingress rule if backend port changes
# - Onboarding should end at Main screen, not Auth gate
# - APK download: serve via backend /download endpoint, not GitHub releases
# - See: docs/mobile-app-delivery-annex.md for full checklist

# ============================================================
# STEP 9: Discord alerts (DM 148191845040652288 for important events)
# ============================================================
# Send Discord DM for:
#   ✅ Phase completion: "✅ Phase N COMPLETE — [brief summary]
#      Moving to Phase N+1: [next goal]"
#   🚧 Blocker found: "🚧 BLOCKER: [exact question, what I tried, what I need]"
#   🔧 Backend restart: "🔧 Backend was down, restarted automatically"
#   🎉 All done: "🎉 ALL PHASES COMPLETE!
#      [full summary of what shipped]"

# ============================================================
# STEP 10: Release lock
# ============================================================
echo "$(date +%s)" > "$LOCK_FILE"

echo "DONE — completed at $TIMESTAMP"
