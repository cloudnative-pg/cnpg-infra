#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Renders the desired COMPONENT_OWNERS.md content for one repo from
# repo-tiers.yaml's `owners:` field, with names and countries filled in
# from people.yaml.
#
# That field is the single source of truth for who holds Write on a repo
# (sync-project-owner-teams.sh reconciles the <repo>-owners GitHub team
# against it). Rendering a file from it gives each component a public,
# per-repo answer to "who owns this and who votes on my promotion" --
# GitHub team membership is only visible to other org members, so the
# team itself can't serve that purpose, and governance/MAINTAINERS.md
# deliberately lists committee members only, not Component Owners.
#
# Usage:
#   ruby render-component-owners.rb <repo>
#
# Prints the desired file content to stdout. Does not touch any repo,
# clone, or GitHub state -- purely a renderer, same as
# render-codeowners.rb.

require "yaml"
require_relative "lib_people"

INFRA_ROOT = File.expand_path("..", __dir__)
TIERS_FILE = File.join(INFRA_ROOT, "repo-tiers.yaml")

LADDER_URL = "https://github.com/cloudnative-pg/governance/blob/main/CONTRIBUTOR_LADDER.md"
SUBPROJECTS_URL = "https://github.com/cloudnative-pg/governance/blob/main/subprojects"

# repo-tiers.yaml's `subproject` values, as they should read to someone
# who has never seen that file. org-control and unclassified are not
# subprojects at all, so they get a sentence instead of a name.
SUBPROJECT_NAMES = {
  "core" => ["Core", "core.md"],
  "supply-chain" => ["Supply Chain", "supply-chain.md"],
  "community-ecosystem" => ["Community, Docs & Ecosystem", "community-ecosystem.md"],
  "extensibility" => ["Extensibility", "extensibility.md"],
}.freeze

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

owners = Array(entry["owners"])
if owners.empty?
  warn "'#{repo}' has no owners in repo-tiers.yaml -- nothing to render."
  exit 1
end

subproject = entry["subproject"].to_s
name, file = SUBPROJECT_NAMES[subproject]

lines = []
lines << "# Component Owners"
lines << ""
lines << "<!--"
lines << "Generated from repo-tiers.yaml and people.yaml in"
lines << "cloudnative-pg/cnpg-infra -- do not hand-edit. Propose a change there"
lines << "instead; an owner is added or removed there only to record a vote that"
lines << "has already passed, never to make the decision itself."
lines << "-->"
lines << ""

case subproject
when "org-control"
  lines << "`#{repo}` is one of the CloudNativePG organization-control repositories,"
  lines << "administered directly by the Steering Committee rather than by a"
  lines << "subproject maintainer committee."
when *SUBPROJECT_NAMES.keys
  lines << "`#{repo}` is a component of the [#{name}](#{SUBPROJECTS_URL}/#{file})"
  lines << "subproject of CloudNativePG."
else
  lines << "`#{repo}` is not yet classified under any CloudNativePG subproject."
end

lines << ""
lines << "The people below are its **Component Owners**: they hold `Write` on this"
lines << "repository through the `#{repo.sub(/\A\./, '')}-owners` GitHub team, and are its default"
lines << "[`CODEOWNERS`](CODEOWNERS) entry, so every pull request here is routed to"
lines << "them for review."
lines << ""
lines << "| Name | GitHub Handle | Country |"
lines << "| :--- | :--- | :--- |"
People.sorted(owners).each { |o| lines << People.row(o) }
lines << ""
lines << "Component Owner is a rung of the CloudNativePG"
lines << "[contributor ladder](#{LADDER_URL}#component-owner). A new owner is added"
lines << "by a ⅔ vote of this repository's existing Component Owners, held on an"
lines << "issue in this repository; the change is then recorded in `cnpg-infra`,"
lines << "which grants the access and regenerates this file. See the"
lines << "[contributor ladder](#{LADDER_URL}) for the full process, including what"
lines << "happens when a repository has too few owners to reach that threshold."

puts lines.join("\n")
