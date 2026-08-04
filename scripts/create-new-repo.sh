#!/usr/bin/env bash
#
# Onboards a brand-new cloudnative-pg org repo end-to-end:
#   1. Creates it on GitHub from cnpg-template.
#   2. Clones it as a sibling of cnpg-infra (the one step that can't be
#      skipped -- everything else here depends on the clone existing).
#   3. Appends its entry to repo-tiers.yaml and componentowners-policy.yaml
#      (at the end of each repositories: list -- this script does NOT try
#      to re-sort or re-group by class, that stays a human tidy-up).
#   4. Regenerates generated/managed-repos.yaml.
#   5. Creates and populates its <repo>-owners team
#      (scripts/sync-project-owner-teams.sh).
#   6. Renders and pushes its real CODEOWNERS
#      (scripts/render-codeowners.rb) -- deliberately BEFORE step 7, since
#      fix-repo-settings.sh's ruleset would otherwise block this direct
#      push once it's in place.
#   7. Brings it up to the settings baseline
#      (scripts/fix-repo-settings.sh --apply).
#   8. Runs scripts/validate-policy.rb as a final sanity check.
#   9. Appends it to cloudnative-pg/.project's project.yaml repositories
#      list, via a branch + PR (that repo doesn't have cnpg-infra's
#      no-PR exception).
#
# Dry-run by default, like every other script here -- prints the full
# plan and does nothing until --apply.
#
# Requires: gh (authenticated, org owner), jq, ruby, git
#
# Usage:
#   ./create-new-repo.sh --name <repo> --class <A|B|C> \
#     --subproject <core|supply-chain|community-ecosystem|extensibility|org-control|unclassified> \
#     --description "<text>" --owners user1,user2,... [--apply]
set -uo pipefail

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$INFRA_ROOT/.." && pwd)"
TIERS="$INFRA_ROOT/repo-tiers.yaml"
COMPONENTOWNERS="$INFRA_ROOT/componentowners-policy.yaml"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo "error: ruby is required" >&2; exit 1; }

name=""
class=""
subproject=""
description=""
owners=""
apply=false

while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --class) class="$2"; shift 2 ;;
    --subproject) subproject="$2"; shift 2 ;;
    --description) description="$2"; shift 2 ;;
    --owners) owners="$2"; shift 2 ;;
    --apply) apply=true; shift ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

usage() {
  echo "usage: $0 --name <repo> --class <A|B|C> --subproject <core|supply-chain|community-ecosystem|extensibility|org-control|unclassified> --description \"<text>\" --owners user1,user2,... [--apply]" >&2
  exit 1
}

[ -z "$name" ] && usage
[ -z "$class" ] && usage
[ -z "$subproject" ] && usage
[ -z "$description" ] && usage
[ -z "$owners" ] && usage

case "$class" in A|B|C) ;; *) echo "error: --class must be A, B, or C" >&2; exit 1 ;; esac
case "$subproject" in
  core|supply-chain|community-ecosystem|extensibility|org-control|unclassified) ;;
  *) echo "error: --subproject must be one of core, supply-chain, community-ecosystem, extensibility, org-control, unclassified" >&2; exit 1 ;;
esac

full="${ORG}/${name}"
clone_dir="${WORKSPACE_ROOT}/${name}"
owners_bracket="[$(echo "$owners" | tr ',' ',' | sed 's/,/, /g')]"

# --- safety: refuse if this repo is already tracked anywhere ----------
if gh api "repos/$full" >/dev/null 2>&1; then
  echo "error: $full already exists on GitHub -- this script is for brand-new repos only" >&2
  exit 1
fi
if grep -q "^  - name: ${name}\$" "$TIERS" 2>/dev/null; then
  echo "error: '$name' already has a repo-tiers.yaml entry" >&2
  exit 1
fi
if grep -q "^  - name: ${name}\$" "$COMPONENTOWNERS" 2>/dev/null; then
  echo "error: '$name' already has a componentowners-policy.yaml entry" >&2
  exit 1
fi
if [ -d "$clone_dir" ]; then
  echo "error: $clone_dir already exists" >&2
  exit 1
fi

echo "=== Plan for new repo: $full ==="
echo "  1. gh repo create $full --template ${ORG}/cnpg-template --public"
echo "  2. git clone https://github.com/$full.git $clone_dir"
echo "  3. Append to repo-tiers.yaml:"
echo "       - name: $name"
echo "         class: $class"
echo "         subproject: $subproject"
echo "         description: \"$description\""
echo "         owners: $owners_bracket"
echo "  4. Append to componentowners-policy.yaml:"
echo "       - name: $name"
echo "         rules:"
echo "           - path: \"*\""
echo "             teams: [${name}-owners]"
echo "             users: []"
echo "  5. Regenerate generated/managed-repos.yaml"
echo "  6. Create and populate the '${name}-owners' team with: $owners"
echo "  7. Render and push real CODEOWNERS (before any ruleset exists)"
echo "  8. Run fix-repo-settings.sh --apply (ruleset, security features, description)"
echo "  9. Run validate-policy.rb"
echo " 10. Open a PR on cloudnative-pg/.project adding $full to project.yaml's repositories list"
echo

