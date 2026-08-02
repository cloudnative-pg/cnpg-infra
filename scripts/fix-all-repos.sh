#!/usr/bin/env bash
#
# Convenience wrapper: runs fix-repo-settings.sh across every repo in
# managed-repos.yaml, one at a time. Same safety model as the single-repo
# script — defaults to dry-run for every repo, only applies anything when
# --apply is passed, and each repo still only ever gets its settings
# raised, never lowered.
#
# This does NOT add any new logic of its own — it's a loop around
# fix-repo-settings.sh, so anything true of that script (ruleset-based
# enforcement, class-driven floors, the automated-category exemption,
# description sync) is true here for every repo.
#
# Requires: same as fix-repo-settings.sh (gh, jq), plus that script itself
#
# Usage:
#   ./fix-all-repos.sh              # dry run every repo, print each diff
#   ./fix-all-repos.sh --apply      # apply every repo's diff
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$INFRA_ROOT/generated/managed-repos.yaml"
FIX_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/fix-repo-settings.sh"

apply_flag=""
[ "${1:-}" = "--apply" ] && apply_flag="--apply"

[ -f "$MANIFEST" ] || { echo "error: $MANIFEST not found — run ./update-managed-repos.sh first" >&2; exit 1; }

mapfile -t REPOS < <(grep -E '^  - name: ' "$MANIFEST" | sed 's/^  - name: //')

echo "Running fix-repo-settings.sh across ${#REPOS[@]} repos${apply_flag:+ (--apply: changes WILL be made)}..." >&2
echo >&2

changed_repos=()
unchanged_count=0

for repo in "${REPOS[@]}"; do
  echo "############################################################"
  output="$("$FIX_SCRIPT" "$repo" $apply_flag 2>&1)"
  echo "$output"
  echo
  if echo "$output" | grep -q "nothing to do"; then
    unchanged_count=$((unchanged_count + 1))
  else
    changed_repos+=("$repo")
  fi
done

echo "############################################################"
echo
echo "Summary: ${#REPOS[@]} repos checked, $unchanged_count already at baseline, ${#changed_repos[@]} with changes${apply_flag:+ applied}."
if [ "${#changed_repos[@]}" -gt 0 ]; then
  echo "Repos with changes: ${changed_repos[*]}"
fi
if [ -z "$apply_flag" ] && [ "${#changed_repos[@]}" -gt 0 ]; then
  echo
  echo "Dry run only — re-run with --apply to make these changes across all of them,"
  echo "or run ./fix-repo-settings.sh <repo> --apply one at a time to review each first."
fi
