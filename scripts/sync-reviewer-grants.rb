#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Reconciles the repository access that Reviewers need, against the people
# named individually in componentowners-policy.yaml's path rules.
#
# governance/CONTRIBUTOR_LADDER.md's rule is that a team named in
# CODEOWNERS means ownership and an individual named there means review.
# This script is what makes the second half work, because GitHub ignores a
# CODEOWNERS entry for anyone without Write -- silently, with the line
# still looking correct. Every individual a path rule names therefore needs
# Write on that repository, or the rule does nothing.
#
# It has to grant that directly rather than through a team, because the
# rung deliberately implies no organisation membership and GitHub teams can
# only contain organisation members. That is why this is a separate script
# from sync-project-owner-teams.sh, which manages the <repo>-owners teams.
#
# There is no separate list of Reviewers to keep in step: the CODEOWNERS
# policy is the list. Anyone named on a path is a Reviewer of it, which is
# exactly what the ladder says, and cannot drift from what the rendered
# CODEOWNERS will contain.
#
# Never revokes. A direct grant this script did not plan is reported as
# drift and left alone: it may be a Reviewer mid-removal, a legacy grant,
# or someone who needs access for a reason no policy file knows. Removing
# access is a decision, not a reconciliation.
#
# Requires: gh (authenticated, admin on the target repos)
#
# Usage:
#   ruby scripts/sync-reviewer-grants.rb                    # dry run, all repos
#   ruby scripts/sync-reviewer-grants.rb <repo>             # dry run, one repo
#   ruby scripts/sync-reviewer-grants.rb [<repo>] --apply   # actually grant

require "yaml"
require "json"
require "open3"

ORG = "cloudnative-pg"
INFRA_ROOT = File.expand_path("..", __dir__)
COMPONENTOWNERS = File.join(INFRA_ROOT, "componentowners-policy.yaml")
TIERS = File.join(INFRA_ROOT, "repo-tiers.yaml")
MANIFEST = File.join(INFRA_ROOT, "generated", "managed-repos.yaml")

apply = !ARGV.delete("--apply").nil?
target_repo = ARGV.first

managed = YAML.load_file(MANIFEST).fetch("repositories", []).map { |r| r["name"] }
owners = YAML.load_file(TIERS).fetch("repositories", [])
             .to_h { |r| [r["name"], Array(r["owners"])] }
policy = YAML.load_file(COMPONENTOWNERS).fetch("repositories", [])

if target_repo && !managed.include?(target_repo)
  warn "error: '#{target_repo}' is not in managed-repos.yaml -- refusing to touch a repo outside the managed scope."
  exit 1
end

def gh(*args)
  out, err, status = Open3.capture3("gh", *args)
  [status.success? ? out : nil, err]
end

# repo => { user => [paths they are named on] }
reviewers = Hash.new { |h, k| h[k] = Hash.new { |i, j| i[j] = [] } }
policy.each do |entry|
  repo = entry["name"]
  next unless managed.include?(repo)

  Array(entry["rules"]).each do |rule|
    Array(rule["users"]).each { |u| reviewers[repo][u] << rule["path"] }
  end
end

repos = target_repo ? [target_repo] : reviewers.keys.sort
planned = 0
failures = 0

repos.each do |repo|
  wanted = reviewers[repo]
  next if wanted.empty?

  puts "=== #{repo}"

  # Anyone who is also an owner already has access through the
  # <repo>-owners team; naming them on a path is review routing on top of
  # ownership, not a reason for a second, direct grant.
  wanted.each do |user, paths|
    if owners.fetch(repo, []).include?(user)
      puts "  #{user}: owner, access comes from the team (named on #{paths.join(', ')})"
      next
    end

    perm_raw, = gh("api", "repos/#{ORG}/#{repo}/collaborators/#{user}/permission",
                   "--jq", ".permission")
    perm = perm_raw&.strip

    if %w[write admin maintain].include?(perm)
      puts "  #{user}: has #{perm} (named on #{paths.join(', ')})"
      next
    end

    planned += 1
    puts "  #{user}: #{perm || 'no access'} -> push   (named on #{paths.join(', ')})"
    next unless apply

    _, err = gh("api", "-X", "PUT", "repos/#{ORG}/#{repo}/collaborators/#{user}",
                "-f", "permission=push")
    if err && !err.empty? && !err.include?("201") && !err.include?("204")
      warn "    failed: #{err.lines.first&.strip}"
      failures += 1
    end
  end

  # Drift: a direct grant at write or above that no CODEOWNERS rule
  # explains. The filter has to ride in the query string -- `gh api -f` on a
  # GET sends a body field, which this endpoint ignores, so asking that way
  # silently returns every collaborator instead of the direct ones. Read-level
  # direct grants are left out: on a public repository they confer nothing,
  # and listing them would bury the ones that matter.
  direct_raw, = gh("api", "--paginate",
                   "repos/#{ORG}/#{repo}/collaborators?affiliation=direct",
                   "--jq", ".[] | select(.role_name != \"read\") | .login + \"=\" + .role_name")
  Array(direct_raw&.lines).map(&:strip).reject(&:empty?).each do |line|
    login, role = line.split("=", 2)
    next if wanted.key?(login) || owners.fetch(repo, []).include?(login)

    puts "  #{login}: direct #{role} grant, no CODEOWNERS rule explains it (left alone)"
  end
end

puts
if planned.zero?
  puts "Nothing to grant -- every individual named in CODEOWNERS already has access."
elsif apply
  puts "Granted #{planned}#{failures.positive? ? ", #{failures} failed" : ''}."
else
  puts "#{planned} grant(s) planned. Dry run only -- re-run with --apply."
end
exit(failures.positive? ? 1 : 0)
