#!/usr/bin/env bats
# tests/update-pr-branches.bats — Unit tests for scripts/update-pr-branches.sh
#
# Dependencies: bats-core (https://github.com/bats-core/bats-core)
#   macOS:   brew install bats-core
#   Ubuntu:  sudo apt-get install bats
#   or:      npm install -g bats
#
# Run locally from the repo root:
#   bats tests/update-pr-branches.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/update-pr-branches.sh"

# ------------------------------------------------------------------------------
# setup / teardown
# ------------------------------------------------------------------------------

setup() {
  # Create a temp bin dir and put a fake 'gh' in it.
  FAKE_BIN=$(mktemp -d)
  export PATH="$FAKE_BIN:$PATH"

  # Write the fake gh stub. Behavior is controlled by env vars:
  #   FAKE_GH_PAGINATE_RESPONSE  — JSON returned for --paginate calls
  #   FAKE_GH_PR_<N>_RESPONSE    — JSON returned for individual PR #N fetch
  #   FAKE_GH_PR_<N>_FAIL        — set to 1 to make individual PR #N fetch fail
  #   FAKE_GH_UPDATE_STATUS      — HTTP status code for update-branch calls (default 202)
  #   FAKE_GH_UPDATE_BODY        — JSON body for update-branch calls
  cat > "$FAKE_BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --paginate "* ]]; then
  echo "${FAKE_GH_PAGINATE_RESPONSE:-[]}"
  exit 0
fi

if [[ " $* " == *" --method PUT "* ]]; then
  STATUS="${FAKE_GH_UPDATE_STATUS:-202}"
  BODY="${FAKE_GH_UPDATE_BODY:-{\"message\":\"Updating pull request branch.\"}}"
  printf 'HTTP/1.1 %s OK\r\n\r\n%s\n' "$STATUS" "$BODY"
  exit 0
fi

# Individual PR detail fetch — extract PR number from the URL argument.
URL=""
for arg in "$@"; do
  case "$arg" in repos/*) URL="$arg" ;; esac
done
PR_NUM=$(echo "$URL" | grep -oE '/pulls/[0-9]+$' | grep -oE '[0-9]+')
FAIL_VAR="FAKE_GH_PR_${PR_NUM}_FAIL"
if [ "${!FAIL_VAR:-0}" = "1" ]; then
  echo "API error" >&2
  exit 1
fi
RESP_VAR="FAKE_GH_PR_${PR_NUM}_RESPONSE"
DEFAULT="{\"number\":$PR_NUM,\"state\":\"open\",\"draft\":false,\"mergeable_state\":\"clean\",\"base\":{\"ref\":\"main\"}}"
echo "${!RESP_VAR:-$DEFAULT}"
EOF
  chmod +x "$FAKE_BIN/gh"

  # Default env vars consumed by the script.
  export REPO="test-org/test-repo"
  export TARGET_BASE="main"
  export GITHUB_SERVER_URL="https://github.com"
  # Unset GH_TOKEN so tests don't accidentally use a real token.
  unset GH_TOKEN || true
}

teardown() {
  rm -rf "$FAKE_BIN"
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------

@test "exits 0 and reports nothing-to-do when there are no open PRs" {
  export FAKE_GH_PAGINATE_RESPONSE='[]'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 0 non-draft open PRs"* ]]
  [[ "$output" == *"Nothing to do"* ]]
}

@test "skips PRs that are not behind (mergeable_state=clean)" {
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":10,"title":"feat","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_10_RESPONSE='{"number":10,"state":"open","draft":false,"mergeable_state":"clean"}'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"mergeable_state='clean', skipping"* ]]
  [[ "$output" == *"0 updated"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "updates a PR whose mergeable_state is behind and exits 0" {
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":42,"title":"fix","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_42_RESPONSE='{"number":42,"state":"open","draft":false,"mergeable_state":"behind"}'
  export FAKE_GH_UPDATE_STATUS="202"
  export FAKE_GH_UPDATE_BODY='{"message":"Updating pull request branch."}'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Updating PR #42"* ]]
  [[ "$output" == *"✓ PR #42"* ]]
  [[ "$output" == *"1 updated"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "skips a draft PR even if the bulk list returned it" {
  # The bulk list filters drafts via jq, but the double-check re-fetch also
  # guards against a PR becoming a draft between list and fetch.
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":7,"title":"wip","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_7_RESPONSE='{"number":7,"state":"open","draft":true,"mergeable_state":"behind"}'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"became a draft, skipping"* ]]
  [[ "$output" == *"0 updated"* ]]
}

@test "skips PR when individual detail fetch fails — non-fatal" {
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":99,"title":"bad","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_99_FAIL=1

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to fetch details, skipping"* ]]
  [[ "$output" == *"0 updated"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "treats HTTP 409 from update-branch as a skip, not a failure" {
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":55,"title":"409","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_55_RESPONSE='{"number":55,"state":"open","draft":false,"mergeable_state":"behind"}'
  export FAKE_GH_UPDATE_STATUS="409"
  export FAKE_GH_UPDATE_BODY='{"message":"Already up-to-date."}'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"update not needed or not allowed (HTTP 409)"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "counts unexpected HTTP status as a failure and exits 1" {
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":77,"title":"err","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_77_RESPONSE='{"number":77,"state":"open","draft":false,"mergeable_state":"behind"}'
  export FAKE_GH_UPDATE_STATUS="500"
  export FAKE_GH_UPDATE_BODY='{"message":"Internal Server Error"}'

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ PR #77"* ]]
  [[ "$output" == *"1 failed"* ]]
}

@test "skips PRs not targeting TARGET_BASE" {
  export FAKE_GH_PAGINATE_RESPONSE='[{"number":11,"title":"feature","draft":false,"base":{"ref":"feature-branch"}},{"number":12,"title":"main PR","draft":false,"base":{"ref":"main"}}]'
  export FAKE_GH_PR_12_RESPONSE='{"number":12,"state":"open","draft":false,"mergeable_state":"behind"}'
  export TARGET_BASE="main"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"targeting 'feature-branch', not 'main', skipping"* ]]
  [[ "$output" == *"Updating PR #12"* ]]
  [[ "$output" == *"1 updated"* ]]
}

@test "updates multiple behind PRs in a single run" {
  export FAKE_GH_PAGINATE_RESPONSE='[
    {"number":101,"title":"a","draft":false,"base":{"ref":"main"}},
    {"number":102,"title":"b","draft":false,"base":{"ref":"main"}}
  ]'
  export FAKE_GH_PR_101_RESPONSE='{"number":101,"state":"open","draft":false,"mergeable_state":"behind"}'
  export FAKE_GH_PR_102_RESPONSE='{"number":102,"state":"open","draft":false,"mergeable_state":"behind"}'
  export FAKE_GH_UPDATE_STATUS="202"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ PR #101"* ]]
  [[ "$output" == *"✓ PR #102"* ]]
  [[ "$output" == *"2 updated"* ]]
}
