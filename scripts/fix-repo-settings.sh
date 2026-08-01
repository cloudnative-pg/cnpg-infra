#!/usr/bin/env bash
#
# Brings one repo's branch protection and vulnerability-handling settings up
# to the org baseline. Only ever *strengthens* settings — never lowers an
# existing stricter value (e.g. a repo already requiring 2 reviews keeps
# requiring 2).
#
# Branch protection is enforced via a repository Ruleset named
# "cnpg-baseline", NOT classic branch protection. Classic protection is
# still read (to combine with any existing ruleset when computing the floor
# to never lower) but this script no longer writes to it — it was found to
# silently ignore writes to `allow_force_pushes` on at least one real repo
# (cloudnative-pg.github.io) while every other classic-protection field
# worked fine; rulesets are a separate mechanism and aren't affected by
# whatever that was. If a repo already has working classic protection, the
# new ruleset simply adds an equal-or-stricter floor alongside it (GitHub
# enforces the most restrictive of all applicable rules + rulesets, so this
# is safe to layer rather than replace).
#
# Scope, deliberately narrow:
#   - Default branch only (whatever GitHub reports as default_branch), via
#     the ruleset's `~DEFAULT_BRANCH` condition. This script never touches
#     dev/*, release-*, or any other branch — force-push and deletion stay
#     allowed there regardless of what this does to the default branch.
#   - Required approving reviews: raised to at least 1 by default, never
#     lowered. The floor can go higher two ways, and the higher of the two
#     wins: repo-tiers.yaml's `class` (A = 2, B/C = 1) — the normal
#     mechanism — or repo-policy.yaml's standalone `required_reviews`
#     override, kept for repos not yet classified there.
#   - Code-owner review: forced on for class A/B, left untouched (whatever
#     it already is) for class C/n/a. EXCEPT for repos listed under
#     category "automated" (content published by automation from an
#     already-reviewed upstream repo), where NEITHER the review-count
#     floor NOR the code-owner-review requirement is forced, regardless of
#     class — a bot can't satisfy a human PR-review gate the same way a
#     person can (repo-tiers.yaml's `artifacts` entry is the example:
#     class A, but also category automated).
#   - Default branch: force-push and deletion blocked (ruleset rules
#     `non_fast_forward` + `deletion`), for every repo including "automated"
#     ones — that protection is unrelated to the review-gate question.
#   - Existing required status checks, code-owner-review requirement,
#     dismiss-stale-reviews, and last-push-approval are preserved as-is
#     (read from whichever of classic protection / an existing ruleset has
#     them) — this script adds a floor, it doesn't redesign a repo's
#     existing review policy.
#   - Linear history: required (`required_linear_history` rule). This is a
#     plain boolean floor, forced unconditionally, including for
#     "automated" repos.
#   - Dependabot vulnerability alerts + security updates: turned on if off.
#   - Secret scanning + push protection: turned on if off.
#   - Repo-level merge/branch settings, forced to true if not already:
#     squash merging, rebase merging, "always suggest updating PR branches",
#     delete head branches on merge. "Allow merge commit" is left untouched —
#     turning it off isn't requested and required_linear_history already
#     blocks a merge commit from landing even if the button is offered.
#   - Squash-merge commit message: forced to PR title + PR body
#     (squash_merge_commit_title=PR_TITLE, squash_merge_commit_message=PR_BODY),
#     so a squashed commit reads the same as the PR it came from rather than
#     a pile of intermediate commit messages.
#   - Does NOT touch teams, collaborators, or repo visibility — those are
#     governance/roster decisions (see governance/CLAUDE.md), not settings
#     a script should change unilaterally.
#   - Does NOT touch "require signed commits" — GitHub accepts GPG, SSH, or
#     S/MIME signatures for this, and turning it on can break contributors
#     who haven't set up commit signing, so it's left as an explicit opt-in
#     rather than something this script forces.
#   - Does NOT touch any *other* ruleset on the repo (e.g. tag-protection
#     rulesets, a "Copilot review" ruleset) — only ever creates/updates the
#     one named "cnpg-baseline".
#
# Requires: gh (authenticated, admin on the target repo), jq
#
# Usage:
#   ./fix-repo-settings.sh <repo-name>            # dry run: show proposed diff only
#   ./fix-repo-settings.sh <repo-name> --apply    # actually apply the changes
set -uo pipefail

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$INFRA_ROOT/generated/managed-repos.yaml"
POLICY="$INFRA_ROOT/repo-policy.yaml"
TIERS="$INFRA_ROOT/repo-tiers.yaml"
# The ruleset this script manages is named after the branch it protects
# (e.g. "main"), matching GitHub's own convention (see cloudnative-pg/docs'
# hand-authored ruleset, also named "main") — set once default_branch is known.

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

