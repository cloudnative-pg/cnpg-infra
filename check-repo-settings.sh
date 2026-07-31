#!/usr/bin/env bash
#
# Audits GitHub repository settings (visibility, teams, collaborators,
# branch protection, security features) for every repo listed in
# managed-repos.yaml, and cross-references the GitHub-API-checkable subset
# of the OpenSSF Baseline (OSPS Baseline) checklist:
#   https://baseline.openssf.org/versions/2026-02-19-checklist.md
#
# Most OSPS Baseline items are documentation/policy items (a written
# vulnerability disclosure policy, a threat model, release signing
# practice, ...) that cannot be verified from repo settings alone. This
# script only checks the subset that maps to an actual GitHub API field;
# see the closing section of the generated report for what's out of scope.
#
# Requires: gh (authenticated, org member with admin/push access to get
# full security_and_analysis visibility), jq
#
# Usage:
#   ./check-repo-settings.sh              # audit every repo in managed-repos.yaml
#   ./check-repo-settings.sh <repo-name>  # audit a single repo (faster iteration)
set -uo pipefail

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$INFRA_ROOT/managed-repos.yaml"
POLICY="$INFRA_ROOT/repo-policy.yaml"
OUTPUT="$INFRA_ROOT/repo-settings-report.md"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "error: $MANIFEST not found — run ./update-managed-repos.sh first" >&2; exit 1; }

policy_category() { # $1 = repo name -> prints category, or "standard" if unlisted
  [ -f "$POLICY" ] || { echo "standard"; return; }
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    category:/ { print $2; matched=1; exit }
    END { if (!matched) print "standard" }
  ' "$POLICY"
}

policy_reason() { # $1 = repo name -> prints reason string, or "" if unlisted
  [ -f "$POLICY" ] || return
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    reason:/ { sub(/^    reason: /, ""); gsub(/^"|"$/, ""); print; exit }
  ' "$POLICY"
}

policy_field() { # $1 = repo name, $2 = field name (e.g. pages_branch) -> prints value, or "" if unset
  [ -f "$POLICY" ] || return
  awk -v want="$1" -v field="$2:" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && index($0, "    " field)==1 { print $2; exit }
  ' "$POLICY"
}

if [ $# -ge 1 ]; then
  REPOS=("$1")
else
  mapfile -t REPOS < <(grep -E '^  - name: ' "$MANIFEST" | sed 's/^  - name: //')
fi

SUMMARY_TMP="$(mktemp)"
DETAIL_TMP="$(mktemp)"
trap 'rm -f "$SUMMARY_TMP" "$DETAIL_TMP"' EXIT

# --- helpers ---------------------------------------------------------------

icon() { # $1 = "true"/"false"/anything else
  case "$1" in
    true) echo "✅" ;;
    false) echo "❌" ;;
    *) echo "❔" ;;
  esac
}

status_icon() { # $1 = "enabled"/"disabled"/anything else
  case "$1" in
    enabled) echo "✅" ;;
    disabled) echo "❌" ;;
    *) echo "❔" ;;
  esac
}

# gh api wrapper: prints body on stdout, always exits 0, sets body to '{}'
# on any non-2xx response so a missing branch-protection rule or a 403 from
# insufficient permissions never aborts the script.
api_json() { # $1 = api path
  local body
  body="$(gh api "$1" 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$body" ]; then
    echo '{}'
  else
    echo "$body"
  fi
}

api_status_code() { # $1 = api path -> prints HTTP status code only
  gh api -i "$1" 2>/dev/null | head -1 | awk '{print $2}'
}

contents_exists() { # $1 = path within repo, $2 = owner/repo
  local code
  code="$(api_status_code "repos/$2/contents/$1")"
  [ "$code" = "200" ]
}

echo "Auditing ${#REPOS[@]} repositories under github.com/${ORG} ..." >&2

# --- organization-level checks (apply to every repo, checked once) ---------

org_json="$(api_json "orgs/${ORG}")"
org_2fa="$(echo "$org_json" | jq -r '.two_factor_requirement_enabled')"
org_default_perm="$(echo "$org_json" | jq -r '.default_repository_permission // "unknown"')"

