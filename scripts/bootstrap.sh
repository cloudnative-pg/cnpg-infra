#!/usr/bin/env bash
#
# Entry point for setting up a cloudnative-pg admin's local workspace.
# Clone this repo (cnpg-infra) as a sibling of every other managed repo —
# an otherwise-empty directory is fine, this script populates it — then run
# this script from inside cnpg-infra.
#
# What it does:
#   1. Confirms the authenticated `gh` user is an active member of the
#      `admins` team. This is a fail-fast sanity check, not the real
#      security boundary — GitHub's own API authorization is what actually
#      stops a non-admin from doing anything privileged, this just avoids
#      a confusing half-completed run before that happens.
#   2. Reads managed-repos.yaml and clones any repo listed there that
#      isn't already present as a sibling directory. Existing clones are
#      left completely alone (not pulled, not reset) — this only fills in
#      what's missing.
#
# Deliberately NOT run from CI/GitHub Actions: every script in this repo
# assumes a human, locally-authenticated `gh` session with real org-admin
# scope. Keeping that scope on a laptop instead of in a pipeline secret
# means a compromised workflow or malicious PR never has a path to
# org-wide admin access.
#
# Requires: gh (authenticated, `admin:org` + `repo` scopes — see
# `gh auth refresh -h github.com -s admin:org` if the team-membership
# check below fails with a scope error rather than a membership error),
# git, jq
set -uo pipefail

ORG="cloudnative-pg"
ADMIN_TEAM="admins"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$INFRA_ROOT/.." && pwd)"
MANIFEST="$INFRA_ROOT/generated/managed-repos.yaml"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

echo "=== Checking admin access ==="

login="$(gh api user --jq '.login' 2>/dev/null)"
if [ -z "$login" ]; then
  echo "error: could not determine the authenticated gh user — run 'gh auth login' first." >&2
  exit 1
fi

membership_state="$(gh api "orgs/${ORG}/teams/${ADMIN_TEAM}/memberships/${login}" --jq '.state' 2>/dev/null)"
if [ "$membership_state" != "active" ]; then
  echo "error: '$login' is not an active member of @${ORG}/${ADMIN_TEAM} — this workspace is for org admins only." >&2
  echo "       (if you believe this is wrong, confirm your gh token has 'read:org' scope and try again)" >&2
  exit 1
fi
echo "  ✓ $login is an active member of @${ORG}/${ADMIN_TEAM}"

echo
echo "=== Syncing sibling repos ==="

if [ ! -f "$MANIFEST" ]; then
  echo "error: $MANIFEST not found — run ./update-managed-repos.sh first to generate it." >&2
  exit 1
fi

mapfile -t REPO_NAMES < <(grep -E '^  - name: ' "$MANIFEST" | sed 's/^  - name: //')

cloned=0
skipped=0
for name in "${REPO_NAMES[@]}"; do
  if [ -d "$WORKSPACE_ROOT/$name/.git" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "  Cloning $name..."
  if git clone "https://github.com/${ORG}/${name}.git" "$WORKSPACE_ROOT/$name" >/dev/null 2>&1; then
    cloned=$((cloned + 1))
  else
    echo "  ✗ failed to clone $name" >&2
  fi
done

echo
echo "Done. $cloned repo(s) cloned, $skipped already present and left untouched."