policy_category() { # $1 = repo name -> prints category, or "standard" if unlisted
  [ -f "$POLICY" ] || { echo "standard"; return; }
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    category:/ { print $2; matched=1; exit }
    END { if (!matched) print "standard" }
  ' "$POLICY"
}

policy_required_reviews() { # $1 = repo name -> prints integer floor, or 1 if unlisted
  [ -f "$POLICY" ] || { echo 1; return; }
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    required_reviews:/ { print $2; matched=1; exit }
    END { if (!matched) print 1 }
  ' "$POLICY"
}

policy_tier() { # $1 = repo name -> prints class (A/B/C), or "C" if unlisted/n/a
  [ -f "$TIERS" ] || { echo "C"; return; }
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    class:/ { print $2; matched=1; exit }
    END { if (!matched) print "C" }
  ' "$TIERS"
}

entry_exists() { # $1 = file, $2 = repo name -> exit 0 if that file has a "- name: <repo>" entry
  [ -f "$1" ] || return 1
  grep -q "^  - name: $2\$" "$1"
}

tier_review_floor() { # $1 = class -> prints the review-count floor that class implies
  case "$1" in
    A) echo 2 ;;
    *) echo 1 ;;  # B, C, n/a: org default, no extra floor
  esac
}

tier_forces_code_owner_review() { # $1 = class -> prints true/false
  case "$1" in
    A|B) echo true ;;
    *) echo false ;;
  esac
}

repo="${1:-}"
apply=false
[ "${2:-}" = "--apply" ] && apply=true

if [ -z "$repo" ]; then
  echo "usage: $0 <repo-name> [--apply]" >&2
  exit 1
fi

if [ -f "$MANIFEST" ] && ! grep -q "^  - name: ${repo}\$" "$MANIFEST"; then
  echo "error: '$repo' is not in managed-repos.yaml — refusing to touch a repo outside the managed scope." >&2
  echo "       (run ./update-managed-repos.sh first if it should be there)" >&2
  exit 1
fi

full="${ORG}/${repo}"

repo_json="$(gh api "repos/$full" 2>/dev/null)"
if [ -z "$repo_json" ] || [ "$(echo "$repo_json" | jq -r 'length')" = "0" ]; then
  echo "error: could not read repos/$full (not found, or no access)" >&2
  exit 1
fi

# NOTE throughout: deliberately not using jq's `//` for booleans — it treats
# a real `false` the same as `null`/missing, so e.g. `.enabled // true`
# would silently flip an actual `false` into `true`. `if . == null` only
# substitutes the default when the field is genuinely absent.
has_admin="$(echo "$repo_json" | jq -r '.permissions.admin | if . == null then false else . end')"
if [ "$has_admin" != "true" ]; then
  echo "error: this token does not have admin access to $full — can't change branch protection or security settings." >&2
  exit 1
fi

default_branch="$(echo "$repo_json" | jq -r '.default_branch')"
RULESET_NAME="$default_branch"

# Classic branch protection — read only, never written, per the header note.
bp_json="$(gh api "repos/$full/branches/$default_branch/protection" 2>/dev/null)"
[ $? -eq 0 ] || bp_json='{}'

# Effective ruleset-sourced rules for this branch (aggregates repo + org +
# enterprise rulesets — but NOT classic protection, they're independent).
rules_json="$(gh api "repos/$full/rules/branches/$default_branch" 2>/dev/null)"
[ $? -eq 0 ] || rules_json='[]'