{
  echo "## Organization-level"
  echo
  echo "| Setting | Value | OSPS item |"
  echo "| --- | --- | --- |"
  echo "| Two-factor auth required org-wide | $(icon "$org_2fa") \`$org_2fa\` | OSPS-AC-01.01 |"
  echo "| Default repository permission for members | \`$org_default_perm\` | OSPS-AC-02.01 (lower is stricter; \`read\` or \`none\` preferred) |"
  echo
} > "$SUMMARY_TMP.org"

# --- summary table header ---------------------------------------------------

{
  echo "## Summary matrix (GitHub-API-checkable subset only)"
  echo
  echo "Full detail (team/collaborator lists, status-check names, per-repo OSPS table) is below the matrix, one section per repo."
  echo "🤖 in the Reviews column = repo is classified \`automated\` in [\`repo-policy.yaml\`](repo-policy.yaml); a low/zero review count there is expected, not a gap."
  echo "Merge cfg = how many of {squash merge, rebase merge, suggest-update-branch, delete-branch-on-merge, linear history, squash title = PR title, squash message = PR body} are on; full breakdown per repo below."
  echo
  echo "| Repo | Public | Protected | Reviews | Owners | No force-push | No delete | Checks | Secrets | Push guard | Dependabot | Vuln alerts | LICENSE | Merge cfg |"
  echo "| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |"
} > "$SUMMARY_TMP.header"

# --- per-repo audit -----------------------------------------------------------

