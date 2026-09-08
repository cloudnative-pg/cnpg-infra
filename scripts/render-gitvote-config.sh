#!/usr/bin/env bash
#
# Renders the desired .gitvote.yml content for one managed repo, per
# gitvote-policy.yaml. Shared by check-gitvote-config.sh (diffs it against
# the live file) and fix-gitvote-config.sh (lands it) -- kept in one place
# so the two scripts can never disagree on what "correct" looks like.
#
# Can also be run standalone to preview a repo's rendered file:
#   ./render-gitvote-config.sh <repo-name>
#
# No GitHub API calls, no credentials needed -- pure text rendering from
# the policy files already checked into this repo.
set -uo pipefail

GITVOTE_INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITVOTE_POLICY="$GITVOTE_INFRA_ROOT/gitvote-policy.yaml"

gitvote_policy_category() { # $1 = repo name -> category, or "" if unlisted
  [ -f "$GITVOTE_POLICY" ] || return
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    category:/ { print $2; exit }
  ' "$GITVOTE_POLICY"
}

gitvote_policy_excluded() { # $1 = repo name -> "true" or "false"
  [ -f "$GITVOTE_POLICY" ] && awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    excluded: true/ { print "true"; found=1; exit }
    END { if (!found) print "false" }
  ' "$GITVOTE_POLICY" || echo "false"
}

gitvote_policy_reason() { # $1 = repo name -> reason string, or "" if unlisted
  [ -f "$GITVOTE_POLICY" ] || return
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    reason:/ { sub(/^    reason: /, ""); gsub(/^"|"$/, ""); print; exit }
  ' "$GITVOTE_POLICY"
}

gitvote_policy_voters_override() { # $1 = repo name -> one team slug per line, empty if none set
  [ -f "$GITVOTE_POLICY" ] || return
  awk -v want="$1" '
    /^  - name: / { name=$3; found_name=(name==want) }
    found_name && /^    allowed_voters_teams:/ {
      line=$0
      sub(/^    allowed_voters_teams: \[/, "", line)
      sub(/\]$/, "", line)
      gsub(/ /, "", line)
      n = split(line, arr, ",")
      for (i = 1; i <= n; i++) if (arr[i] != "") print arr[i]
      exit
    }
  ' "$GITVOTE_POLICY"
}

team_slug_for() { # $1 = repo name -> "<repo>-owners" slug (matches sync-project-owner-teams.sh)
  local base="${1#.}" # strip a leading "." (.github -> github, .project -> project)
  echo "${base}-owners" | tr '.' '-'
}

gitvote_voter_teams() { # $1 = repo, $2 = category -> one team slug per line
  local repo="$1" category="$2"
  mapfile -t override < <(gitvote_policy_voters_override "$repo")
  if [ "${#override[@]}" -gt 0 ]; then
    printf '%s\n' "${override[@]}"
    return
  fi
  if [ "$category" = "org-control" ]; then
    echo "steering-committee"
  else
    team_slug_for "$repo"
  fi
}

render_gitvote_config() { # $1 = repo, $2 = category (may be empty)
  local repo="$1" category="$2"
  mapfile -t teams < <(gitvote_voter_teams "$repo" "$category")
  # Multi-line "        - team" block, one per voter team -- almost always
  # just one, but gitvote-policy.yaml's allowed_voters_teams override can
  # list more, and this renders every one of them rather than silently
  # keeping only the first.
  local team_lines team="${teams[0]}"
  team_lines="$(printf '        - %s\n' "${teams[@]}")"

  if [ "$category" = "org-control" ]; then
    cat <<EOF
# GitVote configuration for cloudnative-pg/${repo}.
#
# Rendered by cnpg-infra's scripts/render-gitvote-config.sh -- see
# cnpg-infra's gitvote-policy.yaml and scripts/check-gitvote-config.sh /
# fix-gitvote-config.sh for how this file is generated and enforced.
#
# One of the five org-control repos (governance, .project, .github,
# cnpg-infra, cnpg-template) -- Steering Committee business, not a
# subproject's. Voters are the steering-committee GitHub team (see
# org-policy.yaml's steering_committee field); membership is today's 5
# core maintainers, pending ratification of the federated governance
# model (governance's dev/67 and dev/70).
automation:
  enabled: false
  rules:
    - patterns: []
      profile: default

profiles:
  default:
    duration: 1w
    pass_threshold: 50
    allowed_voters:
      teams:
${team_lines}
      users: []
    close_on_passing: true
    close_on_passing_min_wait: "10 minutes"

  steering:
    duration: 1w
    pass_threshold: 66
    allowed_voters:
      teams:
${team_lines}
      users: []
    close_on_passing: true
    close_on_passing_min_wait: "10 minutes"
EOF
  else
    cat <<EOF
# GitVote configuration for cloudnative-pg/${repo}.
#
# Rendered by cnpg-infra's scripts/render-gitvote-config.sh -- see
# cnpg-infra's gitvote-policy.yaml and scripts/check-gitvote-config.sh /
# fix-gitvote-config.sh for how this file is generated and enforced.
#
# Voters are this repository's own ${team} GitHub team (repo-tiers.yaml's
# owners field is what populates it; see sync-project-owner-teams.sh).
# Component Owner-level decisions per CONTRIBUTOR_LADDER.md are scoped to
# the repository, not org-wide. The two profiles below mirror
# CONTRIBUTOR_LADDER.md's two repository-level thresholds:
#   - default:         simple majority, Contributor promotion/removal
#   - component-owner:  two-thirds majority, Component Owner
#                        promotion/removal (/vote-component-owner)
automation:
  enabled: false
  rules:
    - patterns: []
      profile: default

profiles:
  default:
    duration: 1w
    pass_threshold: 50
    allowed_voters:
      teams:
${team_lines}
      users: []
    close_on_passing: true
    close_on_passing_min_wait: "10 minutes"

  component-owner:
    duration: 1w
    pass_threshold: 66
    allowed_voters:
      teams:
${team_lines}
      users: []
    close_on_passing: true
    close_on_passing_min_wait: "10 minutes"
EOF
  fi
}

# --- standalone mode: print one repo's rendered content ------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "usage: $0 <repo-name>" >&2
    exit 1
  fi
  render_gitvote_config "$repo" "$(gitvote_policy_category "$repo")"
fi
