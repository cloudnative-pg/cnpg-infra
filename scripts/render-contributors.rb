#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Renders the desired CONTRIBUTORS.md content for one repo from
# repo-tiers.yaml's `contributors:` field, with names and countries filled
# in from people.yaml.
#
# The Contributor tier is recognition, not access: nothing in GitHub state
# reflects it, which is exactly why it needs a written record. It lives
# per-repo, next to the Component Owners who vote on it, rather than in one
# org-wide list -- governance/CONTRIBUTORS.md used to hold that list, and
# every name in it turned out to be a Component Owner of some repository,
# so the file was an owners list under the wrong name.
#
# Unlike render-component-owners.rb, this one is expected to have nothing
# to render for most repos: a repo with no `contributors:` entry exits 1
# with a message, so sync-ownership-files.sh skips it rather than
# scattering empty files across the org.
#
# Usage:
#   ruby render-contributors.rb <repo>
#
# Prints the desired file content to stdout. Touches nothing.

require "yaml"
require_relative "lib_people"

INFRA_ROOT = File.expand_path("..", __dir__)
TIERS_FILE = File.join(INFRA_ROOT, "repo-tiers.yaml")

LADDER_URL = "https://github.com/cloudnative-pg/governance/blob/main/CONTRIBUTOR_LADDER.md"

repo = ARGV[0]
if repo.nil? || repo.empty?
  warn "usage: #{$PROGRAM_NAME} <repo>"
  exit 1
end

tiers = YAML.load_file(TIERS_FILE)
entry = tiers.fetch("repositories", []).find { |r| r["name"] == repo }

if entry.nil?
  warn "error: '#{repo}' has no entry in repo-tiers.yaml"
  exit 1
end

contributors = Array(entry["contributors"])
if contributors.empty?
  warn "'#{repo}' has no contributors in repo-tiers.yaml -- no file to render."
  exit 1
end

lines = []
lines << "# Contributors"
lines << ""
lines << "<!--"
lines << "Generated from repo-tiers.yaml and people.yaml in"
lines << "cloudnative-pg/cnpg-infra -- do not hand-edit. Propose a change there"
lines << "instead; a contributor is added or removed there only to record a vote"
lines << "that has already passed, never to make the decision itself."
lines << "-->"
lines << ""
lines << "The people below hold the **Contributor** tier for `#{repo}`: the entry"
lines << "rung of the CloudNativePG [contributor ladder](#{LADDER_URL}#contributor),"
lines << "recognition for contributions to this repository rather than a grant of"
lines << "access to it. This project is grateful for their work."
lines << ""
lines << "| Name | GitHub Handle | Country |"
lines << "| :--- | :--- | :--- |"
People.sorted(contributors).each { |c| lines << People.row(c) }
lines << ""
lines << "Contributor status is awarded by nomination and a simple-majority vote of"
lines << "this repository's [Component Owners](COMPONENT_OWNERS.md), held on an issue"
lines << "in this repository. A Contributor later promoted to Component Owner moves"
lines << "to that file and is removed from this one. Contributions are not limited to"
lines << "code: documentation, review, triage, and community work all count. See the"
lines << "[contributor ladder](#{LADDER_URL}) for the full requirements and process."

puts lines.join("\n")
