#!/usr/bin/env bash
#
# For every repo in repo-tiers.yaml with a non-empty `owners` list, ensures
# a "<repo>-owners" GitHub team exists with EXACTLY those users as members
# (adds anyone missing, removes anyone no longer listed), grants that team
# `maintain` on the repo, and removes any *direct* (non-team) collaborator
# grant for those same users on that repo — access should live in one
# place (the team), not both a direct grant and a team grant simultaneously.
#
# repo-tiers.yaml's `owners` field is the single source of truth for this
# team's membership — not componentowners-policy.yaml, which only
# references the team by name in its CODEOWNERS `*` rule and doesn't
# duplicate who's in it.
#
# Only removes a direct grant for someone who is already a full org member.
# Adding a non-member to a team creates a *pending* invitation, not active
# membership, until they accept it — removing their direct access first
# would leave them with reduced access in the meantime. Learned this the
# hard way on the first real run (docs/SaxenaAnushka102 and
# postgres-keycloak-oauth-validator/y-tabata both dropped to read-only for
# a few minutes before this check was added).
#
# Team naming: <repo>-owners, with any character GitHub wouldn't accept in
# a slug replaced or stripped up front, so the name we ask for and the
# slug GitHub assigns can't drift apart from each other: an internal "."
# (cloudnative-pg.github.io) becomes "-", and a leading "." (.github,
# .project) is dropped rather than turned into a leading "-".
#
# Requires: gh (authenticated, org owner — team creation, membership
# changes, and collaborator removal all need real org-admin scope), jq
#
# Usage:
#   ./sync-project-owner-teams.sh              # dry run: show every repo's plan
#   ./sync-project-owner-teams.sh <repo>        # dry run: just one repo
#   ./sync-project-owner-teams.sh [<repo>] --apply   # actually apply it
set -uo pipefail

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIERS="$INFRA_ROOT/repo-tiers.yaml"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
[ -f "$TIERS" ] || { echo "error: $TIERS not found" >&2; exit 1; }

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
  local base="${1#.}" # strip a leading "." (.github -> github, .project -> project)
  echo "${base}-owners" | tr '.' '-'
}

is_active_org_member() { # $1 = username -> exit 0 if they're a full, active org member
  gh api "orgs/${ORG}/members/${1}" >/dev/null 2>&1
}

# --- extract, for every repo, the `owners:` list (only non-empty) ---------
# Parser assumes the file's existing shape: one `- name:` block per repo,
# with an `owners: [...]` line somewhere in that block (order-independent,
# unlike componentowners-policy.yaml's per-rule fields).
mapfile -t REPO_OWNER_PAIRS < <(awk '
  /^  - name:/ { name=$3 }
  /^    owners:/ {
    line=$0
    sub(/^    owners: \[/, "", line)
    sub(/\]$/, "", line)
    gsub(/ /, "", line)
    if (length(line) > 0) print name "\t" line
  }
' "$TIERS")

if [ -n "$target_repo" ]; then
  filtered=()
  for pair in "${REPO_OWNER_PAIRS[@]}"; do
    [[ "$pair" == "$target_repo"$'\t'* ]] && filtered+=("$pair")
  done
  REPO_OWNER_PAIRS=("${filtered[@]}")
  if [ "${#REPO_OWNER_PAIRS[@]}" -eq 0 ]; then
    echo "error: '$target_repo' has no non-empty owners list in repo-tiers.yaml" >&2
    exit 1
  fi
fi

apply_note=""
[ "$apply" = "true" ] && apply_note=" (--apply: changes WILL be made)"
echo "Processing ${#REPO_OWNER_PAIRS[@]} repo(s)${apply_note}..." >&2
echo >&2

for pair in "${REPO_OWNER_PAIRS[@]}"; do
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

  # Reconciliation: anyone currently an active team member but no longer in
  # repo-tiers.yaml's owners list gets removed. Safe to do unconditionally
  # (unlike adding) — removing an existing team member is always instant,
  # there's no "pending" equivalent on the way out.
  extra_members=()
  for m in "${current_members[@]:-}"; do
    found=false
    for u in "${desired_users[@]}"; do
      [ "$u" = "$m" ] && found=true && break
    done
    [ "$found" = "false" ] && extra_members+=("$m")
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
  else
    [ "${#missing_members[@]}" -gt 0 ] && echo "  - missing members to add: ${missing_members[*]}"
    [ "${#extra_members[@]}" -gt 0 ] && echo "  - extra members to remove (no longer in repo-tiers.yaml): ${extra_members[*]}"
    [ "${#missing_members[@]}" -eq 0 ] && [ "${#extra_members[@]}" -eq 0 ] && echo "  - team exists with exactly the desired members"
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
    for m in "${extra_members[@]:-}"; do
      [ -z "$m" ] && continue
      gh api -X DELETE "orgs/${ORG}/teams/${slug}/memberships/${m}" >/dev/null \
        && echo "  ✓ removed $m from $slug" \
        || echo "  ✗ failed to remove $m from $slug"
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
