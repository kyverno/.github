#!/usr/bin/env bash
# update-pr-branches.sh — Find open PRs that are behind their base branch and
# trigger GitHub's built-in branch-update mechanism for each one.
#
# Required env vars:
#   REPO                  — owner/name, e.g. "kyverno/kyverno"
#   GH_TOKEN              — token with contents:write + pull-requests:write
#                           (picked up automatically by the gh CLI)
#
# Optional env vars:
#   TARGET_BASE           — only update PRs targeting this branch;
#                           empty = update PRs regardless of base branch
#   GITHUB_SERVER_URL     — defaults to "https://github.com" (GHE support)
#
# Exit codes:
#   0 — success (even if some PRs were skipped)
#   1 — one or more unexpected API failures occurred

set -euo pipefail

: "${REPO:?REPO env var is required (e.g. owner/name)}"

GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

# Derive GH_HOST for GitHub Enterprise compatibility.
GH_HOST="${GITHUB_SERVER_URL#https://}"
GH_HOST="${GH_HOST#http://}"
export GH_HOST

echo "Repository : $REPO"
echo "Base branch: ${TARGET_BASE:-(any)}"
echo ""

# ------------------------------------------------------------------------------
# Step 1 — Fetch all non-draft open PRs (bulk endpoint only returns "unknown"
# for mergeable_state, so we only keep the minimum fields needed here).
# ------------------------------------------------------------------------------
PR_LIST_FILE=$(mktemp)
gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
  | jq -s 'add // [] | map(select(.draft == false)) | map({number, title, base_ref: .base.ref})' \
  > "$PR_LIST_FILE"

TOTAL=$(jq length "$PR_LIST_FILE")
echo "Found $TOTAL non-draft open PRs"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  echo "Nothing to do."
  rm -f "$PR_LIST_FILE"
  exit 0
fi

UPDATED=0
SKIPPED=0
FAILED=0

# ------------------------------------------------------------------------------
# Step 2 — For each PR, re-fetch the full record to get reliable mergeable_state.
# ------------------------------------------------------------------------------
while IFS= read -r pr_json; do
  PR_NUMBER=$(echo "$pr_json" | jq -r '.number')
  PR_BASE=$(echo "$pr_json" | jq -r '.base_ref')

  # Skip PRs that don't target the requested base branch.
  if [ -n "${TARGET_BASE:-}" ] && [ "$PR_BASE" != "$TARGET_BASE" ]; then
    echo "  - PR #$PR_NUMBER — targeting '$PR_BASE', not '$TARGET_BASE', skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Fetch the full PR record; non-fatal on error.
  DETAILS_FILE=$(mktemp)
  if ! gh api \
       -H "Accept: application/vnd.github+json" \
       "repos/$REPO/pulls/$PR_NUMBER" \
       > "$DETAILS_FILE" 2>&1; then
    echo "  - PR #$PR_NUMBER — failed to fetch details, skipping"
    rm -f "$DETAILS_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if ! jq -e . >/dev/null 2>&1 < "$DETAILS_FILE"; then
    echo "  - PR #$PR_NUMBER — invalid JSON from details fetch, skipping"
    rm -f "$DETAILS_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  MERGEABLE_STATE=$(jq -r '.mergeable_state // empty' "$DETAILS_FILE")
  PR_STATE=$(jq -r '.state // empty' "$DETAILS_FILE")
  PR_DRAFT=$(jq -r '.draft // false' "$DETAILS_FILE")
  rm -f "$DETAILS_FILE"

  # Double-check still open + non-draft (may have changed since bulk fetch).
  if [ "$PR_STATE" != "open" ]; then
    echo "  - PR #$PR_NUMBER — no longer open, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ "$PR_DRAFT" = "true" ]; then
    echo "  - PR #$PR_NUMBER — became a draft, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ "$MERGEABLE_STATE" != "behind" ]; then
    echo "  - PR #$PR_NUMBER — mergeable_state='${MERGEABLE_STATE:-unknown}', skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # ----------------------------------------------------------------------------
  # Step 3 — Call GitHub's update-branch endpoint.
  # Branch on HTTP status code (stable contract), not response message text.
  # ----------------------------------------------------------------------------
  echo "Updating PR #$PR_NUMBER..."

  RESPONSE_FILE=$(mktemp)
  gh api \
    --include \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "repos/$REPO/pulls/$PR_NUMBER/update-branch" \
    > "$RESPONSE_FILE" 2>&1 || true

  STATUS_CODE=$(grep -m1 -E '^HTTP/' "$RESPONSE_FILE" | awk '{print $2}' || echo "")
  RESPONSE_BODY=$(awk 'BEGIN{body=0} body{print} /^(\r)?$/{body=1}' "$RESPONSE_FILE")

  if echo "$RESPONSE_BODY" | jq -e . >/dev/null 2>&1; then
    MSG=$(echo "$RESPONSE_BODY" | jq -r '.message // empty')
  else
    MSG=$(cat "$RESPONSE_FILE")
  fi
  rm -f "$RESPONSE_FILE"

  case "$STATUS_CODE" in
    202|204)
      echo "  ✓ PR #$PR_NUMBER — branch update scheduled (HTTP $STATUS_CODE)${MSG:+: $MSG}"
      UPDATED=$((UPDATED + 1))
      ;;
    409|422)
      # 409 = already up-to-date; 422 = fork / maintainer update not allowed.
      echo "  - PR #$PR_NUMBER — update not needed or not allowed (HTTP $STATUS_CODE)${MSG:+: $MSG}"
      SKIPPED=$((SKIPPED + 1))
      ;;
    *)
      echo "  ✗ PR #$PR_NUMBER — unexpected response (HTTP ${STATUS_CODE:-unknown})${MSG:+: $MSG}"
      FAILED=$((FAILED + 1))
      ;;
  esac

done < <(jq -c '.[]' "$PR_LIST_FILE")

rm -f "$PR_LIST_FILE"

echo ""
echo "Summary: $UPDATED updated, $SKIPPED skipped, $FAILED failed (of $TOTAL non-draft open PRs)"

[ "$FAILED" -eq 0 ] || exit 1
