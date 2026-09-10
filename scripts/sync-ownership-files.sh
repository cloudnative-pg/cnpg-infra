#!/usr/bin/env bash
#
# Writes a repo's generated ownership files into its local sibling clone:
#
#   CODEOWNERS           rendered from componentowners-policy.yaml
#                        (scripts/render-codeowners.rb)
#   COMPONENT_OWNERS.md  rendered from repo-tiers.yaml's `owners:`
#                        (scripts/render-component-owners.rb)
#   CONTRIBUTORS.md      rendered from repo-tiers.yaml's `contributors:`
#                        (scripts/render-contributors.rb) -- only for a repo
#                        that has any; skipped everywhere else
#
# Both renderers only ever printed to stdout, which left "write it into
# the clone, commit, open a PR" as a manual step done by hand every time
# (see CLAUDE.md's "Landing a rendered CODEOWNERS file in a target
# repo"). This script does the write half of that, into the working tree
# of the sibling clone, and stops there: it never commits, never pushes,
# and never touches GitHub. The human opens the PR, which is also what
# keeps the target repo's own review gate in front of the change.
#
# Requires: ruby. No gh, no network -- everything here is local.
#
# Usage:
#   ./sync-ownership-files.sh <repo-name>            # dry run: show the diff
#   ./sync-ownership-files.sh <repo-name> --apply    # write the files
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$INFRA_ROOT/generated/managed-repos.yaml"

command -v ruby >/dev/null 2>&1 || { echo "error: ruby is required" >&2; exit 1; }

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

clone="$INFRA_ROOT/../$repo"
if [ ! -d "$clone/.git" ]; then
  echo "error: no sibling clone at $clone -- run ./scripts/bootstrap.sh first." >&2
  exit 1
fi

echo "=== $repo  ($clone) ==="
echo

changed=false

# $1 = filename in the target clone, $2 = renderer script, $3 = human label
render_one() {
  local target="$clone/$1" renderer="$2" label="$3"
  local rendered status tmp

  rendered="$(ruby "$INFRA_ROOT/scripts/$renderer" "$repo" 2>&1)"
  status=$?
  if [ $status -ne 0 ]; then
    # A renderer refusing to render is normal, not a failure of this run:
    # a documented CODEOWNERS exception, or a repo with no owners yet.
    echo "--- $1: skipped"
    echo "    $rendered"
    echo
    return 0
  fi

  if [ -f "$target" ] && [ "$rendered" = "$(cat "$target")" ]; then
    echo "--- $1: already up to date"
    echo
    return 0
  fi

  changed=true
  echo "--- $1: $([ -f "$target" ] && echo "would be updated ($label)" || echo "would be created ($label)")"
  tmp="$(mktemp)"
  printf '%s\n' "$rendered" > "$tmp"
  if [ -f "$target" ]; then
    diff -u --label "a/$1" "$target" --label "b/$1" "$tmp"
  else
    diff -u --label "a/$1" /dev/null --label "b/$1" "$tmp"
  fi
  echo

  if [ "$apply" = "true" ]; then
    mv "$tmp" "$target"
    echo "  ✓ wrote $target"
    echo
  else
    rm -f "$tmp"
  fi
}

render_one "CODEOWNERS" "render-codeowners.rb" "componentowners-policy.yaml"
render_one "COMPONENT_OWNERS.md" "render-component-owners.rb" "repo-tiers.yaml"
# Expected to skip on most repos: only a repo with a `contributors:` entry
# gets a CONTRIBUTORS.md at all, rather than 35 empty files across the org.
render_one "CONTRIBUTORS.md" "render-contributors.rb" "repo-tiers.yaml"

if [ "$changed" = "false" ]; then
  echo "(nothing to do -- both files already match policy)"
  exit 0
fi

if [ "$apply" != "true" ]; then
  echo "Dry run only -- re-run with --apply to write these files."
  exit 0
fi

cat <<EOF
Files written to the working tree only. Nothing is committed, pushed, or
sent to GitHub. To land them, from $clone:

  git switch -c dev/sync-ownership-files
  git add CODEOWNERS COMPONENT_OWNERS.md
  git commit -s -m "chore: sync ownership files with cnpg-infra policy"
  gh pr create

Add an 'Assisted-by:' trailer if a model helped, separated from
'Signed-off-by:' by a blank line, per governance/AI_POLICY.md.
EOF
