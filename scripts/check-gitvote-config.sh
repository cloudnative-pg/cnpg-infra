#!/usr/bin/env bash
#
# Audits each repo in managed-repos.yaml's .gitvote.yml against the
# baseline gitvote-policy.yaml describes (see that file's header), and
# reports the org-wide gitvote GitHub App installation once.
#
# gitvote (github.com/cncf/gitvote) is already installed org-wide with
# repository_selection: "all" -- every managed repo, current and future,
# already has the app. There is no per-repo "install" gap this script
# could ever find; it only checks .gitvote.yml content.
#
# Requires: gh (authenticated), jq
#
# Usage:
#   ./check-gitvote-config.sh              # audit every repo in managed-repos.yaml
#   ./check-gitvote-config.sh <repo-name>  # audit a single repo (faster iteration)
set -uo pipefail

# See check-repo-settings.sh's header for why these are unset -- gh
# colorizes JSON whenever either is set, even into a pipe, and jq chokes
# on the ANSI escapes.
unset CLICOLOR_FORCE
unset GH_FORCE_TTY

ORG="cloudnative-pg"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$INFRA_ROOT/generated/managed-repos.yaml"
OUTPUT="$INFRA_ROOT/gitvote-config-report.md"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "error: $MANIFEST not found -- run ./update-managed-repos.sh first" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/render-gitvote-config.sh"

if [ $# -ge 1 ]; then
  REPOS=("$1")
else
  mapfile -t REPOS < <(grep -E '^  - name: ' "$MANIFEST" | sed 's/^  - name: //')
fi

api_json() { # $1 = api path -> body on stdout, always exits 0, '{}' on failure
  local body
  body="$(gh api "$1" 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$body" ]; then echo '{}'; else echo "$body"; fi
}

api_raw() { # $1 = contents api path -> file body verbatim, empty on failure
  gh api "$1" -H "Accept: application/vnd.github.raw" 2>/dev/null
}

contents_exists() { # $1 = path within repo, $2 = owner/repo
  local code
  code="$(gh api -i "repos/$2/contents/$1" 2>/dev/null | head -1 | awk '{print $2}')"
  [ "$code" = "200" ]
}

echo "Auditing ${#REPOS[@]} repositories' .gitvote.yml under github.com/${ORG} ..." >&2

# --- org-level: confirm gitvote's installation scope once -----------------
install_json="$(api_json "orgs/${ORG}/installations")"
gitvote_install="$(echo "$install_json" | jq -c '[.installations[]? | select(.app_slug=="git-vote")][0] // {}')"
gitvote_selection="$(echo "$gitvote_install" | jq -r '.repository_selection // "unknown"')"
gitvote_suspended="$(echo "$gitvote_install" | jq -r '.suspended_at != null')"

SUMMARY_TMP="$(mktemp)"
DETAIL_TMP="$(mktemp)"
trap 'rm -f "$SUMMARY_TMP" "$DETAIL_TMP"' EXIT

{
  echo "| Repo | Category | .gitvote.yml present | Matches policy | Voter team(s) exist |"
  echo "| --- | --- | :-: | :-: | :-: |"
} > "$SUMMARY_TMP"

for repo in "${REPOS[@]}"; do
  full="${ORG}/${repo}"
  echo "  - $full" >&2

  category="$(gitvote_policy_category "$repo")"
  excluded="$(gitvote_policy_excluded "$repo")"
  reason="$(gitvote_policy_reason "$repo")"

  present=false
  contents_exists ".gitvote.yml" "$full" && present=true

  actual=""
  [ "$present" = "true" ] && actual="$(api_raw "repos/$full/contents/.gitvote.yml")"

  expected="$(render_gitvote_config "$repo" "$category")"

  drift="unknown"
  if [ "$present" = "true" ] && [ -n "$actual" ]; then
    if [ "$(echo "$actual" | tr -d '\r' | sed 's/[[:space:]]*$//')" = "$(echo "$expected" | tr -d '\r' | sed 's/[[:space:]]*$//')" ]; then
      drift=false
    else
      drift=true
    fi
  elif [ "$present" = "false" ]; then
    drift=true
  fi

  # --- do the voter team(s) this repo's rendered config names actually
  #     exist on GitHub? A typo'd or not-yet-created team means gitvote
  #     silently falls back to "all repository collaborators" -- exactly
  #     the bug already found and fixed in governance's own .gitvote.yml.
  mapfile -t voter_teams < <(gitvote_voter_teams "$repo" "$category")
  teams_ok=true
  missing_teams=()
  for t in "${voter_teams[@]}"; do
    gh api "orgs/${ORG}/teams/${t}" >/dev/null 2>&1 || { teams_ok=false; missing_teams+=("$t"); }
  done

  present_cell="❌"; [ "$present" = "true" ] && present_cell="✅"
  drift_cell="❔"
  case "$drift" in
    false) drift_cell="✅" ;;
    true) drift_cell="❌" ;;
  esac
  teams_cell="✅"; [ "$teams_ok" = "false" ] && teams_cell="❌ ${missing_teams[*]}"
  [ "$excluded" = "true" ] && { drift_cell="🚫 excluded"; }

  printf '| [%s](#%s) | %s | %s | %s | %s |\n' \
    "$repo" "$(echo "$repo" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')" \
    "${category:-default}" "$present_cell" "$drift_cell" "$teams_cell" >> "$SUMMARY_TMP"

  {
    echo "### $repo"
    echo
    echo "Category: \`${category:-default}\`$([ "$excluded" = "true" ] && echo " -- **excluded** (see gitvote-policy.yaml): $reason")"
    echo "Voter team(s) expected: $(printf '`%s` ' "${voter_teams[@]}")"
    [ "$teams_ok" = "false" ] && echo "- ⚠️ **team(s) not found on GitHub**: ${missing_teams[*]} -- gitvote falls back to \"all repository collaborators\" for a rule naming a team that doesn't exist, silently"
    echo "- .gitvote.yml present on default branch: $present_cell"
    if [ "$excluded" != "true" ]; then
      case "$drift" in
        false) echo "- Matches rendered policy: ✅" ;;
        true) echo "- Matches rendered policy: ❌ **drift** -- regenerate with \`./fix-gitvote-config.sh $repo\` (dry run first)" ;;
        *) echo "- Matches rendered policy: ❔ (fetch failed, retry)" ;;
      esac
    fi
    echo
  } >> "$DETAIL_TMP"
done

{
  echo "# CloudNativePG org -- gitvote configuration audit"
  echo
  echo "Generated by \`./check-gitvote-config.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  echo "Source of repo list: [\`generated/managed-repos.yaml\`](generated/managed-repos.yaml) (${#REPOS[@]} repos requested)."
  echo
  echo "## gitvote app installation (org-level, checked once)"
  echo
  echo "- App: \`git-vote\`"
  echo "- Repository selection: \`$gitvote_selection\`$([ "$gitvote_selection" = "all" ] && echo " -- covers every current and future repo in the org; there is no per-repo install gap to report below")"
  echo "- Suspended: $gitvote_suspended$([ "$gitvote_suspended" = "true" ] && echo " ⚠️ **the app is suspended org-wide -- no vote in any repo will work until this is lifted**")"
  echo
  echo "## Per-repo .gitvote.yml"
  echo
  cat "$SUMMARY_TMP"
  echo
  echo "## Detail"
  echo
  cat "$DETAIL_TMP"
} > "$OUTPUT"

echo "Wrote report for ${#REPOS[@]} repositories to $OUTPUT" >&2