for repo in "${REPOS[@]}"; do
  full="${ORG}/${repo}"
  echo "  - $full" >&2

  repo_json="$(api_json "repos/$full")"
  if [ "$(echo "$repo_json" | jq -r 'length')" = "0" ]; then
    echo "    (skipped: repo not found or inaccessible)" >&2
    continue
  fi

  visibility="$(echo "$repo_json" | jq -r '.visibility // "unknown"')"
  default_branch="$(echo "$repo_json" | jq -r '.default_branch // "main"')"
  # NOTE: deliberately not using jq's `//` for booleans below — it treats a
  # real `false` the same as `null`/missing, so e.g. `.enabled // true`
  # would silently flip an actual `false` (blocked) into `true` (allowed).
  # `if . == null` only substitutes the default when the field is genuinely
  # absent, so a real `false` survives.
  has_admin="$(echo "$repo_json" | jq -r '.permissions.admin | if . == null then false else . end')"
  secret_scanning="$(echo "$repo_json" | jq -r '.security_and_analysis.secret_scanning.status // "unknown"')"
  push_protection="$(echo "$repo_json" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"')"
  dependabot_sec="$(echo "$repo_json" | jq -r '.security_and_analysis.dependabot_security_updates.status // "unknown"')"

  # Classic branch protection AND effective ruleset rules are independent
  # mechanisms that both contribute to real enforcement (GitHub applies the
  # most restrictive of whatever either provides) — a repo can be fully
  # protected via a ruleset alone while classic protection reports nothing.
  # Every field below is the OR/max of both sources, not classic alone.
  bp_json="$(api_json "repos/$full/branches/$default_branch/protection")"
  rules_json="$(api_json "repos/$full/rules/branches/$default_branch")"
  [ "$(echo "$rules_json" | jq -r 'type')" = "array" ] || rules_json='[]'

  classic_has_protection="$([ "$(echo "$bp_json" | jq -r 'length')" != "0" ] && echo true || echo false)"
  rules_has_ruleset="$([ "$(echo "$rules_json" | jq -r 'length')" != "0" ] && echo true || echo false)"
  has_protection="$([ "$classic_has_protection" = "true" ] || [ "$rules_has_ruleset" = "true" ] && echo true || echo false)"

  classic_reviews="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
  rules_pr_params="$(echo "$rules_json" | jq -c '[.[] | select(.type=="pull_request")][0].parameters // {}')"
  rules_reviews="$(echo "$rules_pr_params" | jq -r '.required_approving_review_count // 0')"
  reviews_count=$(( classic_reviews > rules_reviews ? classic_reviews : rules_reviews ))

  classic_code_owner="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.require_code_owner_reviews | if . == null then false else . end')"
  rules_code_owner="$(echo "$rules_pr_params" | jq -r '.require_code_owner_review // false')"
  code_owner_review="$([ "$classic_code_owner" = "true" ] || [ "$rules_code_owner" = "true" ] && echo true || echo false)"

  classic_dismiss_stale="$(echo "$bp_json" | jq -r '.required_pull_request_reviews.dismiss_stale_reviews | if . == null then false else . end')"
  rules_dismiss_stale="$(echo "$rules_pr_params" | jq -r '.dismiss_stale_reviews_on_push // false')"
  dismiss_stale="$([ "$classic_dismiss_stale" = "true" ] || [ "$rules_dismiss_stale" = "true" ] && echo true || echo false)"

  enforce_admins="$(echo "$bp_json" | jq -r '.enforce_admins.enabled | if . == null then false else . end')"

  classic_allow_deletions="$(echo "$bp_json" | jq -r '.allow_deletions.enabled | if . == null then true else . end')"
  rules_blocks_deletion="$(echo "$rules_json" | jq -r 'any(.[]; .type=="deletion")')"
  allow_deletions="$([ "$classic_allow_deletions" = "false" ] || [ "$rules_blocks_deletion" = "true" ] && echo false || echo true)"

  classic_allow_force_pushes="$(echo "$bp_json" | jq -r '.allow_force_pushes.enabled | if . == null then true else . end')"
  rules_blocks_force_push="$(echo "$rules_json" | jq -r 'any(.[]; .type=="non_fast_forward")')"
  allow_force_pushes="$([ "$classic_allow_force_pushes" = "false" ] || [ "$rules_blocks_force_push" = "true" ] && echo false || echo true)"

  classic_linear_history="$(echo "$bp_json" | jq -r '.required_linear_history.enabled | if . == null then false else . end')"
  rules_linear_history="$(echo "$rules_json" | jq -r 'any(.[]; .type=="required_linear_history")')"
  linear_history="$([ "$classic_linear_history" = "true" ] || [ "$rules_linear_history" = "true" ] && echo true || echo false)"

  classic_status_checks_list="$(echo "$bp_json" | jq -c '[(.required_status_checks.checks // [])[].context] | unique')"
  rules_status_checks_list="$(echo "$rules_json" | jq -c '[.[] | select(.type=="required_status_checks")][0].parameters.required_status_checks // [] | map(.context)')"
  status_checks="$(jq -nr --argjson a "$classic_status_checks_list" --argjson b "$rules_status_checks_list" '($a + $b) | unique | if length == 0 then "(none)" else join(", ") end')"

  ruleset_names="$(gh api "repos/$full/rulesets" 2>/dev/null | jq -r '[.[] | select(.target=="branch" and .enforcement=="active") | .name] | if length == 0 then "" else join(", ") end')"

  allow_squash="$(echo "$repo_json" | jq -r '.allow_squash_merge | if . == null then false else . end')"
  allow_rebase="$(echo "$repo_json" | jq -r '.allow_rebase_merge | if . == null then false else . end')"
  allow_merge_commit="$(echo "$repo_json" | jq -r '.allow_merge_commit | if . == null then false else . end')"
  allow_update_branch="$(echo "$repo_json" | jq -r '.allow_update_branch | if . == null then false else . end')"
  delete_on_merge="$(echo "$repo_json" | jq -r '.delete_branch_on_merge | if . == null then false else . end')"
  squash_title="$(echo "$repo_json" | jq -r '.squash_merge_commit_title // "unknown"')"
  squash_message="$(echo "$repo_json" | jq -r '.squash_merge_commit_message // "unknown"')"

  vuln_status="$(api_status_code "repos/$full/vulnerability-alerts")"
  vuln_enabled=$([ "$vuln_status" = "204" ] && echo true || echo false)

  cs_json="$(api_json "repos/$full/code-scanning/default-setup")"
  cs_state="$(echo "$cs_json" | jq -r '.state // "unknown"')"

  community_json="$(api_json "repos/$full/community/profile")"
  has_license="$(echo "$community_json" | jq -r 'if .files.license != null then true else false end')"
  has_coc="$(echo "$community_json" | jq -r 'if .files.code_of_conduct != null then true else false end')"
  has_contributing="$(echo "$community_json" | jq -r 'if .files.contributing != null then true else false end')"

  teams_json="$(api_json "repos/$full/teams")"
  teams_list="$(echo "$teams_json" | jq -r '[.[] | "\(.slug) (\(.permission))"] | if length == 0 then "(none)" else join(", ") end')"

  outside_json="$(gh api -X GET "repos/$full/collaborators" -f affiliation=outside 2>/dev/null)"
  [ $? -eq 0 ] || outside_json='[]'
  outside_list="$(echo "$outside_json" | jq -r '[.[] | "\(.login) (\(if .permissions.admin then "admin" elif .permissions.maintain then "maintain" elif .permissions.push then "push" elif .permissions.triage then "triage" else "read" end))"] | if length == 0 then "(none)" else join(", ") end')"

  direct_json="$(gh api -X GET "repos/$full/collaborators" -f affiliation=direct 2>/dev/null)"
  [ $? -eq 0 ] || direct_json='[]'
  direct_list="$(echo "$direct_json" | jq -r '[.[] | "\(.login) (\(if .permissions.admin then "admin" elif .permissions.maintain then "maintain" elif .permissions.push then "push" elif .permissions.triage then "triage" else "read" end))"] | if length == 0 then "(none)" else join(", ") end')"

  codeowners_exists=false
  if contents_exists "CODEOWNERS" "$full" || contents_exists ".github/CODEOWNERS" "$full"; then
    codeowners_exists=true
  fi

  category="$(policy_category "$repo")"
  reason="$(policy_reason "$repo")"

  pages_expected="$(policy_field "$repo" pages_enabled)"
  if [ "$pages_expected" = "true" ]; then
    pages_expected_build_type="$(policy_field "$repo" pages_build_type)"
    pages_expected_branch="$(policy_field "$repo" pages_branch)"
    pages_expected_path="$(policy_field "$repo" pages_path)"
    pages_expected_cname="$(policy_field "$repo" pages_cname)"
    pages_json="$(api_json "repos/$full/pages")"
    pages_actual_build_type="$(echo "$pages_json" | jq -r '.build_type // "unknown"')"
    pages_actual_branch="$(echo "$pages_json" | jq -r '.source.branch // "unknown"')"
    pages_actual_path="$(echo "$pages_json" | jq -r '.source.path // "unknown"')"
    pages_actual_cname="$(echo "$pages_json" | jq -r '.cname // ""')"
    pages_actual_enabled="$([ "$(echo "$pages_json" | jq -r 'length')" != "0" ] && echo true || echo false)"
    pages_drift=false
    [ "$pages_actual_enabled" != "true" ] && pages_drift=true
    [ "$pages_actual_build_type" != "$pages_expected_build_type" ] && pages_drift=true
    [ "$pages_actual_branch" != "$pages_expected_branch" ] && pages_drift=true
    [ -n "$pages_expected_cname" ] && [ "$pages_actual_cname" != "$pages_expected_cname" ] && pages_drift=true
  fi

  # --- summary row -----------------------------------------------------------
  status_checks_count="$([ "$status_checks" = "(none)" ] && echo 0 || echo "$status_checks" | tr ',' '\n' | wc -l | tr -d ' ')"
  reviews_cell="$([ "$reviews_count" -ge 1 ] 2>/dev/null && echo "✅$reviews_count" || echo "❌0")"
  [ "$category" = "automated" ] && reviews_cell="🤖$reviews_count"
  merge_cfg_score=0
  for v in "$allow_squash" "$allow_rebase" "$allow_update_branch" "$delete_on_merge" "$linear_history"; do
    [ "$v" = "true" ] && merge_cfg_score=$((merge_cfg_score + 1))
  done
  [ "$squash_title" = "PR_TITLE" ] && merge_cfg_score=$((merge_cfg_score + 1))
  [ "$squash_message" = "PR_BODY" ] && merge_cfg_score=$((merge_cfg_score + 1))
  merge_cfg_cell="$([ "$merge_cfg_score" -eq 7 ] && echo "✅7/7" || echo "⚠️${merge_cfg_score}/7")"
  {
    printf '| [%s](#%s) | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$repo" "$(echo "$repo" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')" \
      "$(icon "$([ "$visibility" = "public" ] && echo true || echo false)")" \
      "$(icon "$has_protection")" \
      "$reviews_cell" \
      "$(icon "$code_owner_review")" \
      "$(icon "$([ "$allow_force_pushes" = "false" ] && echo true || echo false)")" \
      "$(icon "$([ "$allow_deletions" = "false" ] && echo true || echo false)")" \
      "$([ "$status_checks_count" -ge 1 ] 2>/dev/null && echo "✅$status_checks_count" || echo "❌0")" \
      "$(status_icon "$secret_scanning")" \
      "$(status_icon "$push_protection")" \
      "$(status_icon "$dependabot_sec")" \
      "$(icon "$vuln_enabled")" \
      "$(icon "$has_license")" \
      "$merge_cfg_cell"
  } >> "$SUMMARY_TMP.rows"

  # --- detail section ---------------------------------------------------------
  {
    echo "### $repo"
    echo
    echo "<https://github.com/$full> — visibility: \`$visibility\`, default branch: \`$default_branch\`$( [ "$has_admin" != "true" ] && echo " — ⚠️ auditing token lacks admin access here, security_and_analysis fields may be incomplete" )"
    if [ "$category" != "standard" ]; then
      echo
      echo "> 🤖 **Category: $category** (see [\`repo-policy.yaml\`](repo-policy.yaml)) — $reason"
    fi
    echo
    echo "**Access**"
    echo "- Teams: $teams_list"
    echo "- Outside collaborators (non-org members — review these first): $outside_list"
    echo "- Direct collaborators (repo-specific grant, bypasses team access): $direct_list"
    echo "- CODEOWNERS present on default branch: $(icon "$codeowners_exists")"
    echo
    echo "**Branch protection ($default_branch)** — combined view: classic protection OR any active branch ruleset, whichever is stricter per field"
    echo "- Protected: $(icon "$has_protection")$([ -n "$ruleset_names" ] && echo " (active branch ruleset(s): $ruleset_names)")"
    echo "- Required approving reviews: $reviews_count"
    echo "- Require code owner review: $(icon "$code_owner_review")"
    echo "- Dismiss stale reviews on new commits: $(icon "$dismiss_stale")"
    echo "- Enforced for admins too: $(icon "$enforce_admins")"
    echo "- Force pushes blocked: $(icon "$([ "$allow_force_pushes" = "false" ] && echo true || echo false)")"
    echo "- Branch deletion blocked: $(icon "$([ "$allow_deletions" = "false" ] && echo true || echo false)")"
    echo "- Linear history required: $(icon "$linear_history")"
    echo "- Required status checks: $status_checks"
    echo
    echo "**Merge & branch settings**"
    echo "- Allow squash merging: $(icon "$allow_squash")"
    echo "- Allow rebase merging: $(icon "$allow_rebase")"
    echo "- Allow merge commit: $(icon "$allow_merge_commit")$([ "$linear_history" = "true" ] && [ "$allow_merge_commit" = "true" ] && echo " (offered in the UI, but blocked from actually landing by linear-history above)")"
    echo "- Always suggest updating PR branches: $(icon "$allow_update_branch")"
    echo "- Automatically delete head branches: $(icon "$delete_on_merge")"
    echo "- Squash commit title = PR title: $(icon "$([ "$squash_title" = "PR_TITLE" ] && echo true || echo false)") (\`$squash_title\`)"
    echo "- Squash commit message = PR body: $(icon "$([ "$squash_message" = "PR_BODY" ] && echo true || echo false)") (\`$squash_message\`)"
    echo
    if [ "$pages_expected" = "true" ]; then
      echo "**GitHub Pages** (expected per [\`repo-policy.yaml\`](repo-policy.yaml))"
      echo "- Enabled: $(icon "$pages_actual_enabled") (expected: true)"
      echo "- Build type: \`$pages_actual_build_type\` (expected: \`$pages_expected_build_type\`)"
      echo "- Source: \`$pages_actual_branch$pages_actual_path\` (expected: \`$pages_expected_branch$pages_expected_path\`)"
      [ -n "$pages_expected_cname" ] && echo "- Custom domain: \`$pages_actual_cname\` (expected: \`$pages_expected_cname\`)"
      if [ "$pages_drift" = "true" ]; then
        echo "- ⚠️ **Drift detected** — live config doesn't match what's documented in repo-policy.yaml. Not auto-fixed (see that file's note on why Pages config is audit-only)."
      fi
      echo
    fi
    echo "**Security features**"
    echo "- Secret scanning: $(status_icon "$secret_scanning") \`$secret_scanning\`"
    echo "- Secret scanning push protection: $(status_icon "$push_protection") \`$push_protection\`"
    echo "- Dependabot security updates: $(status_icon "$dependabot_sec") \`$dependabot_sec\`"
    echo "- Dependabot vulnerability alerts: $(icon "$vuln_enabled")"
    echo "- Code scanning default setup: \`$cs_state\` (only detects the *default* CodeQL setup — a repo using a custom/advanced code-scanning workflow will show \`not-configured\` here even if SAST actually runs; verify manually before treating this as a hard fail)"
    echo
    echo "**Community health files (default branch)**"
    echo "- LICENSE: $(icon "$has_license")"
    echo "- CODE_OF_CONDUCT: $(icon "$has_coc")"
    echo "- CONTRIBUTING: $(icon "$has_contributing")"
    echo
    echo "**OSPS Baseline — checkable subset**"
    echo
    echo "| OSPS item | Requirement | Status |"
    echo "| --- | --- | --- |"
    echo "| OSPS-QA-01.01 | Repo publicly readable | $(icon "$([ "$visibility" = "public" ] && echo true || echo false)") |"
    if [ "$category" = "automated" ]; then
      echo "| OSPS-AC-03.01 | Direct commits to primary branch prevented | 🤖 N/A — automated repo, see category note above |"
      echo "| OSPS-QA-07.01 | ≥1 non-author approval required | 🤖 N/A — automated repo, see category note above |"
    else
      echo "| OSPS-AC-03.01 | Direct commits to primary branch prevented | $(icon "$has_protection")$([ "$has_protection" = "true" ] && [ "$reviews_count" -lt 1 ] 2>/dev/null && echo " ⚠️ protection exists but 0 required reviews")|"
      echo "| OSPS-QA-07.01 | ≥1 non-author approval required | $([ "$reviews_count" -ge 1 ] 2>/dev/null && echo "✅ ($reviews_count)" || echo "❌") |"
    fi
    echo "| OSPS-AC-03.02 | Primary branch deletion prevented | $(icon "$([ "$allow_deletions" = "false" ] && echo true || echo false)") |"
    echo "| OSPS-QA-03.01 | Automated status checks required before merge | $(icon "$([ "$status_checks" != "(none)" ] && echo true || echo false)") |"
    echo "| OSPS-BR-07.01 | Secret scanning enabled | $(status_icon "$secret_scanning") |"
    echo "| OSPS-VM-05.03 | Automated dependency vuln. blocking (Dependabot) | $(icon "$vuln_enabled")$([ "$dependabot_sec" != "enabled" ] && echo " ⚠️ security updates not auto-applied")|"
    echo "| OSPS-VM-06.02 | Automated SAST blocking | \`$cs_state\` (default-setup only, see note above) |"
    echo "| OSPS-LE-03.01 | LICENSE file present | $(icon "$has_license") |"
    echo "| OSPS-AC-02.01 | New-collaborator access is least-privilege | $([ "$outside_list" = "(none)" ] && echo "✅ no outside collaborators" || echo "⚠️ review: $outside_list") |"
    echo
  } >> "$DETAIL_TMP"
