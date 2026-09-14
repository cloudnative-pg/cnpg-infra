#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Reconciles GitHub issue labels against labels-policy.yaml: creates a
# label where it is missing, and updates its colour or description where
# either has drifted. Never deletes a label, and never touches one the
# policy doesn't mention -- repositories carry plenty of their own.
#
# The reason this is worth automating rather than doing by hand: GitHub
# silently drops a label an issue form asks for when the repository
# doesn't have it. The issue is created, untagged, with no error anywhere,
# so the failure is invisible until someone goes looking for issues by
# label and finds none.
#
# Requires: gh (authenticated, write access on each target repo)
#
# Usage:
#   ruby scripts/sync-labels.rb                    # dry run, every repo
#   ruby scripts/sync-labels.rb <repo>             # dry run, one repo
#   ruby scripts/sync-labels.rb [<repo>] --apply   # actually apply it

require "yaml"
require "json"
require "open3"

ORG = "cloudnative-pg"
INFRA_ROOT = File.expand_path("..", __dir__)
POLICY_FILE = File.join(INFRA_ROOT, "labels-policy.yaml")
MANIFEST = File.join(INFRA_ROOT, "generated", "managed-repos.yaml")

apply = !ARGV.delete("--apply").nil?
target_repo = ARGV.first

policy = YAML.load_file(POLICY_FILE).fetch("labels", [])
managed = YAML.load_file(MANIFEST).fetch("repositories", []).map { |r| r["name"] }

if target_repo && !managed.include?(target_repo)
  warn "error: '#{target_repo}' is not in managed-repos.yaml -- refusing to touch a repo outside the managed scope."
  exit 1
end

def gh(*args)
  out, err, status = Open3.capture3("gh", *args)
  [status.success? ? out : nil, err]
end

# repo => [labels it should have]
wanted = Hash.new { |h, k| h[k] = [] }
policy.each do |label|
  scope = label["scope"].to_s
  repos = scope == "all" ? managed : [scope]
  repos.each { |r| wanted[r] << label if managed.include?(r) }
end

repos = target_repo ? [target_repo] : wanted.keys.sort
planned = 0
failures = 0

repos.each do |repo|
  labels = wanted[repo]
  next if labels.empty?

  existing_raw, = gh("api", "--paginate", "repos/#{ORG}/#{repo}/labels", "--jq",
                     ".[] | {name, color, description} | tostring")
  if existing_raw.nil?
    warn "  #{repo}: could not read labels"
    failures += 1
    next
  end
  existing = existing_raw.lines.map { |l| JSON.parse(l) }
                         .to_h { |h| [h["name"].downcase, h] }

  labels.each do |label|
    name = label["name"]
    have = existing[name.downcase]
    desired_colour = label["color"].to_s.downcase
    desired_desc = label["description"].to_s

    if have.nil?
      planned += 1
      puts "  #{repo}: create #{name} (##{desired_colour})"
      next unless apply

      _, err = gh("api", "-X", "POST", "repos/#{ORG}/#{repo}/labels",
                  "-f", "name=#{name}", "-f", "color=#{desired_colour}",
                  "-f", "description=#{desired_desc}")
      if err && !err.empty? && !err.include?("already_exists")
        warn "    failed: #{err.lines.first&.strip}"
        failures += 1
      end
    elsif have["color"].to_s.downcase != desired_colour || have["description"].to_s != desired_desc
      planned += 1
      puts "  #{repo}: update #{name} (colour #{have['color']} -> #{desired_colour})"
      next unless apply

      _, err = gh("api", "-X", "PATCH", "repos/#{ORG}/#{repo}/labels/#{name}",
                  "-f", "new_name=#{name}", "-f", "color=#{desired_colour}",
                  "-f", "description=#{desired_desc}")
      if err && !err.empty?
        warn "    failed: #{err.lines.first&.strip}"
        failures += 1
      end
    end
  end
end

puts
if planned.zero?
  puts "Nothing to do -- every label in labels-policy.yaml already matches."
elsif apply
  puts "Applied #{planned} change(s)#{failures.positive? ? ", #{failures} failed" : ''}."
else
  puts "#{planned} change(s) planned. Dry run only -- re-run with --apply."
end
exit(failures.positive? ? 1 : 0)