secret_scanning="$(echo "$repo_json" | jq -r '.security_and_analysis.secret_scanning.status // "unknown"')"
push_protection="$(echo "$repo_json" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"')"
dependabot_sec="$(echo "$repo_json" | jq -r '.security_and_analysis.dependabot_security_updates.status // "unknown"')"
vuln_status_code="$(gh api -i "repos/$full/vulnerability-alerts" 2>/dev/null | head -1 | awk '{print $2}')"
vuln_enabled="$([ "$vuln_status_code" = "204" ] && echo true || echo false)"

category="$(policy_category "$repo")"

# --- combine classic protection + effective ruleset rules into "old" values,
#     each one true/set if EITHER mechanism already provides it ------------
classic_reviews="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
classic_code_owner="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.require_code_owner_reviews | if . == null then false else . end')"
classic_dismiss_stale="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.dismiss_stale_reviews | if . == null then false else . end')"
classic_last_push="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.require_last_push_approval | if . == null then false else . end')"
classic_had_review_block="$(echo "$bp_json" | jq -r '.required_pull_request_reviews != null')"
classic_force_push_blocked="$(echo "$bp_json" | jq -r '(.allow_force_pushes.enabled | if . == null then true else . end) == false')"
classic_deletion_blocked="$(echo "$bp_json" | jq -r '(.allow_deletions.enabled | if . == null then true else . end) == false')"
classic_linear_history="$(echo "$bp_json" | jq -r '.required_linear_history.enabled | if . == null then false else . end')"
classic_status_checks="$(echo "$bp_json" | jq -c '[(.required_status_checks.checks // [])[].context] | unique')"

rules_pr="$(echo "$rules_json" | jq -c '[.[] | select(.type=="pull_request")][0].parameters // {}')"
rules_reviews="$(echo "$rules_pr" | jq -r '.required_approving_review_count // 0')"
rules_code_owner="$(echo "$rules_pr" | jq -r '.require_code_owner_review // false')"
rules_dismiss_stale="$(echo "$rules_pr" | jq -r '.dismiss_stale_reviews_on_push // false')"
rules_last_push="$(echo "$rules_pr" | jq -r '.require_last_push_approval // false')"
rules_had_review_block="$(echo "$rules_json" | jq -r 'any(.[]; .type=="pull_request")')"
rules_force_push_blocked="$(echo "$rules_json" | jq -r 'any(.[]; .type=="non_fast_forward")')"
rules_deletion_blocked="$(echo "$rules_json" | jq -r 'any(.[]; .type=="deletion")')"
rules_linear_history="$(echo "$rules_json" | jq -r 'any(.[]; .type=="required_linear_history")')"
rules_status_checks="$(echo "$rules_json" | jq -c '[.[] | select(.type=="required_status_checks")][0].parameters.required_status_checks // [] | map(.context)')"

old_reviews=$(( classic_reviews > rules_reviews ? classic_reviews : rules_reviews ))
old_code_owner="$([ "$classic_code_owner" = "true" ] || [ "$rules_code_owner" = "true" ] && echo true || echo false)"
old_dismiss_stale="$([ "$classic_dismiss_stale" = "true" ] || [ "$rules_dismiss_stale" = "true" ] && echo true || echo false)"
old_last_push="$([ "$classic_last_push" = "true" ] || [ "$rules_last_push" = "true" ] && echo true || echo false)"
old_had_review_block="$([ "$classic_had_review_block" = "true" ] || [ "$rules_had_review_block" = "true" ] && echo true || echo false)"
old_force_push_blocked="$([ "$classic_force_push_blocked" = "true" ] || [ "$rules_force_push_blocked" = "true" ] && echo true || echo false)"
old_deletion_blocked="$([ "$classic_deletion_blocked" = "true" ] || [ "$rules_deletion_blocked" = "true" ] && echo true || echo false)"
old_linear_history="$([ "$classic_linear_history" = "true" ] || [ "$rules_linear_history" = "true" ] && echo true || echo false)"
old_status_checks="$(jq -cn --argjson a "$classic_status_checks" --argjson b "$rules_status_checks" '($a + $b) | unique')"

