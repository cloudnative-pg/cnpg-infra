#!/usr/bin/env bash
#
# For every repo in componentowners-policy.yaml whose `*` rule lists
# individual `users`, ensures a "<repo>-owners" GitHub team exists with
# exactly those users as members, grants that team `maintain` on the repo,
# and removes any *direct* (non-team) collaborator grant for those same
# users on that repo — access should live in one place (the team), not
# both a direct grant and a team grant simultaneously.
#
# Only removes a direct grant for someone who is already a full org member.
# Adding a non-member to a team creates a *pending* invitation, not active
# membership, until they accept it — removing their direct access first
# would leave them with reduced access in the meantime. Learned this the
# hard way on the first real run (docs/SaxenaAnushka102 and
# postgres-keycloak-oauth-validator/y-tabata both dropped to read-only for
# a few minutes before this check was added).
#
# Does NOT touch componentowners-policy.yaml itself (adding the new team to
# each repo's `teams:` list, and clearing the now-redundant `users:` list,
# is a separate, deliberate edit — this script only touches live GitHub
# team/collaborator state).
#
# Team naming: <repo>-owners, with any character GitHub wouldn't accept in
# a slug (currently just "." in cloudnative-pg.github.io) replaced with "-"
# up front, so the name we ask for and the slug GitHub assigns can't drift
# apart from each other.
#
# Requires: gh (authenticated, org owner — team creation and collaborator
# removal both need real org-admin scope), jq
#
# Usage:
#   ./sync-project-owner-teams.sh              # dry run: show every repo's plan
#   ./sync-project-owner-teams.sh <repo>        # dry run: just one repo
#   ./sync-project-owner-teams.sh [<repo>] --apply   # actually apply it
set -uo pipefail

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPONENTOWNERS="$INFRA_ROOT/componentowners-policy.yaml"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
[ -f "$COMPONENTOWNERS" ] || { echo "error: $COMPONENTOWNERS not found" >&2; exit 1; }

apply=false
target_repo=""
for arg in "$@"; do
  if [ "$arg" = "--apply" ]; then
    apply=true
  else
    target_repo="$arg"
  fi
done

team_slug_for() { # $1 = repo name -> prints the "<repo>-owners" slug
  echo "$1-owners" | tr '.' '-'
}

is_active_org_member() { # $1 = username -> exit 0 if they're a full, active org member
  gh api "orgs/${ORG}/members/${1}" >/dev/null 2>&1
}

