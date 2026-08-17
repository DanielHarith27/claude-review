#!/bin/bash
# Runs Claude Code review for a GitLab MR and posts results
# Called from .gitlab-ci.yml claude-review job
# Expects CI_* environment variables from GitLab CI

set -euo pipefail

# Resolve this script's own directory so the tool works from any path in any repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project-configurable knobs — override as CI/CD variables
JIRA_HOST="${JIRA_HOST:-xsolla.atlassian.net}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
# Extra git pathspecs excluded from the review diff. Space-separated, intentionally
# word-split below. Set to "" to review everything.
DIFF_EXCLUDES="${DIFF_EXCLUDES-:!vendor/}"

# Pre-flight checks — fail fast before expensive operations
if [ -z "${GITLAB_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: GITLAB_ACCESS_TOKEN is not set. Review cannot be posted."
  exit 1
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY is not set."
  exit 1
fi

# Isolated work directory — prevents /tmp race conditions with parallel jobs
# and limits exposure of Jira ticket content to other processes on the host
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export WORK_DIR  # passed to post-review.sh

# GitLab MR API endpoint (used throughout the script)
API_URL="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}"

# Pre-compute diff once — avoids each agent re-running git diff and fixes target branch hardcoding
# shellcheck disable=SC2086  # DIFF_EXCLUDES is deliberately word-split into pathspecs
git diff "origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}...HEAD" -- . $DIFF_EXCLUDES > "$WORK_DIR/diff.patch"
echo "Diff: $(wc -l < "$WORK_DIR/diff.patch") lines"

# Fetch correct start_sha from MR diff version (differs from base_sha for rebased MRs)
START_SHA=$(curl -s --max-time 10 --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
  "${API_URL}/versions?per_page=1" 2>/dev/null | jq -r '.[0].start_commit_sha // empty' 2>/dev/null || true)
START_SHA="${START_SHA:-${CI_MERGE_REQUEST_DIFF_BASE_SHA}}"
export START_SHA

# Fetch bot user ID once — used by skip_with_comment and thread collection
BOT_USER_ID=$(curl -s --max-time 10 --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
  "${CI_API_V4_URL}/user" 2>/dev/null | jq -r '.id // empty')
if [ -z "$BOT_USER_ID" ] || [ "$BOT_USER_ID" = "null" ]; then
  echo "ERROR: Could not resolve bot user ID. GITLAB_ACCESS_TOKEN may be invalid."
  exit 1
fi
export BOT_USER_ID

# Post a skip comment to the MR and exit (ticket quality gate)
# Reason string uses literal newlines (NL=$'\n') — no printf %b to avoid Jira title corruption
skip_with_comment() {
  local reason="$1"
  echo "=== Skipping review: ${reason} ==="
  # Delete existing skip comments before posting (dedup across pipeline retriggers)
  # Only delete notes authored by the current bot token (can't delete other users' notes)
  SKIP_NOTES=$(curl -s --max-time 10 --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
    "${API_URL}/notes?per_page=100" 2>/dev/null) || true
  if echo "$SKIP_NOTES" | jq -e 'type == "array"' > /dev/null 2>&1; then
    for OLD_ID in $(echo "$SKIP_NOTES" | jq -r \
        --argjson bot_id "$BOT_USER_ID" \
        '.[] | select(.author.id == $bot_id and (.body | contains("Claude Code Review — Skipped"))) | .id'); do
      curl -s -o /dev/null --max-time 10 --request DELETE \
        --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
        "${API_URL}/notes/${OLD_ID}" || true
      echo "  Deleted old skip comment ${OLD_ID}"
    done
  fi
  local NL=$'\n'
  local body
  body="<!-- claude-review -->${NL}⏭️ **Claude Code Review — Skipped**${NL}${NL}${reason}"
  jq -n --arg body "$body" '{"body": $body}' > "$WORK_DIR/skip_payload.json"
  HTTP_CODE=$(curl -s -o "$WORK_DIR/skip_resp.txt" -w "%{http_code}" \
    --max-time 15 \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
    --header "Content-Type: application/json" \
    --data @"$WORK_DIR/skip_payload.json" \
    "${API_URL}/notes") || true
  echo "  Skip comment HTTP ${HTTP_CODE:-unknown}: $(cat "$WORK_DIR/skip_resp.txt" 2>/dev/null | head -1)"
  exit 0
}

# Extract Jira ticket from MR description (Closes PROJ-1234) or branch name
# || true: grep exits 1 when no match — must not trigger set -e
TICKET=$(echo "$CI_MERGE_REQUEST_DESCRIPTION" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)
if [ -z "$TICKET" ]; then
  TICKET=$(echo "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)
fi

# Gate 1: no ticket referenced
if [ -z "$TICKET" ]; then
  skip_with_comment "No Jira ticket referenced in the MR description or branch name."$'\n\n'"Add the ticket key to the MR description (e.g. \`Closes PROJ-1234\`) or name your branch \`PROJ-1234-description\`."
fi

# Gate 2: Jira credentials not configured
if [ -z "${JIRA_API_TOKEN:-}" ] || [ -z "${JIRA_USERNAME:-}" ]; then
  skip_with_comment "Jira credentials not configured (\`JIRA_API_TOKEN\` or \`JIRA_USERNAME\` CI/CD variable missing). Cannot validate ticket \`${TICKET}\`."
fi

# Fetch ticket from Jira — credentials via netrc (avoids exposure in /proc/PID/cmdline)
echo "Fetching Jira ticket: $TICKET"
printf 'machine %s login %s password %s\n' "$JIRA_HOST" "$JIRA_USERNAME" "$JIRA_API_TOKEN" > "$WORK_DIR/.netrc"
chmod 600 "$WORK_DIR/.netrc"
JIRA_RESPONSE=$(curl -s --max-time 20 --netrc-file "$WORK_DIR/.netrc" \
  "https://${JIRA_HOST}/rest/api/3/issue/$TICKET?fields=summary,description,comment" 2>/dev/null) || true

# Gate 3: ticket not found
if ! echo "$JIRA_RESPONSE" | jq -e '.key' > /dev/null 2>&1; then
  skip_with_comment "Ticket \`${TICKET}\` not found in Jira. Check the ticket key or Jira credentials."
fi

# sed trim instead of xargs — xargs crashes on apostrophes ("user's") and can inject shell metacharacters
JIRA_SUMMARY=$(echo "$JIRA_RESPONSE" | jq -r '.fields.summary // empty' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Gate 4: ticket quality — extract all text from description ADF recursively
JIRA_DESC_TEXT=$(echo "$JIRA_RESPONSE" | jq -r '[.fields.description // {} | .. | .text? // empty] | join(" ")' 2>/dev/null || echo "")
DESC_LEN=${#JIRA_DESC_TEXT}

QUALITY_ISSUES=""
if [ "$DESC_LEN" -lt 150 ]; then
  QUALITY_ISSUES="${QUALITY_ISSUES}"$'\n'"- **Description too short** (${DESC_LEN} chars). Add context: what problem is being solved, what changes are proposed."
fi

# Check for AC/DoD in text — also check ADF node types since Jira native task lists
# don't emit "- [" prefix in extracted text, only raw task item text
HAS_AC_TEXT=false
if echo "$JIRA_DESC_TEXT" | grep -qiE '(acceptance criteria|AC:|criteria:|definition of done|\bDOD\b|\- \[|\* \[)'; then
  HAS_AC_TEXT=true
fi
HAS_TASKLIST=$(echo "$JIRA_RESPONSE" | \
  jq -r '[(.fields.description // {}) | .. | objects | select(.type == "taskItem")] | length' \
  2>/dev/null || echo 0)
if [ "$HAS_AC_TEXT" = false ] && [ "${HAS_TASKLIST:-0}" -eq 0 ]; then
  QUALITY_ISSUES="${QUALITY_ISSUES}"$'\n'"- **No Acceptance Criteria** found. Add an AC or DoD section describing what must be true for this ticket to be done."
fi

if [ -n "$QUALITY_ISSUES" ]; then
  skip_with_comment "Ticket \`${TICKET}\` — **${JIRA_SUMMARY}** — does not meet quality requirements:${QUALITY_ISSUES}"$'\n\n'"Fix the ticket description and re-run the pipeline."
fi

# Ticket passed quality gates — build context file for Claude
JIRA_DESC=$(echo "$JIRA_RESPONSE" | jq -r '[.fields.description // {} | .. | .text? // empty] | join("\n")' 2>/dev/null | head -200)
JIRA_COMMENTS=$(echo "$JIRA_RESPONSE" | jq -r '
  [.fields.comment.comments[]? | {
    author: .author.displayName,
    body: ([.body // {} | .. | .text? // empty] | join(" "))
  }] | .[-10:][] | "\(.author): \(.body)"
' 2>/dev/null | head -200)
{
  echo "Ticket: ${TICKET}"
  echo "Summary: ${JIRA_SUMMARY}"
  echo ""
  echo "Description:"
  echo "$JIRA_DESC"
  if [ -n "$JIRA_COMMENTS" ]; then
    echo ""
    echo "Comments:"
    echo "$JIRA_COMMENTS"
  fi
} > "$WORK_DIR/jira_context.txt"
JIRA_CONTEXT="Jira ticket context saved to ${WORK_DIR}/jira_context.txt — read it for ticket alignment."
echo "Jira context loaded: $TICKET — $JIRA_SUMMARY ($(echo "$JIRA_RESPONSE" | jq '.fields.comment.total // 0') comments)"

# Collect existing Claude review threads for dedup and resolution
echo "=== Fetching existing review threads ==="
echo "Bot user ID: ${BOT_USER_ID}"

echo '[]' > "$WORK_DIR/existing_threads.json"
echo '[]' > "$WORK_DIR/pending_replies.json"
echo '[]' > "$WORK_DIR/human_threads.json"
PAGE=1
while [ "$PAGE" -le 50 ]; do
  DISC_PAGE=$(curl -s --max-time 10 --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
    "${API_URL}/discussions?per_page=100&page=${PAGE}") || break
  echo "$DISC_PAGE" | jq -e 'type == "array"' > /dev/null 2>&1 || break
  [ "$(echo "$DISC_PAGE" | jq 'length')" = "0" ] && break
  # Only collect threads started by bot with claude-review marker (avoids pollution from other automations)
  echo "$DISC_PAGE" | jq --argjson bot_id "$BOT_USER_ID" '[
    .[] | select(.notes[0].author.id == $bot_id and (.notes[0].body | contains("<!-- claude-review -->")))
    | {
        discussion_id: .id,
        file: (.notes[0].position.new_path // null),
        line: (.notes[0].position.new_line // null),
        title: ((.notes[0].body // "") | [capture("— \\*\\*(?<t>[^*]+)\\*\\*"), capture("\\*\\*(?<t>[^*]+)\\*\\*")] | map(.t // empty) | first // ""),
        resolved: (if .notes[0].resolved == true then true else false end)
      }
  ]' > "$WORK_DIR/disc_page.json" 2>/dev/null
  jq -s 'add // []' "$WORK_DIR/existing_threads.json" "$WORK_DIR/disc_page.json" > "$WORK_DIR/merged.json"
  mv "$WORK_DIR/merged.json" "$WORK_DIR/existing_threads.json"
  # Collect threads where a developer replied and bot hasn't responded yet (only claude-review threads)
  echo "$DISC_PAGE" | jq --argjson bot_id "$BOT_USER_ID" '[
    .[] | select(
      .notes[0].author.id == $bot_id
      and (.notes[0].body | contains("<!-- claude-review -->"))
      and (.notes | length > 1)
      and (.notes[-1].author.id != $bot_id)
      and (if .notes[0].resolved == true then false else true end)
    )
    | {
        discussion_id: .id,
        file: (.notes[0].position.new_path // null),
        line: (.notes[0].position.new_line // null),
        conversation: [.notes[] | {author: .author.username, body: .body}]
      }
  ]' > "$WORK_DIR/reply_page.json" 2>/dev/null
  jq -s 'add // []' "$WORK_DIR/pending_replies.json" "$WORK_DIR/reply_page.json" > "$WORK_DIR/merged_replies.json"
  mv "$WORK_DIR/merged_replies.json" "$WORK_DIR/pending_replies.json"
  # Extract human-opened threads as context (avoid duplicating developer-raised issues)
  echo "$DISC_PAGE" | jq --argjson bot_id "$BOT_USER_ID" '[
    .[] | select(.notes[0].author.id != $bot_id and (.notes[0].system // false) == false)
    | {
        file: (.notes[0].position.new_path // null),
        line: (.notes[0].position.new_line // null),
        author: .notes[0].author.username,
        body: .notes[0].body,
        resolved: (if .notes[0].resolved == true then true else false end)
      }
  ]' > "$WORK_DIR/human_threads_page.json" 2>/dev/null
  jq -s 'add // []' "$WORK_DIR/human_threads.json" "$WORK_DIR/human_threads_page.json" > "$WORK_DIR/human_threads_merged.json"
  mv "$WORK_DIR/human_threads_merged.json" "$WORK_DIR/human_threads.json"
  PAGE=$((PAGE + 1))
done
THREAD_COUNT=$(jq 'length' "$WORK_DIR/existing_threads.json")
REPLY_COUNT=$(jq 'length' "$WORK_DIR/pending_replies.json")
HUMAN_THREAD_COUNT=$(jq 'length' "$WORK_DIR/human_threads.json")
echo "Found ${THREAD_COUNT} Claude review threads, ${REPLY_COUNT} with pending replies, ${HUMAN_THREAD_COUNT} human threads (context)"

# Collect standalone human MR notes as read-only context for Claude
# Claude reads these to avoid raising findings already discussed by developers
# general_replies is always [] — Claude does not respond to standalone notes
echo '[]' > "$WORK_DIR/human_notes.json"
NOTES_PAGE_NUM=1
while [ "$NOTES_PAGE_NUM" -le 20 ]; do
  NOTES_PAGE=$(curl -s --max-time 10 --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN}" \
    "${API_URL}/notes?per_page=100&page=${NOTES_PAGE_NUM}") || break
  echo "$NOTES_PAGE" | jq -e 'type == "array"' > /dev/null 2>&1 || break
  [ "$(echo "$NOTES_PAGE" | jq 'length')" = "0" ] && break
  echo "$NOTES_PAGE" | jq --argjson bot_id "$BOT_USER_ID" '[
    .[] | select(.author.id != $bot_id and .system == false and (.author.bot != true))
    | {note_id: .id, author: .author.username, body: .body}
  ]' > "$WORK_DIR/human_notes_page.json" 2>/dev/null
  jq -s 'add // []' "$WORK_DIR/human_notes.json" "$WORK_DIR/human_notes_page.json" > "$WORK_DIR/human_notes_merged.json"
  mv "$WORK_DIR/human_notes_merged.json" "$WORK_DIR/human_notes.json"
  NOTES_PAGE_NUM=$((NOTES_PAGE_NUM + 1))
done
HUMAN_NOTE_COUNT=$(jq 'length' "$WORK_DIR/human_notes.json")
echo "Found ${HUMAN_NOTE_COUNT} human notes (context only, no replies)"

# Runtime copies of agent config and prompt with $WORK_DIR paths and model substituted
# (review-prompt.md and review-agents.json use /tmp/ paths and __MODEL__ as templates)
sed -e "s|/tmp/|${WORK_DIR}/|g" -e "s|__MODEL__|${CLAUDE_MODEL}|g" \
  "$SCRIPT_DIR/review-agents.json" > "$WORK_DIR/review-agents.json"
sed -e "s|/tmp/|${WORK_DIR}/|g" -e "s|__MODEL__|${CLAUDE_MODEL}|g" \
  "$SCRIPT_DIR/review-prompt.md" > "$WORK_DIR/review-prompt.md"

# Build prompt — MR metadata only; diff injected as file to avoid injection via MR title
PROMPT=$(printf 'Review MR !%s (%s -> %s). %s. Diff pre-computed at %s/diff.patch — read that file instead of running git diff. Read %s/existing_threads.json for previous findings; include fixed ones in resolved_findings, skip still-open ones. Read %s/pending_replies.json for threads needing bot reply. Dispatch all review sub-agents in parallel, compile findings into the JSON report.' \
  "$CI_MERGE_REQUEST_IID" \
  "$TICKET" \
  "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" \
  "$JIRA_CONTEXT" \
  "$WORK_DIR" \
  "$WORK_DIR" \
  "$WORK_DIR")

# Scale max-turns for large diffs, many changed files, or many review threads
DIFF_LINES=$(wc -l < "$WORK_DIR/diff.patch")
DIFF_FILES=$(grep -c '^diff --git' "$WORK_DIR/diff.patch" 2>/dev/null || echo 0)
THREAD_TOTAL=$((THREAD_COUNT + REPLY_COUNT + HUMAN_THREAD_COUNT))
MAX_TURNS=23
if [ "$DIFF_LINES" -gt 500 ] || [ "$DIFF_FILES" -gt 30 ] || [ "$THREAD_TOTAL" -gt 15 ]; then
  MAX_TURNS=35
fi
echo "Max turns: ${MAX_TURNS} (diff: ${DIFF_LINES} lines, files: ${DIFF_FILES}, threads: ${THREAD_TOTAL})"

# Run Claude Code review with structured JSON output
# --model sets orchestrator model; per-agent model in review-agents.json sets sub-agent model
CLAUDE_EXIT=0
claude \
  -p "$PROMPT" \
  --bare \
  --model "$CLAUDE_MODEL" \
  --permission-mode dontAsk \
  --allowedTools "Read" "Grep" "Glob" "Bash(git log *)" "Bash(git show *)" "Agent" \
  --agents "$(cat "$WORK_DIR/review-agents.json")" \
  --append-system-prompt-file "$WORK_DIR/review-prompt.md" \
  --json-schema "$(cat "$SCRIPT_DIR/review-schema.json")" \
  --output-format json \
  --max-turns $MAX_TURNS \
  --max-budget-usd 5.00 \
  > "$WORK_DIR/claude_raw.json" 2>"$WORK_DIR/claude_errors.txt" || CLAUDE_EXIT=$?

if [ $CLAUDE_EXIT -ne 0 ]; then
  echo "=== Claude exited with code $CLAUDE_EXIT ==="
  echo "=== stderr ==="
  cat "$WORK_DIR/claude_errors.txt" 2>/dev/null
  echo "=== stdout ==="
  cat "$WORK_DIR/claude_raw.json" 2>/dev/null
  exit $CLAUDE_EXIT
fi

# Extract review JSON from CLI envelope (.structured_output field)
# With --json-schema, the review is in .structured_output (not .result)
jq '.structured_output' "$WORK_DIR/claude_raw.json" > "$WORK_DIR/claude_review.json" 2>/dev/null

echo "=== Review JSON ==="
jq '.' "$WORK_DIR/claude_review.json"

# Post inline comments (guard against null structured_output)
if [ -s "$WORK_DIR/claude_review.json" ] \
    && jq empty "$WORK_DIR/claude_review.json" 2>/dev/null \
    && [ "$(jq -r 'type' "$WORK_DIR/claude_review.json" 2>/dev/null)" != "null" ]; then
  echo "=== Posting inline review comments ==="
  bash "$SCRIPT_DIR/post-review.sh" "$WORK_DIR/claude_review.json"
else
  echo "WARNING: Could not extract structured_output, posting raw result as note"
  BODY=$(jq -r '.result // .structured_output // empty' "$WORK_DIR/claude_raw.json" 2>/dev/null)
  if [ -n "$BODY" ]; then
    jq -n --arg body "$BODY" '{"body": $body}' > "$WORK_DIR/payload.json"
    curl -s -o /dev/null -w "HTTP %{http_code}" \
      --max-time 15 \
      --request POST \
      --header "PRIVATE-TOKEN: ${GITLAB_ACCESS_TOKEN:-}" \
      --header "Content-Type: application/json" \
      --data @"$WORK_DIR/payload.json" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/notes" || true
  fi
fi
