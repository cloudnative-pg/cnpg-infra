#!/usr/bin/env bash
#
# One command to reconcile a single repo with every policy file here, after
# any change to repo-tiers.yaml, componentowners-policy.yaml, people.yaml,
# repo-policy.yaml, labels-policy.yaml or milestones-policy.yaml. In order:
#
#   1. validate-policy.rb              (aborts everything if it fails)
#   2. sync-project-owner-teams.sh     <repo>-owners team membership
#   3. sync-reviewer-grants.rb         direct Write grants for Reviewers
#   4. fix-repo-settings.sh            ruleset, teams, description
#   5. sync-labels.rb                  issue labels
#   6. sync-milestones.rb              horizon milestones
#   7. sync-ownership-files.sh         CODEOWNERS, COMPONENT_OWNERS.md,
#                                      CONTRIBUTORS.md, .gitvote.yml and issue
#                                      templates into the sibling clone
#
# No new logic: each step is the script of that name, with the same safety
# model. Dry-run by default for every step; --apply passes --apply to every
# step. A failing step does not stop the later ones (they are independent),
# but the exit status is non-zero and the summary names what failed.
# The milestones step is skipped for a repo milestones-policy.yaml does not
# name, since sync-milestones.rb exits 1 for one.
#
# What this cannot do: step 7 stops at the working tree. Commit and open a
# PR in the target repo yourself (fetch first, branch from origin/main).
#
# Requires: gh, jq, ruby, and whatever the individual scripts need.
#
# Usage:
#   ./sync-repo.sh <repo>            # dry run of every step
#   ./sync-repo.sh <repo> --apply    # apply every step
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo=""
apply_flag=""
for arg in "$@"; do
  if [ "$arg" = "--apply" ]; then
    apply_flag="--apply"
  else
    repo="$arg"
  fi
done
[ -n "$repo" ] || { echo "usage: $0 <repo-name> [--apply]" >&2; exit 1; }

echo "== validate-policy.rb"
if ! ruby "$SCRIPTS/validate-policy.rb"; then
  echo "error: policy validation failed, nothing was run" >&2
  exit 1
fi

failed=()
run_step() { # $1 = label, rest = command
  local label="$1"
  shift
  echo
  echo "== $label${apply_flag:+ (--apply)}"
  "$@" || failed+=("$label")
}

run_step sync-project-owner-teams "$SCRIPTS/sync-project-owner-teams.sh" "$repo" $apply_flag
run_step sync-reviewer-grants ruby "$SCRIPTS/sync-reviewer-grants.rb" "$repo" $apply_flag
run_step fix-repo-settings "$SCRIPTS/fix-repo-settings.sh" "$repo" $apply_flag
run_step sync-labels ruby "$SCRIPTS/sync-labels.rb" "$repo" $apply_flag
if grep -Eq "^[[:space:]]*-[[:space:]]+\"?${repo//./\\.}\"?[[:space:]]*$" "$SCRIPTS/../milestones-policy.yaml"; then
  run_step sync-milestones ruby "$SCRIPTS/sync-milestones.rb" "$repo" $apply_flag
else
  echo
  echo "== sync-milestones: skipped, $repo is not in milestones-policy.yaml"
fi
run_step sync-ownership-files "$SCRIPTS/sync-ownership-files.sh" "$repo" $apply_flag

echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "Summary: ${#failed[@]} step(s) reported a failure: ${failed[*]}" >&2
else
  echo "Summary: every step succeeded."
fi
if [ -z "$apply_flag" ]; then
  echo "Dry run only. Re-run with --apply to make these changes."
else
  echo "Next: in $repo, git fetch origin, branch from origin/main, commit the generated files, open a PR."
fi
[ "${#failed[@]}" -eq 0 ]
