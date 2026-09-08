#!/usr/bin/env bash
#
# Lands the .gitvote.yml render-gitvote-config.sh computes for one repo
# in gitvote-policy.yaml, if the live file differs.
#
# Unlike fix-repo-settings.sh (which PATCHes repo settings directly via
# the API), .gitvote.yml is a file checked into each repo's own git
# history, so "fixing" it means a real commit. This script never uses a
# local clone -- it reads and writes the file entirely through the GitHub
# Contents API, the same way create-new-repo.sh lands a new repo's
# CODEOWNERS and its cloudnative-pg/.project PR.
#
# For every managed repo except cnpg-infra itself, that means opening a
# PR (branch + commit + gh pr create) -- a target repo's own branch
# ruleset requires review, same as landing a rendered CODEOWNERS file
# (see this repo's CLAUDE.md). cnpg-infra is the one documented exception
# (repo-policy.yaml's ruleset_bypass_teams, this repo's own CLAUDE.md: "do
# not open PRs against this repo, push directly to main") -- for it alone,
# this script commits straight to the default branch.
#
# governance is excluded entirely (gitvote-policy.yaml's excluded: true)
# -- its .gitvote.yml is maintained directly in that repo, not from here.
# This script refuses to touch it even if invoked directly.
#
# Requires: gh (authenticated, write access to the target repo -- admin
# not needed, this only ever touches file contents and PRs), jq
#
# Usage:
#   ./fix-gitvote-config.sh <repo-name>            # dry run: show proposed diff only
#   ./fix-gitvote-config.sh <repo-name> --apply    # actually land the change
set -uo pipefail

unset CLICOLOR_FORCE
unset GH_FORCE_TTY

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$INFRA_ROOT/generated/managed-repos.yaml"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# shellcheck source=./render-gitvote-config.sh
source "$(dirname "${BASH_SOURCE[0]}")/render-gitvote-config.sh"

repo="${1:-}"
apply=false
[ "${2:-}" = "--apply" ] && apply=true

if [ -z "$repo" ]; then
  echo "usage: $0 <repo-name> [--apply]" >&2
  exit 1
fi

if [ -f "$MANIFEST" ] && ! grep -q "^  - name: ${repo}\$" "$MANIFEST"; then
  echo "error: '$repo' is not in managed-repos.yaml -- refusing to touch a repo outside the managed scope." >&2
  exit 1
fi

excluded="$(gitvote_policy_excluded "$repo")"
if [ "$excluded" = "true" ]; then
  reason="$(gitvote_policy_reason "$repo")"
  echo "'$repo' is marked excluded in gitvote-policy.yaml -- refusing to touch it."
  echo "Reason: $reason"
  exit 0
fi

category="$(gitvote_policy_category "$repo")"
expected="$(render_gitvote_config "$repo" "$category")"

full="${ORG}/${repo}"
repo_json="$(gh api "repos/$full" 2>/dev/null)"
if [ -z "$repo_json" ] || [ "$(echo "$repo_json" | jq -r 'length')" = "0" ]; then
  echo "error: could not read repos/$full (not found, or no access)" >&2
  exit 1
fi
default_branch="$(echo "$repo_json" | jq -r '.default_branch')"

existing_json="$(gh api "repos/$full/contents/.gitvote.yml?ref=$default_branch" 2>/dev/null)"
existing_sha="$(echo "$existing_json" | jq -r '.sha // empty' 2>/dev/null)"
actual=""
[ -n "$existing_sha" ] && actual="$(gh api "repos/$full/contents/.gitvote.yml?ref=$default_branch" -H "Accept: application/vnd.github.raw" 2>/dev/null)"

normalize() { tr -d '\r' | sed 's/[[:space:]]*$//'; }

echo "=== $full  (default branch: $default_branch) ==="
echo "Category: ${category:-default}"
echo

if [ -n "$existing_sha" ] && [ "$(echo "$actual" | normalize)" = "$(echo "$expected" | normalize)" ]; then
  echo "(nothing to do -- .gitvote.yml already matches policy)"
  exit 0
fi

direct_push=false
[ "$repo" = "cnpg-infra" ] && direct_push=true

if [ -n "$existing_sha" ]; then
  echo "Existing .gitvote.yml differs from policy. Diff (- live, + policy):"
  diff -u <(echo "$actual") <(echo "$expected") | tail -n +3
else
  echo "No .gitvote.yml on $default_branch yet. Will create:"
  echo "$expected" | sed 's/^/  + /'
fi
echo

if [ "$direct_push" = "true" ]; then
  echo "cnpg-infra's own ruleset_bypass_teams exception (repo-policy.yaml, CLAUDE.md) applies:"
  echo "  will commit directly to $default_branch, not open a PR."
else
  echo "Will open a PR against $full (branch chore/gitvote-config -> $default_branch)."
fi
echo

if [ "$apply" != "true" ]; then
  echo "Dry run only -- re-run with --apply to make this change."
  exit 0
fi

author_name="$(git config --get user.name 2>/dev/null)"
author_email="$(git config --get user.email 2>/dev/null)"
if [ -z "$author_name" ] || [ -z "$author_email" ]; then
  echo "error: git config user.name/user.email must be set to build a DCO-compliant commit." >&2
  exit 1
fi

msg="chore: sync .gitvote.yml with cnpg-infra policy

See cloudnative-pg/cnpg-infra's gitvote-policy.yaml and
scripts/render-gitvote-config.sh for how this file is generated.

Signed-off-by: ${author_name} <${author_email}>

Assisted-by: Claude"

b64="$(echo "$expected" | base64)"

echo "Applying..."

if [ "$direct_push" = "true" ]; then
  args=(-f message="$msg" -f content="$b64" -f branch="$default_branch")
  [ -n "$existing_sha" ] && args+=(-f sha="$existing_sha")
  if gh api -X PUT "repos/$full/contents/.gitvote.yml" "${args[@]}" >/dev/null; then
    echo "  done: committed .gitvote.yml directly to $default_branch"
  else
    echo "  failed to commit .gitvote.yml to $default_branch"
    exit 1
  fi
else
  branch="chore/gitvote-config"
  base_sha="$(gh api "repos/$full/git/refs/heads/$default_branch" --jq '.object.sha' 2>/dev/null)"
  gh api "repos/$full/git/refs" -f ref="refs/heads/$branch" -f sha="$base_sha" >/dev/null 2>&1
  branch_sha="$(gh api "repos/$full/contents/.gitvote.yml?ref=$branch" --jq '.sha' 2>/dev/null)"
  [ -z "$branch_sha" ] && branch_sha="$existing_sha"

  args=(-f message="$msg" -f content="$b64" -f branch="$branch")
  [ -n "$branch_sha" ] && args+=(-f sha="$branch_sha")
  if gh api -X PUT "repos/$full/contents/.gitvote.yml" "${args[@]}" >/dev/null; then
    echo "  committed to $branch"
    pr_url="$(gh pr create --repo "$full" --base "$default_branch" --head "$branch" \
      --title "chore: sync .gitvote.yml with cnpg-infra policy" \
      --body "Rendered from cloudnative-pg/cnpg-infra's gitvote-policy.yaml. See that repo's scripts/render-gitvote-config.sh for how this is generated.

Assisted-by: Claude" 2>&1)"
    echo "  PR: $pr_url"
  else
    echo "  failed to commit .gitvote.yml to $branch"
    exit 1
  fi
fi

echo
echo "Done. Re-run ./check-gitvote-config.sh $repo to verify."
