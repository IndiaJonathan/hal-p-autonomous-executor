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
PLANE_PROJECT_ID="{PLANE_PROJECT_ID}" # e.g. 1612c33a-28de-4d76-bd82-d5022e88eddb
PLANE_WORKSPACE="mahoodles"
QA_SCRIPT="{QA_SCRIPT}"               # e.g. ~/Projects/poem-of-the-day/scripts/qa/qa_runner.py

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
# STEP 4b: Pull Plane tickets — inject QA-reported bugs into work queue
# ============================================================
# Get new/active bug tickets from Plane for this project.
# Any tickets filed by QA agents (bug hunters, design reviewers, code wardens)
# become priority work items in STATE.md.
#
# How it works:
#   1. Get service token from Plane container (inline, no stored secrets)
#   2. Fetch open issues from the project's Backlog + In Progress states
#   3. Compare against last known ticket list (stored in STATE.md or a ticket tracker file)
#   4. Any NEW tickets → add to STATE.md Blockers section with ticket URL
#   5. Mark them as "acknowledged" so we don't re-process them every cycle
#
# Ticket state tracking file: {PROJECT_ROOT}/.planning/qa-tickets.json
# Format: { "last_ticket_sync": "ISO timestamp", "known_tickets": ["id1", "id2", ...] }

PLANE_TOKEN=$(docker exec plane-app-api-1 python manage.py shell \
  -c "from plane.db.models import APIToken, User, Workspace; \
      u=User.objects.get(email='indiajonathan@gmail.com'); \
      w=Workspace.objects.get(slug='mahoodles'); \
      t=APIToken.objects.create(user=u, workspace=w, user_type=0, \
      is_service=True, description='GSD Executor', created_by=u, updated_by=u); \
      print(t.token)" 2>/dev/null)

if [ -n "$PLANE_TOKEN" ] && [ -n "$PLANE_PROJECT_ID" ]; then
  TICKET_TRACKER="$PROJECT_ROOT/.planning/qa-tickets.json"
  mkdir -p "$(dirname "$TICKET_TRACKER")"

  # Fetch open issues (Backlog + In Progress states)
  # Uses /issues/?state=backlog,in_progress&priority=urgent,high,medium
  PLANE_ISSUES=$(curl -sf -X GET \
    "https://plane.burk-dashboards.com/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PLANE_PROJECT_ID}/issues/?per_page=50" \
    -H "X-API-Key: ${PLANE_TOKEN}" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for issue in data.get('results', []):
        state = issue.get('state', '')
        title = issue.get('name', '')
        tid = issue.get('id', '')
        url = 'https://plane.burk-dashboards.com/mahoodles/projects/${PLANE_PROJECT_ID}/issues/' + tid
        priority = issue.get('priority', 'medium')
        print(f'TICKET|{tid}|{priority}|{title[:80]}|{url}')
except: pass
" 2>/dev/null || echo "")

  # Load known tickets from tracker
  KNOWN=""
  if [ -f "$TICKET_TRACKER" ]; then
    KNOWN=$(python3 -c "import json; d=json.load(open('$TICKET_TRACKER')); print(' '.join(d.get('known_tickets',[])))" 2>/dev/null || echo "")
  fi

  # For each Plane issue, check if it's new
  NEW_TICKETS=""
  for line in $(echo "$PLANE_ISSUES" | grep -v "^$"); do
    TID=$(echo "$line" | cut -d'|' -f2)
    PRIORITY=$(echo "$line" | cut -d'|' -f3)
    TITLE=$(echo "$line" | cut -d'|' -f4)
    URL=$(echo "$line" | cut -d'|' -f5)

    if ! echo "$KNOWN" | grep -q "$TID"; then
      NEW_TICKETS="${NEW_TICKETS}NEW_TICKET|${TID}|${PRIORITY}|${TITLE}|${URL}\n"
      echo "[$TIMESTAMP] New Plane ticket: [$PRIORITY] $TITLE — $URL" >> /tmp/executor.log
    fi
  done

  # If new tickets found, update STATE.md blockers + ticket tracker
  if [ -n "$NEW_TICKETS" ]; then
    echo "[$TIMESTAMP] New QA tickets detected — updating STATE.md..." >> /tmp/executor.log
    # Append to blockers section
    echo "" >> "$STATE_FILE"
    echo "## QA-Reported Tickets (auto-injected)" >> "$STATE_FILE"
    echo "$NEW_TICKETS" | while IFS='|' read -r _ tid priority title url; do
      echo "- [$priority] $title" >> "$STATE_FILE"
      echo "  URL: $url" >> "$STATE_FILE"
    done
    # Update tracker
    ALL_TICKETS=$(echo "$PLANE_ISSUES" | while IFS='|' read -r _ tid _ _ _; do echo "$tid"; done | sort -u | tr '\n' ' ')
    python3 -c "
import json, sys
 tracker = {'last_sync': '$(date -I)', 'known_tickets': sys.stdin.read().split()}
with open('$TICKET_TRACKER', 'w') as f:
    json.dump(tracker, f)
" <<< "$ALL_TICKETS"
  fi
fi

# ============================================================
# STEP 5: Check phase completion
# ============================================================
PHASE_GOAL=$(grep -A5 "## Phase $CURRENT_PHASE" "$ROADMAP_FILE" 2>/dev/null | grep "^**Goal:" | sed 's/.*Goal: *//' || echo "")
TOTAL_PHASES=$(grep -c "^## Phase" "$ROADMAP_FILE" 2>/dev/null || echo "unknown")

# ============================================================
# STEP 6: Decide what to do
# ============================================================
# Priority order:
# 1. QA-reported tickets (newest first, urgent > high > medium)
# 2. Phase blockers
# 3. Current phase next items
# 4. Phase advancement
# Decision tree:
# - If NEW_QA_TICKETS exist → work through them in priority order first
# - If BLOCKERS → DM human with exact blocker question, work around if possible
# - If Phase N done, Phase N+1 not started → start Phase N+1, DM "Phase N complete"
# - If Phase N in progress → find highest-priority next item and execute
# - If all phases complete → full completion summary, DM

# ============================================================
# STEP 7: Execute
# ============================================================
# For heavy multi-file work:
#   openclaw sessions spawn \
#     --runtime "acp" \
#     --agentId "main" \
#     --model "minimax/MiniMax-M2.7" \
#     --cwd "$PROJECT_ROOT" \
#     --runTimeoutSeconds 10800 \
#     --task "YOUR TASK HERE" \
#     --mode "run"
#
# NOTE: sessions_spawn REQUIRES --agentId "main" or acp.defaultAgent in config.

# For direct execution: write code → run tests → verify → commit → push

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
# - EXPO_PUBLIC_API_URL must be set BEFORE building the APK
# - APP_URL on backend must be set for magic link emails
# - Onboarding should end at Main screen, not Auth gate
# - APK download: serve via backend /download endpoint
# - See: docs/mobile-app-delivery-annex.md for full checklist

# ============================================================
# STEP 9: Discord alerts (DM 148191845040652288)
# ============================================================
#   ✅ Phase completion: "✅ Phase N COMPLETE — [brief summary]"
#   🚧 Blocker: "🚧 BLOCKER: [exact question]"
#   🔧 Backend restart: "🔧 Backend was down, restarted"
#   🎉 All done: "🎉 ALL PHASES COMPLETE! [full summary]"
#   🐛 QA ticket done: "Fixed QA ticket: [title] — [commit]"

# ============================================================
# STEP 10: Release lock
# ============================================================
echo "$(date +%s)" > "$LOCK_FILE"

echo "DONE — completed at $TIMESTAMP"