old_squash="$(echo "$repo_json" | jq -r '.allow_squash_merge | if . == null then false else . end')"
old_rebase="$(echo "$repo_json" | jq -r '.allow_rebase_merge | if . == null then false else . end')"
old_update_branch="$(echo "$repo_json" | jq -r '.allow_update_branch | if . == null then false else . end')"
old_delete_on_merge="$(echo "$repo_json" | jq -r '.delete_branch_on_merge | if . == null then false else . end')"
old_squash_title="$(echo "$repo_json" | jq -r '.squash_merge_commit_title // "unknown"')"
old_squash_message="$(echo "$repo_json" | jq -r '.squash_merge_commit_message // "unknown"')"

if ! entry_exists "$TIERS" "$repo"; then
  echo "⚠️  '$repo' has no entry in repo-tiers.yaml — defaulting to class C until it's classified." >&2
fi
tier="$(policy_tier "$repo")"
policy_floor="$(policy_required_reviews "$repo")"
tier_floor="$(tier_review_floor "$tier")"
required_reviews_floor=$(( policy_floor > tier_floor ? policy_floor : tier_floor ))

if [ "$category" = "automated" ]; then
  # Never force a review requirement into existence for an automated repo;
  # if one already exists for some other reason (in classic protection or
  # another ruleset), leave its count and code-owner-review requirement
  # untouched rather than flooring them — a bot can't satisfy a human
  # PR-review gate the same way a person can, regardless of tier.
  new_reviews="$old_reviews"
  force_review_block="$old_had_review_block"
  new_code_owner="$old_code_owner"
else
  new_reviews=$(( old_reviews > required_reviews_floor ? old_reviews : required_reviews_floor ))
  force_review_block=true
  if [ "$(tier_forces_code_owner_review "$tier")" = "true" ]; then
    new_code_owner=true
  else
    new_code_owner="$old_code_owner"
  fi
fi

# --- find our own managed ruleset, if one already exists on this repo -----
existing_ruleset_id="$(gh api "repos/$full/rulesets" 2>/dev/null | jq -r --arg name "$RULESET_NAME" '.[] | select(.name==$name) | .id' | head -1)"

# --- build the ruleset body, preserving everything that already exists and
#     only adding the floor described above --------------------------------
new_ruleset_body="$(jq -n \
  --arg name "$RULESET_NAME" \
  --argjson reviews "$new_reviews" \
  --argjson force_review_block "$force_review_block" \
  --argjson code_owner "$new_code_owner" \
  --argjson dismiss_stale "$old_dismiss_stale" \
  --argjson last_push "$old_last_push" \
  --argjson status_checks "$old_status_checks" \
  '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: (
      [{type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"}]
      + (if $force_review_block then
          [{type: "pull_request", parameters: {
            required_approving_review_count: $reviews,
            dismiss_stale_reviews_on_push: $dismiss_stale,
            require_code_owner_review: $code_owner,
            require_last_push_approval: $last_push,
            required_review_thread_resolution: false
          }}]
        else [] end)
      + (if ($status_checks | length) > 0 then
          [{type: "required_status_checks", parameters: {
            do_not_enforce_on_create: false,
            strict_required_status_checks_policy: false,
            required_status_checks: [$status_checks[] | {context: ., integration_id: null}]
          }}]
        else [] end)
    )
  }')"

echo "=== $full  (default branch: $default_branch) ==="
echo "Class: $tier (repo-tiers.yaml)"
if [ "$category" != "standard" ]; then
  echo "Category: $category (repo-policy.yaml) — review-count and code-owner-review floors skipped, other protections still apply"
elif [ "$required_reviews_floor" != "1" ]; then
  floor_source="repo-tiers.yaml, class $tier"
  [ "$policy_floor" -gt "$tier_floor" ] && floor_source="repo-policy.yaml override"
  echo "Required-reviews floor: $required_reviews_floor ($floor_source; org default is 1)"
fi
if [ -n "$existing_ruleset_id" ]; then
  echo "Managed via ruleset '$RULESET_NAME' (id $existing_ruleset_id) — will update in place"
else
  echo "No '$RULESET_NAME' ruleset yet — will create one"
fi
echo
echo "Proposed changes (combined view: classic protection OR any existing ruleset, whichever is stricter):"
changed=false

diff_line() { # $1=label $2=old $3=new
  if [ "$2" != "$3" ]; then
    echo "  - $1: $2 -> $3"
    changed=true
  fi
}