# --- extract, for every repo, the `*` rule's users list (only non-empty) --
# Parser assumes the file's existing shape: one `- name:` block per repo,
# rules in order with `path: "*"` first, `users: [...]` on the same rule.
mapfile -t REPO_USER_PAIRS < <(awk '
  /^  - name:/ { name=$3; in_star=0 }
  /path: "\*"/ { in_star=1; next }
  /path: "\// { in_star=0 }
  in_star && /^        users:/ {
    line=$0
    sub(/^        users: \[/, "", line)
    sub(/\]$/, "", line)
    gsub(/ /, "", line)
    if (length(line) > 0) print name "\t" line
    in_star=0
  }
' "$COMPONENTOWNERS")

if [ -n "$target_repo" ]; then
  filtered=()
  for pair in "${REPO_USER_PAIRS[@]}"; do
    [[ "$pair" == "$target_repo"$'\t'* ]] && filtered+=("$pair")
  done
  REPO_USER_PAIRS=("${filtered[@]}")
  if [ "${#REPO_USER_PAIRS[@]}" -eq 0 ]; then
    echo "error: '$target_repo' has no non-empty users list in componentowners-policy.yaml's * rule" >&2
    exit 1
  fi
fi

apply_note=""
[ "$apply" = "true" ] && apply_note=" (--apply: changes WILL be made)"
echo "Processing ${#REPO_USER_PAIRS[@]} repo(s)${apply_note}..." >&2
echo >&2

for pair in "${REPO_USER_PAIRS[@]}"; do
  repo="${pair%%$'\t'*}"
  users_csv="${pair#*$'\t'}"
  IFS=',' read -r -a desired_users <<< "$users_csv"
  full="${ORG}/${repo}"
  slug="$(team_slug_for "$repo")"

  echo "=== $full -> team '$slug' ==="

  team_json="$(gh api "orgs/${ORG}/teams/${slug}" 2>/dev/null)"
  team_exists=$([ $? -eq 0 ] && echo true || echo false)

  if [ "$team_exists" = "true" ]; then
    mapfile -t current_members < <(gh api "orgs/${ORG}/teams/${slug}/members" --jq '.[].login' 2>/dev/null | sort)
  else
    current_members=()
  fi

  missing_members=()
  for u in "${desired_users[@]}"; do
    found=false
    for m in "${current_members[@]:-}"; do
      [ "$u" = "$m" ] && found=true && break
    done
    [ "$found" = "false" ] && missing_members+=("$u")
  done

  current_permission="unknown"
  if [ "$team_exists" = "true" ]; then
    # This endpoint only returns the actual permission level in the body
    # with this specific Accept header — otherwise it's just a 204/404
    # existence check with no body at all.
    perm_json="$(gh api -H "Accept: application/vnd.github.v3.repository+json" "orgs/${ORG}/teams/${slug}/repos/${full}" 2>/dev/null)"
    current_permission="$(echo "$perm_json" | jq -r '.role_name // "none"' 2>/dev/null || echo "none")"
  fi

  direct_json="$(gh api -X GET "repos/${full}/collaborators" -f affiliation=direct 2>/dev/null)"
  [ $? -eq 0 ] || direct_json='[]'
  to_remove_direct=()
  skipped_not_member=()
  for u in "${desired_users[@]}"; do
    if echo "$direct_json" | jq -e --arg u "$u" '.[] | select(.login == $u)' >/dev/null 2>&1; then
      # Only safe to drop their direct grant if they're already a full org
      # member — otherwise team membership lands "pending" (needs their
      # acceptance) rather than active, and removing direct access first
      # would leave them with reduced access until they accept. Learned
      # this the hard way on docs/SaxenaAnushka102 and
      # postgres-keycloak-oauth-validator/y-tabata.
      if is_active_org_member "$u"; then
        to_remove_direct+=("$u")
      else
        skipped_not_member+=("$u")
      fi
    fi
  done

  if [ "$team_exists" = "false" ]; then
    echo "  - team does not exist: would create '$slug' with members: ${desired_users[*]}"
  elif [ "${#missing_members[@]}" -gt 0 ]; then
    echo "  - team exists, missing members: ${missing_members[*]}"
  else
    echo "  - team exists with all desired members already"
  fi

  if [ "$current_permission" != "maintain" ]; then
    echo "  - repo permission: '$current_permission' -> 'maintain'"
  else
    echo "  - repo permission: already 'maintain'"
  fi

  if [ "${#to_remove_direct[@]}" -gt 0 ]; then
    echo "  - direct collaborator grants to remove (now covered by team): ${to_remove_direct[*]}"
  else
    echo "  - no direct collaborator grants to remove"
  fi
  if [ "${#skipped_not_member[@]}" -gt 0 ]; then
    echo "  - ⚠️  NOT removing direct grant for: ${skipped_not_member[*]} (not a full org member yet — team access would land pending, not active; removing direct access now would leave them with reduced access until they accept an org invite)"
  fi

  if [ "$apply" = "true" ]; then
    if [ "$team_exists" = "false" ]; then
      gh api -X POST "orgs/${ORG}/teams" -f "name=${slug}" -f "privacy=closed" \
        -f "description=Owners of ${repo}" >/dev/null \
        && echo "  ✓ team '$slug' created" \
        || { echo "  ✗ failed to create team '$slug'"; continue; }
    fi
    for u in "${missing_members[@]:-}"; do
      [ -z "$u" ] && continue
      gh api -X PUT "orgs/${ORG}/teams/${slug}/memberships/${u}" -f role=member >/dev/null \
        && echo "  ✓ added $u to $slug" \
        || echo "  ✗ failed to add $u to $slug"
    done
    if [ "$current_permission" != "maintain" ]; then
      gh api -X PUT "orgs/${ORG}/teams/${slug}/repos/${full}" -f permission=maintain >/dev/null \
        && echo "  ✓ granted $slug 'maintain' on $repo" \
        || echo "  ✗ failed to grant $slug access to $repo"
    fi
    for u in "${to_remove_direct[@]:-}"; do
      [ -z "$u" ] && continue
      gh api -X DELETE "repos/${full}/collaborators/${u}" >/dev/null \
        && echo "  ✓ removed direct collaborator grant for $u" \
        || echo "  ✗ failed to remove direct collaborator grant for $u"
    done
  fi

  echo
done

if [ "$apply" != "true" ]; then
  echo "Dry run only — re-run with --apply to make these changes."
fi
