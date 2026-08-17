#!/bin/bash
# Posts Claude review findings as inline GitLab MR discussions
# Usage: post-review.sh <review.json>

set -euo pipefail

REVIEW_FILE="${1:?Usage: post-review.sh <review.json>}"
API_URL="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}"
BASE_SHA="${CI_MERGE_REQUEST_DIFF_BASE_SHA}"
HEAD_SHA="${CI_COMMIT_SHA}"
# START_SHA exported by run-review.sh; falls back to base_sha for standalone runs
START_SHA="${START_SHA:-${CI_MERGE_REQUEST_DIFF_BASE_SHA}}"

# Auth header (Project Access Token required)
if [ -z "${GITLAB_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: GITLAB_ACCESS_TOKEN is not set. Add it as a CI/CD variable."
  exit 1
fi
AUTH_HEADER="PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN"
MARKER="<!-- claude-review -->"
# Use WORK_DIR exported by run-review.sh; fall back to /tmp when run standalone
WORK_DIR="${WORK_DIR:-/tmp}"

# ── Resolve fixed findings ──
RESOLVED_COUNT=$(jq '.resolved_findings | length // 0' "$REVIEW_FILE")
echo "=== Resolving ${RESOLVED_COUNT} fixed findings ==="
JUST_RESOLVED=0
if [ "$RESOLVED_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((RESOLVED_COUNT - 1))); do
    DISC_ID=$(jq -r ".resolved_findings[$i]" "$REVIEW_FILE")
    if ! echo "$DISC_ID" | grep -qE '^[0-9a-f]{40}$'; then
      echo "  WARN: Invalid discussion ID format, skipping: ${DISC_ID}"
      continue
    fi
    echo "  Resolving discussion ${DISC_ID}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 15 \
      --request PUT \
      --header "$AUTH_HEADER" \
      --header "Content-Type: application/json" \
      --data '{"resolved": true}' \
      "${API_URL}/discussions/${DISC_ID}") || true
    if [ "${HTTP_CODE:-0}" -ge 200 ] && [ "${HTTP_CODE:-0}" -lt 300 ] 2>/dev/null; then
      JUST_RESOLVED=$((JUST_RESOLVED + 1))
    else
      echo "  Resolution failed for ${DISC_ID} (HTTP ${HTTP_CODE:-unknown})"
    fi
  done
fi

# ── Post thread replies ──
REPLY_COUNT=$(jq '.thread_replies | length // 0' "$REVIEW_FILE")
echo "=== Posting ${REPLY_COUNT} thread replies ==="
REPLIED_THREADS=0
if [ "$REPLY_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((REPLY_COUNT - 1))); do
    DISC_ID=$(jq -r ".thread_replies[$i].discussion_id" "$REVIEW_FILE")
    if ! echo "$DISC_ID" | grep -qE '^[0-9a-f]{40}$'; then
      echo "  WARN: Invalid discussion ID format, skipping: ${DISC_ID}"
      continue
    fi
    REPLY_BODY=$(jq -r ".thread_replies[$i].body" "$REVIEW_FILE")
    jq -n --arg body "$REPLY_BODY" '{"body": $body}' > "$WORK_DIR/reply_payload.json"
    echo "  Replying to discussion ${DISC_ID}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 15 \
      --request POST \
      --header "$AUTH_HEADER" \
      --header "Content-Type: application/json" \
      --data @"$WORK_DIR/reply_payload.json" \
      "${API_URL}/discussions/${DISC_ID}/notes") || true
    if [ "${HTTP_CODE:-0}" -ge 200 ] && [ "${HTTP_CODE:-0}" -lt 300 ] 2>/dev/null; then
      REPLIED_THREADS=$((REPLIED_THREADS + 1))
    else
      echo "  Reply failed (HTTP ${HTTP_CODE:-unknown})"
    fi
  done
fi

# ── Post general replies to standalone human MR notes ──
# note_id is included in the marker for future dedup; general_replies is currently always []
GENERAL_REPLY_COUNT=$(jq '.general_replies | length // 0' "$REVIEW_FILE")
echo "=== Posting ${GENERAL_REPLY_COUNT} general replies ==="
REPLIED_GENERAL=0
if [ "$GENERAL_REPLY_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((GENERAL_REPLY_COUNT - 1))); do
    REPLY_BODY=$(jq -r ".general_replies[$i].body" "$REVIEW_FILE")
    NOTE_ID=$(jq -r ".general_replies[$i].note_id // \"unknown\"" "$REVIEW_FILE")
    # Embed reply-to marker (for potential future dedup; general_replies is currently always [])
    REPLY_BODY_MARKED="${REPLY_BODY}
<!-- reply-to: ${NOTE_ID} -->"
    jq -n --arg body "$REPLY_BODY_MARKED" '{"body": $body}' > "$WORK_DIR/general_reply_payload.json"
    echo "  Posting general reply (re: note ${NOTE_ID})"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 15 \
      --request POST \
      --header "$AUTH_HEADER" \
      --header "Content-Type: application/json" \
      --data @"$WORK_DIR/general_reply_payload.json" \
      "${API_URL}/notes") || true
    if [ "${HTTP_CODE:-0}" -ge 200 ] && [ "${HTTP_CODE:-0}" -lt 300 ] 2>/dev/null; then
      REPLIED_GENERAL=$((REPLIED_GENERAL + 1))
    else
      echo "  General reply failed (HTTP ${HTTP_CODE:-unknown})"
    fi
  done
fi

# ── Get bot user ID and delete old summary notes ──
# Reuse BOT_USER_ID exported by run-review.sh; fetch only when run standalone
if [ -z "${BOT_USER_ID:-}" ]; then
  BOT_USER_ID=$(curl -s --max-time 10 --header "$AUTH_HEADER" \
    "${CI_API_V4_URL}/user" | jq -r '.id // empty') || true
fi
echo "Bot user ID: ${BOT_USER_ID}"

if [ -z "$BOT_USER_ID" ] || [ "$BOT_USER_ID" = "null" ] \
    || ! printf '%s' "$BOT_USER_ID" | grep -qE '^[0-9]+$'; then
  echo "WARNING: Could not resolve bot user ID; skipping old-note cleanup."
else
PAGE=1
while [ "$PAGE" -le 50 ]; do
  RESP=$(curl -s --max-time 10 --header "$AUTH_HEADER" \
    "${API_URL}/notes?per_page=100&page=${PAGE}") || break
  echo "$RESP" | jq -e 'type == "array"' > /dev/null 2>&1 || break
  [ "$(echo "$RESP" | jq 'length')" = "0" ] && break
  # Delete only standalone summary notes (type==null). GitLab /notes returns both standalone notes
  # and DiffNote inline thread notes — deleting a DiffNote destroys the thread while leaving a
  # dangling discussion_id in existing_threads.json that Claude keeps referencing but is gone in UI.
  for OLD_ID in $(echo "$RESP" | jq -r --argjson bot_id "$BOT_USER_ID" --arg marker "$MARKER" \
    '.[] | select(.author.id == $bot_id and (.body | contains($marker)) and (.type == null or .type == "")) | .id'); do
    echo "  Replacing old summary note ${OLD_ID}"
    curl -s -o /dev/null --max-time 10 --request DELETE --header "$AUTH_HEADER" \
      "${API_URL}/notes/${OLD_ID}" || true
  done
  PAGE=$((PAGE + 1))
done
fi # end BOT_USER_ID check

post_api() {
  local endpoint="$1"
  local payload_file="$2"
  HTTP_CODE=$(curl -s -o "$WORK_DIR/api_resp.txt" -w "%{http_code}" \
    --max-time 15 \
    --request POST \
    --header "$AUTH_HEADER" \
    --header "Content-Type: application/json" \
    --data @"$payload_file" \
    "${API_URL}${endpoint}") || true
  if [ "${HTTP_CODE:-0}" -ge 200 ] && [ "${HTTP_CODE:-0}" -lt 300 ] 2>/dev/null; then
    return 0
  else
    echo "  API error (HTTP ${HTTP_CODE:-unknown}): $(cat "$WORK_DIR/api_resp.txt" 2>/dev/null)"
    return 1
  fi
}

# Extract data from review JSON
SUMMARY=$(jq -r '.summary // "No summary"' "$REVIEW_FILE")
VERDICT=$(jq -r '.verdict // "Unknown"' "$REVIEW_FILE")
FINDING_COUNT=$(jq '.findings | length // 0' "$REVIEW_FILE")

echo "=== Review: ${VERDICT} (${FINDING_COUNT} findings) ==="
echo "Summary: ${SUMMARY}"

# Post each finding as inline discussion
POSTED=0
POSTED_INLINE=0
FAILED=0
if [ "$FINDING_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((FINDING_COUNT - 1))); do
    SEVERITY=$(jq -r ".findings[$i].severity" "$REVIEW_FILE")
    FILE=$(jq -r ".findings[$i].file" "$REVIEW_FILE")
    LINE=$(jq -r ".findings[$i].line" "$REVIEW_FILE")
    # Validate LINE is numeric — non-numeric crashes --argjson and kills the script
    if ! printf '%s' "$LINE" | grep -qE '^[0-9]+$'; then
      echo "  WARN: Invalid line value '$LINE' for finding $i, posting as regular note"
      LINE=""
    fi
    TITLE=$(jq -r ".findings[$i].title" "$REVIEW_FILE")
    MESSAGE=$(jq -r ".findings[$i].message" "$REVIEW_FILE")
    FIX=$(jq -r ".findings[$i].fix // empty" "$REVIEW_FILE")

    # Severity emoji
    case "$SEVERITY" in
      critical) EMOJI="🔴" ;;
      warning)  EMOJI="🟡" ;;
      suggestion) EMOJI="💡" ;;
      *) EMOJI="ℹ️" ;;
    esac

    # Build comment body (marker for identification)
    NL=$'\n'
    BODY="${MARKER}${NL}${EMOJI} **${TITLE}**${NL}${NL}${MESSAGE}"
    if [ -n "$FIX" ]; then
      BODY="${BODY}${NL}${NL}**Fix:** ${FIX}"
    fi

    echo "  Posting [$SEVERITY] $FILE:$LINE — $TITLE"

    INLINE_OK=false
    if [ -n "$LINE" ]; then
      # Try inline discussion first (only if LINE is valid)
      jq -n \
        --arg body "$(printf '%s' "$BODY")" \
        --arg base_sha "$BASE_SHA" \
        --arg start_sha "$START_SHA" \
        --arg head_sha "$HEAD_SHA" \
        --arg new_path "$FILE" \
        --arg old_path "$FILE" \
        --argjson new_line "$LINE" \
        '{
          "body": $body,
          "position": {
            "base_sha": $base_sha,
            "start_sha": $start_sha,
            "head_sha": $head_sha,
            "position_type": "text",
            "old_path": $old_path,
            "new_path": $new_path,
            "new_line": $new_line
          }
        }' > "$WORK_DIR/discussion_payload.json"

      if post_api "/discussions" "$WORK_DIR/discussion_payload.json"; then
        POSTED=$((POSTED + 1))
        POSTED_INLINE=$((POSTED_INLINE + 1))
        INLINE_OK=true
      fi
    fi

    if [ "$INLINE_OK" = false ]; then
      # Fallback: post as regular note (line not valid or not in diff)
      echo "  Inline failed, posting as regular note..."
      FALLBACK_BODY="${MARKER}${NL}${EMOJI} **${FILE}:${LINE}** — **${TITLE}**${NL}${NL}${MESSAGE}"
      if [ -n "$FIX" ]; then
        FALLBACK_BODY="${FALLBACK_BODY}${NL}${NL}**Fix:** ${FIX}"
      fi
      jq -n --arg body "$(printf '%s' "$FALLBACK_BODY")" \
        '{"body": $body}' > "$WORK_DIR/note_payload.json"
      if post_api "/notes" "$WORK_DIR/note_payload.json"; then
        POSTED=$((POSTED + 1))
      else
        FAILED=$((FAILED + 1))
      fi
    fi
  done
