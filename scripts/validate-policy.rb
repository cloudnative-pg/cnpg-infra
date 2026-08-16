#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Static validation of this repo's hand-maintained and generated YAML
# policy files -- no GitHub API calls, no credentials needed, safe to run
# in CI (see README's "Philosophy: laptop, not CI" -- anything that reads
# or writes live GitHub state stays laptop-only; this script only ever
# reads files already checked into the repo).
#
# Checks:
#   1. Every YAML file parses.
#   2. Every repo in generated/managed-repos.yaml has an entry in
#      repo-tiers.yaml and componentowners-policy.yaml.
#   3. repo-tiers.yaml's class/subproject values are from the documented
#      enum, not a typo.
#   4. Every team slug referenced anywhere (componentowners-policy.yaml's
#      `teams:` lists, repo-policy.yaml's `ruleset_bypass_teams`,
#      org-policy.yaml's global_admin_teams/global_maintain_teams/
#      subproject_committees) actually exists in generated/teams.yaml's
#      last snapshot. This is what would have caught two real typos hit
#      earlier in this project's life: "postgres-extensions-containers-
#      ownersa" and "admin" (singular) instead of "admins".
#   5. Every componentowners-policy.yaml entry has a "*" rule, and that
#      rule comes first.
#   6. Every repo referenced in milestones-policy.yaml is one this
#      workspace actually manages (generated/managed-repos.yaml).
#
# Check 4 is only as fresh as generated/teams.yaml's last regeneration
# (scripts/update-teams.sh) -- a team created on GitHub but not yet synced
# into that snapshot will show as "unknown" here until the snapshot is
# refreshed. That's a deliberate tradeoff for staying credential-free.
#
# Usage: ruby scripts/validate-policy.rb
# Exit status: 0 if everything passes, 1 if any check fails.

require "yaml"

INFRA_ROOT = File.expand_path("..", __dir__)
errors = []

def load_yaml(path, errors)
  YAML.load_file(path)
rescue Psych::SyntaxError => e
  errors << "#{path}: YAML syntax error -- #{e.message}"
  nil
end

files = {
  managed_repos: File.join(INFRA_ROOT, "generated", "managed-repos.yaml"),
  teams: File.join(INFRA_ROOT, "generated", "teams.yaml"),
  tiers: File.join(INFRA_ROOT, "repo-tiers.yaml"),
  componentowners: File.join(INFRA_ROOT, "componentowners-policy.yaml"),
  org_policy: File.join(INFRA_ROOT, "org-policy.yaml"),
  repo_policy: File.join(INFRA_ROOT, "repo-policy.yaml"),
  milestones_policy: File.join(INFRA_ROOT, "milestones-policy.yaml"),
}

files.each_value { |path| errors << "#{path}: file not found" unless File.file?(path) }
if errors.any?
  warn "Policy validation FAILED:"
  errors.each { |e| warn "  - #{e}" }
  exit 1
end

data = files.transform_values { |path| load_yaml(path, errors) }

