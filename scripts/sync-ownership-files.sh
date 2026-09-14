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
#   .github/ISSUE_TEMPLATE/*.yml
#                        copied verbatim from cloudnative-pg/.github's
#                        default branch, but ONLY into a repo that already
#                        has templates of its own, since those are exactly
#                        the repos GitHub stops serving the org-wide ones to
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

# GitHub serves the org-wide issue templates in cloudnative-pg/.github only
# to repos that have no `.github/ISSUE_TEMPLATE/` of their own. A repo with
# even one template of its own stops inheriting all of them, silently, so
# every org-wide template has to be copied in for those repos or the
# process it describes is simply unavailable there.
copy_org_templates() {
  local org_repo="$INFRA_ROOT/../.github" target_dir="$clone/.github/ISSUE_TEMPLATE"
  local name content tmp

  [ "$repo" = ".github" ] && return 0
  if [ ! -d "$org_repo/.git" ]; then
    echo "--- org issue templates: skipped"
    echo "    no sibling clone of cloudnative-pg/.github to copy from"
    echo
    return 0
  fi
  if [ ! -d "$target_dir" ]; then
    echo "--- org issue templates: not needed"
    echo "    this repo has no ISSUE_TEMPLATE of its own, so it inherits the org-wide ones"
    echo
    return 0
  fi

  git -C "$org_repo" fetch -q origin 2>/dev/null
  while read -r path; do
    [ -z "$path" ] && continue
    name="$(basename "$path")"
    [ "$name" = "config.yml" ] && continue
    content="$(git -C "$org_repo" show "origin/main:$path" 2>/dev/null)"
    [ -z "$content" ] && continue

    if [ -f "$target_dir/$name" ] && [ "$content" = "$(cat "$target_dir/$name")" ]; then
      echo "--- .github/ISSUE_TEMPLATE/$name: already up to date"
      echo
      continue
    fi

    changed=true
    echo "--- .github/ISSUE_TEMPLATE/$name: $([ -f "$target_dir/$name" ] && echo "would be updated" || echo "would be copied") (cloudnative-pg/.github)"
    tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    if [ -f "$target_dir/$name" ]; then
      diff -u --label "a/$name" "$target_dir/$name" --label "b/$name" "$tmp"
    else
      diff -u --label "a/$name" /dev/null --label "b/$name" "$tmp"
    fi
    echo
    if [ "$apply" = "true" ]; then
      mv "$tmp" "$target_dir/$name"
      echo "  ✓ wrote $target_dir/$name"
      echo
    else
      rm -f "$tmp"
    fi
  done < <(git -C "$org_repo" ls-tree -r --name-only origin/main -- .github/ISSUE_TEMPLATE 2>/dev/null)
}

copy_org_templates

if [ "$changed" = "false" ]; then
  echo "(nothing to do -- every file already matches policy)"
  exit 0
fi

if [ "$apply" != "true" ]; then
  echo "Dry run only -- re-run with --apply to write these files."
  exit 0
fi

cat <<EOF
Files written to the working tree only. Nothing is committed, pushed, or
sent to GitHub. To land them, from $clone:

  git fetch origin && git checkout -B dev/sync-ownership-files origin/HEAD
  git add -A
  git commit -s -m "chore: sync generated files with cnpg-infra policy"
  gh pr create

Add an 'Assisted-by:' trailer if a model helped, separated from
'Signed-off-by:' by a blank line, per governance/AI_POLICY.md.
EOF