fi

# Post summary note with per-agent breakdown
VERDICT_EMOJI=""
case "$VERDICT" in
  "LGTM") VERDICT_EMOJI="✅" ;;
  "Needs attention") VERDICT_EMOJI="⚠️" ;;
  "Blocking issues") VERDICT_EMOJI="🔴" ;;
esac

PROD_READY=$(jq -r '.production_readiness // "—"' "$REVIEW_FILE")

# Render one line per agent summary, whatever the roster is. The agent roster lives in
# review-agents.json only — do not hardcode agent names here.
AGENT_REPORTS=$(jq -r '
  (.agent_summaries // {}) | to_entries
  | map("**" + ((.key[0:1] | ascii_upcase) + (.key[1:] | gsub("_"; " "))) + ":** " + .value)
  | join("\n\n")
' "$REVIEW_FILE")

NL=$'\n'
SUMMARY_BODY="${MARKER}${NL}${VERDICT_EMOJI} **Claude Code Review — ${VERDICT}**${NL}${NL}${SUMMARY}${NL}${NL}"
SUMMARY_BODY="${SUMMARY_BODY}🚀 **Production Readiness:** ${PROD_READY}${NL}${NL}"
if [ -n "$AGENT_REPORTS" ]; then
  SUMMARY_BODY="${SUMMARY_BODY}### Agent Reports${NL}${NL}${AGENT_REPORTS}${NL}${NL}"
fi
# Count total open threads: existing unresolved - just resolved + newly posted
EXISTING_OPEN=$(jq '[.[] | select(.resolved == false)] | length' "$WORK_DIR/existing_threads.json" 2>/dev/null || echo 0)
TOTAL_OPEN=$(( EXISTING_OPEN - JUST_RESOLVED + POSTED_INLINE ))
[ "$TOTAL_OPEN" -lt 0 ] && TOTAL_OPEN=0

SUMMARY_BODY="${SUMMARY_BODY}---${NL}📊 **${POSTED}** new findings posted, **${TOTAL_OPEN}** total open threads"
if [ "$JUST_RESOLVED" -gt 0 ]; then
  SUMMARY_BODY="${SUMMARY_BODY}, ${JUST_RESOLVED} resolved"
fi
if [ "$REPLIED_THREADS" -gt 0 ]; then
  SUMMARY_BODY="${SUMMARY_BODY}, ${REPLIED_THREADS} thread replies"
fi
if [ "$REPLIED_GENERAL" -gt 0 ]; then
  SUMMARY_BODY="${SUMMARY_BODY}, ${REPLIED_GENERAL} general replies"
fi

jq -n --arg body "$(printf '%s' "$SUMMARY_BODY")" '{"body": $body}' > "$WORK_DIR/summary_payload.json"
post_api "/notes" "$WORK_DIR/summary_payload.json" || echo "WARNING: Failed to post summary note"
echo ""
echo "Done: ${POSTED} posted, ${REPLIED_THREADS} thread replies, ${REPLIED_GENERAL} general replies, ${TOTAL_OPEN} open threads, ${JUST_RESOLVED} resolved, ${FAILED} failed"