if errors.empty?
  managed_repo_names = data[:managed_repos].fetch("repositories", []).map { |r| r["name"] }
  tier_repo_names = data[:tiers].fetch("repositories", []).map { |r| r["name"] }
  componentowners_names = data[:componentowners].fetch("repositories", []).map { |r| r["name"] }
  known_team_slugs = data[:teams].fetch("teams", []).map { |t| t["slug"] }

  # --- check 2: every managed repo has a tiers + componentowners entry ---
  (managed_repo_names - tier_repo_names).each do |name|
    errors << "#{name}: in managed-repos.yaml but missing from repo-tiers.yaml"
  end
  (managed_repo_names - componentowners_names).each do |name|
    errors << "#{name}: in managed-repos.yaml but missing from componentowners-policy.yaml"
  end

  # --- check 3: repo-tiers.yaml enum values ---
  valid_classes = %w[A B C n/a]
  valid_subprojects = %w[core supply-chain community-ecosystem extensibility org-control unclassified]
  data[:tiers].fetch("repositories", []).each do |entry|
    name = entry["name"]
    klass = entry["class"]
    subproject = entry["subproject"]
    errors << "repo-tiers.yaml: #{name}: class '#{klass}' is not one of #{valid_classes.join(', ')}" unless valid_classes.include?(klass)
    errors << "repo-tiers.yaml: #{name}: subproject '#{subproject}' is not one of #{valid_subprojects.join(', ')}" unless valid_subprojects.include?(subproject)
  end

  # --- check 4: every referenced team slug actually exists (per last snapshot) ---
  referenced_teams = []

  data[:componentowners].fetch("repositories", []).each do |entry|
    next if entry["exception"]

    entry.fetch("rules", []).each do |rule|
      Array(rule["teams"]).each { |t| referenced_teams << ["componentowners-policy.yaml (#{entry['name']}, #{rule['path']})", t] }
    end
  end

  Array(data[:org_policy]["global_admin_teams"]).each { |t| referenced_teams << ["org-policy.yaml (global_admin_teams)", t] }
  Array(data[:org_policy]["global_maintain_teams"]).each { |t| referenced_teams << ["org-policy.yaml (global_maintain_teams)", t] }
  Hash(data[:org_policy]["subproject_committees"]).each_key { |t| referenced_teams << ["org-policy.yaml (subproject_committees)", t] }

  Array(data[:repo_policy]["repositories"]).each do |entry|
    Array(entry["ruleset_bypass_teams"]).each { |t| referenced_teams << ["repo-policy.yaml (#{entry['name']}, ruleset_bypass_teams)", t] }
  end

  referenced_teams.each do |source, slug|
    next if known_team_slugs.include?(slug)

    errors << "#{source}: references team '#{slug}', which is not in generated/teams.yaml's last snapshot (typo, or teams.yaml needs a refresh via scripts/update-teams.sh)"
  end

  # --- check 5: the "*" rule exists and comes first ---
  #
  # render-codeowners.rb locates the "*" rule by searching the list, not by
  # position, so a "*" placed after a path-scoped rule still supplies the
  # base owners it prepends to every other rule -- while also being written
  # out after those rules. CODEOWNERS honors only the last matching pattern
  # for a path, so that trailing "*" line then overrides every path rule
  # above it, collapsing the whole file back to the general owners. Both the
  # policy entry and the rendered file still look plausible, which is what
  # makes the ordering worth asserting here rather than leaving it to review.
  data[:componentowners].fetch("repositories", []).each do |entry|
    next if entry["exception"]

    paths = entry.fetch("rules", []).map { |r| r["path"] }

    if paths.empty?
      errors << "componentowners-policy.yaml: #{entry['name']}: has no rules at all"
    elsif !paths.include?("*")
      errors << "componentowners-policy.yaml: #{entry['name']}: has no '*' rule, so the repo would be left with no general owners"
    elsif paths.first != "*"
      errors << "componentowners-policy.yaml: #{entry['name']}: the '*' rule must come first, but #{paths.first.inspect} does -- a '*' rendered after path-scoped rules overrides all of them"
    end
  end

  # --- check 6: every repo referenced in milestones-policy.yaml is managed ---
  data[:milestones_policy].fetch("milestones", []).each do |m|
    title = m["title"]
    Array(m["repos"]).each do |repo|
      next if managed_repo_names.include?(repo)

      errors << "milestones-policy.yaml (#{title}): references repo '#{repo}', which is not in generated/managed-repos.yaml (typo, or the repo isn't cloned/managed here)"
    end
  end
end

if errors.empty?
  puts "Policy validation passed: #{files.size} files parsed, #{data[:managed_repos]&.fetch('repositories', [])&.size || 0} managed repos cross-checked."
  exit 0
else
  warn "Policy validation FAILED:"
  errors.each { |e| warn "  - #{e}" }
  exit 1
end
