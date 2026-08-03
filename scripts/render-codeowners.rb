#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Renders the desired CODEOWNERS content for one repo from
# componentowners-policy.yaml.
#
# Every path-scoped rule gets that repo's "*" rule teams/users prepended,
# not just its own — CODEOWNERS takes only the LAST matching pattern for
# a given path, it never merges rules, so a path rule that lists only its
# own narrow teams/users would otherwise silently drop the repo's general
# owners team as an owner for that subtree. Prepending makes a path rule
# additive (extra reviewers on top of the general owners) instead of a
# silent replacement.
#
# Usage:
#   ruby render-codeowners.rb <repo>
#
# Prints the desired CODEOWNERS file content to stdout. Does not touch
# any repo, clone, or GitHub state — purely a renderer.

require "yaml"

INFRA_ROOT = File.expand_path("..", __dir__)
POLICY_FILE = File.join(INFRA_ROOT, "componentowners-policy.yaml")

repo = ARGV[0]
if repo.nil? || repo.empty?
  warn "usage: #{$PROGRAM_NAME} <repo>"
  exit 1
end

policy = YAML.load_file(POLICY_FILE)
entry = policy.fetch("repositories", []).find { |r| r["name"] == repo }

if entry.nil?
  warn "error: '#{repo}' has no entry in componentowners-policy.yaml"
  exit 1
end

if entry["exception"]
  warn "'#{repo}' is a documented exception (#{entry['reason']}) — no CODEOWNERS rules to render."
  exit 1
end

rules = entry["rules"] || []
star_rule = rules.find { |r| r["path"] == "*" }
base_teams = star_rule ? Array(star_rule["teams"]) : []
base_users = star_rule ? Array(star_rule["users"]) : []

def render_owners(teams, users)
  (teams.map { |t| "@cloudnative-pg/#{t}" } + users.map { |u| "@#{u}" }).join(" ")
end

lines = []
lines << "# This file is generated from componentowners-policy.yaml in"
lines << "# cloudnative-pg/cnpg-infra — do not hand-edit, propose changes there instead."
lines << "#"
lines << "# Path-scoped rules below always include the repo's own general owners"
lines << "# (the \"*\" line) in addition to their own specific teams/users, since"
lines << "# CODEOWNERS only honors the LAST matching pattern for a given path —"
lines << "# it does not merge an earlier, less-specific rule into a later one."
lines << ""

rules.each do |rule|
  path = rule["path"]
  teams = Array(rule["teams"])
  users = Array(rule["users"])

  if path == "*"
    lines << "* #{render_owners(teams, users)}"
  else
    merged_teams = (base_teams + teams).uniq
    merged_users = (base_users + users).uniq
    owners = render_owners(merged_teams, merged_users)
    # A "path" value can hold multiple space-separated patterns sharing the
    # same owners (see componentowners-policy.yaml's note on cloudnative-pg's
    # combined "Testing" scope) — CODEOWNERS has no such grouping syntax, a
    # real line is exactly one pattern followed by its owners, so each
    # pattern needs its own line or everything past the first would be
    # misread as more owners instead of more paths.
    path.split(" ").each { |single_path| lines << "#{single_path} #{owners}" }
  end
end

puts lines.join("\n")