done

# --- assemble final report ---------------------------------------------------

{
  echo "# CloudNativePG org — repository settings & OSPS Baseline audit"
  echo
  echo "Generated by \`./check-repo-settings.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  echo "Source of repo list: [\`managed-repos.yaml\`](managed-repos.yaml) (${#REPOS[@]} repos requested)."
  echo "Reference: [OpenSSF Baseline checklist, 2026-02-19 revision](https://baseline.openssf.org/versions/2026-02-19-checklist.md)."
  echo
  echo "> **Scope note:** the OSPS Baseline is mostly a documentation/process"
  echo "> standard (published security policy, threat model, release-signing"
  echo "> practice, SBOM, dependency-tracking docs, ...). Of its ~55 items, only"
  echo "> the ones with a real GitHub-API equivalent are checked below — everything"
  echo "> else needs a human to read the actual policy documents. See \"Not covered"
  echo "> by this script\" at the bottom."
  echo
  cat "$SUMMARY_TMP.org"
  cat "$SUMMARY_TMP.header"
  cat "$SUMMARY_TMP.rows" 2>/dev/null
  echo
  echo "## Per-repository detail"
  echo
  cat "$DETAIL_TMP"
  echo "## Not covered by this script (OSPS Baseline items needing manual/doc review)"
  echo
  echo "These require reading actual policy documents, not repo settings, so they"
  echo "are out of scope for an API-driven script. Check them by hand against"
  echo "[the checklist](https://baseline.openssf.org/versions/2026-02-19-checklist.md):"
  echo
  echo "- **Governance/process docs**: contribution guide, member/role list,"
  echo "  escalated-permission review policy, public-discussion mechanism"
  echo "  (GV-01.*, GV-02.01, GV-03.*, GV-04.01)."
  echo "- **Vulnerability management policy**: disclosure policy with a timeframe,"
  echo "  private reporting channel, public vuln. data, SCA/SAST remediation"
  echo "  thresholds (VM-01.01, VM-03.01, VM-04.*, VM-05.*, VM-06.01)."
  echo "- **Release practice**: unique version identifiers, signed releases/hashes,"
  echo "  SBOM, changelogs, integrity-verification instructions, support/EOL"
  echo "  statements (BR-02.*, BR-04.01, BR-06.01, DO-03.*, DO-04.01, DO-05.01,"
  echo "  QA-02.02)."
  echo "- **CI/CD pipeline hardening**: untrusted-input sanitization, least-"
  echo "  privilege job permissions, standardized dependency tooling"
  echo "  (BR-01.*, AC-04.*, BR-05.01) — needs reading the actual workflow YAML,"
  echo "  not just repo settings."
  echo "- **Documentation quality**: user guides, build instructions, design docs,"
  echo "  external-interface docs, security assessment/threat model"
  echo "  (DO-01.01, DO-06.01, DO-07.01, SA-01.01, SA-02.01, SA-03.*)."
  echo "- **Repository hygiene**: no generated binaries/executables committed"
  echo "  (QA-05.01, QA-05.02) — needs a contents audit, not a settings check."
  echo "- **Legal**: license text actually meets OSI/FSF definitions, not just"
  echo "  \"a LICENSE file exists\" (LE-02.*)."
  echo "- **DCO enforcement (LE-01.01)**: this script does not confirm a DCO"
  echo "  check is wired in — \`required_status_checks\` is listed above per repo,"
  echo "  so cross-check by eye for a check literally named \`DCO\`. Its absence"
  echo "  from the list does not necessarily mean sign-off isn't required, only"
  echo "  that it isn't enforced as a required PR status check."
} > "$OUTPUT"

echo "Wrote report for ${#REPOS[@]} repositories to $OUTPUT" >&2