diff_line "required approving reviews"        "$old_reviews"      "$new_reviews"
diff_line "code owner review required"        "$old_code_owner"   "$new_code_owner"
diff_line "force pushes allowed on $default_branch" "$([ "$old_force_push_blocked" = "true" ] && echo false || echo true)" "false"
diff_line "deletion allowed on $default_branch"     "$([ "$old_deletion_blocked" = "true" ] && echo false || echo true)"   "false"
diff_line "linear history required"           "$old_linear_history" "true"
diff_line "secret scanning"                   "$secret_scanning"  "enabled"
diff_line "secret scanning push protection"   "$push_protection"  "enabled"
diff_line "dependabot security updates"       "$dependabot_sec"   "enabled"
diff_line "dependabot vulnerability alerts"   "$vuln_enabled"     "true"
diff_line "allow squash merging"              "$old_squash"       "true"
diff_line "allow rebase merging"              "$old_rebase"       "true"
diff_line "suggest updating PR branches"      "$old_update_branch" "true"
diff_line "delete head branches on merge"     "$old_delete_on_merge" "true"
diff_line "squash commit title"               "$old_squash_title"   "PR_TITLE"
diff_line "squash commit message"             "$old_squash_message" "PR_BODY"

if [ "$changed" = "false" ]; then
  echo "  (nothing to do — already at or above baseline)"
  exit 0
fi

echo
echo "Untouched by this script (preserved as-is): required status check names,"
echo "admin enforcement, allow-merge-commit, signed-commit requirement, any"
echo "other ruleset on the repo, teams, collaborators, visibility."
echo

if [ "$apply" != "true" ]; then
  echo "Dry run only — re-run with --apply to make these changes."
  exit 0
fi

echo "Applying..."

if [ -n "$existing_ruleset_id" ]; then
  echo "$new_ruleset_body" | gh api -X PUT "repos/$full/rulesets/$existing_ruleset_id" --input - >/dev/null \
    && echo "  ✓ '$RULESET_NAME' ruleset updated" \
    || echo "  ✗ failed to update '$RULESET_NAME' ruleset"
else
  echo "$new_ruleset_body" | gh api -X POST "repos/$full/rulesets" --input - >/dev/null \
    && echo "  ✓ '$RULESET_NAME' ruleset created" \
    || echo "  ✗ failed to create '$RULESET_NAME' ruleset"
fi

if [ "$secret_scanning" != "enabled" ] || [ "$push_protection" != "enabled" ]; then
  gh api -X PATCH "repos/$full" -f "security_and_analysis[secret_scanning][status]=enabled" \
    -f "security_and_analysis[secret_scanning_push_protection][status]=enabled" >/dev/null \
    && echo "  ✓ secret scanning + push protection enabled" \
    || echo "  ✗ failed to enable secret scanning"
fi

if [ "$vuln_enabled" != "true" ]; then
  gh api -X PUT "repos/$full/vulnerability-alerts" \
    && echo "  ✓ vulnerability alerts enabled" \
    || echo "  ✗ failed to enable vulnerability alerts"
fi

if [ "$dependabot_sec" != "enabled" ]; then
  gh api -X PUT "repos/$full/automated-security-fixes" \
    && echo "  ✓ dependabot security updates enabled" \
    || echo "  ✗ failed to enable dependabot security updates"
fi

if [ "$old_squash" != "true" ] || [ "$old_rebase" != "true" ] || \
   [ "$old_update_branch" != "true" ] || [ "$old_delete_on_merge" != "true" ] || \
   [ "$old_squash_title" != "PR_TITLE" ] || [ "$old_squash_message" != "PR_BODY" ]; then
  gh api -X PATCH "repos/$full" \
    -F "allow_squash_merge=true" \
    -F "allow_rebase_merge=true" \
    -F "allow_update_branch=true" \
    -F "delete_branch_on_merge=true" \
    -F "squash_merge_commit_title=PR_TITLE" \
    -F "squash_merge_commit_message=PR_BODY" >/dev/null \
    && echo "  ✓ merge/branch settings updated (squash, rebase, suggest-update, delete-on-merge, squash message = PR title+body)" \
    || echo "  ✗ failed to update merge/branch settings"
fi

echo
echo "Done. Re-run ./check-repo-settings.sh $repo to verify."