if [ "$apply" != "true" ]; then
  echo "Dry run only -- re-run with --apply to actually do this."
  exit 0
fi

echo "Applying..."

echo "--- 1. Creating repo ---"
gh repo create "$full" --template "${ORG}/cnpg-template" --public \
  || { echo "error: failed to create $full" >&2; exit 1; }

echo "--- 2. Cloning as sibling ---"
git clone "https://github.com/$full.git" "$clone_dir" \
  || { echo "error: failed to clone $full" >&2; exit 1; }

echo "--- 3. Appending to repo-tiers.yaml ---"
{
  echo "  - name: $name"
  echo "    class: $class"
  echo "    subproject: $subproject"
  echo "    description: \"$description\""
  echo "    owners: $owners_bracket"
} >> "$TIERS"

echo "--- 4. Appending to componentowners-policy.yaml ---"
{
  echo "  - name: $name"
  echo "    rules:"
  echo "      - path: \"*\""
  echo "        teams: [${name}-owners]"
  echo "        users: []"
} >> "$COMPONENTOWNERS"

echo "--- 5. Regenerating generated/managed-repos.yaml ---"
"$INFRA_ROOT/scripts/update-managed-repos.sh"

echo "--- 6. Creating and populating ${name}-owners team ---"
"$INFRA_ROOT/scripts/sync-project-owner-teams.sh" "$name" --apply

echo "--- 7. Rendering and pushing CODEOWNERS ---"
codeowners_content="$(ruby "$INFRA_ROOT/scripts/render-codeowners.rb" "$name")"
existing_sha="$(gh api "repos/$full/contents/CODEOWNERS" --jq '.sha' 2>/dev/null)"
b64="$(echo "$codeowners_content" | base64)"
msg=$'chore: sync CODEOWNERS with cnpg-infra policy\n\nSee cloudnative-pg/cnpg-infra for the policy this is generated from.\n\nAssisted-by: Claude'
if [ -n "$existing_sha" ]; then
  gh api -X PUT "repos/$full/contents/CODEOWNERS" -f message="$msg" -f content="$b64" -f sha="$existing_sha" >/dev/null \
    && echo "  ✓ CODEOWNERS updated" || echo "  ✗ failed to update CODEOWNERS"
else
  gh api -X PUT "repos/$full/contents/CODEOWNERS" -f message="$msg" -f content="$b64" >/dev/null \
    && echo "  ✓ CODEOWNERS created" || echo "  ✗ failed to create CODEOWNERS"
fi

echo "--- 8. Bringing $name up to the settings baseline ---"
"$INFRA_ROOT/scripts/fix-repo-settings.sh" "$name" --apply

echo "--- 9. Validating policy files ---"
ruby "$INFRA_ROOT/scripts/validate-policy.rb"

echo "--- 10. Adding $name to cloudnative-pg/.project's repositories list ---"
project_full="${ORG}/.project"
project_branch="chore/add-${name}-to-repositories"
project_main_sha="$(gh api "repos/$project_full/git/refs/heads/main" --jq '.object.sha')"
if gh api "repos/$project_full/git/refs" -f ref="refs/heads/$project_branch" -f sha="$project_main_sha" >/dev/null 2>&1; then
  project_yaml="$(gh api "repos/$project_full/contents/project.yaml?ref=$project_branch" --jq '.content' | base64 -d)"
  new_line="  - \"https://github.com/$full\""
  if echo "$project_yaml" | grep -qF "$new_line"; then
    echo "  (already listed, skipping)"
  else
    last_repo_line="$(echo "$project_yaml" | grep -n '^  - "https://github.com/' | tail -1 | cut -d: -f1)"
    if [ -z "$last_repo_line" ]; then
      echo "  ✗ could not find the repositories: list in project.yaml -- add $full by hand" >&2
    else
      new_project_yaml="$(echo "$project_yaml" | awk -v n="$last_repo_line" -v line="$new_line" 'NR==n { print; print line; next } { print }')"
      project_sha="$(gh api "repos/$project_full/contents/project.yaml?ref=$project_branch" --jq '.sha')"
      b64_project="$(echo "$new_project_yaml" | base64)"
      msg_project=$'chore: add '"$name"$' to repositories list\n\nAssisted-by: Claude'
      if gh api -X PUT "repos/$project_full/contents/project.yaml" -f message="$msg_project" -f content="$b64_project" -f branch="$project_branch" -f sha="$project_sha" >/dev/null; then
        echo "  ✓ committed to $project_branch"
        pr_url="$(gh pr create --repo "$project_full" --base main --head "$project_branch" \
          --title "chore: add $name to repositories list" \
          --body "New repo, onboarded via cnpg-infra/scripts/create-new-repo.sh.

Assisted-by: Claude" 2>&1)"
        echo "  ✓ PR: $pr_url"
      else
        echo "  ✗ failed to commit -- add $full to project.yaml's repositories list by hand"
      fi
    fi
  fi
else
  echo "  ✗ failed to create branch on $project_full -- add $full to project.yaml's repositories list by hand"
fi

echo
echo "Done. $full is onboarded. Re-run ./check-repo-settings.sh $name to verify, and review the .project PR above."
