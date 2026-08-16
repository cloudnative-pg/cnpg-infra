#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Reconciles GitHub milestones against milestones-policy.yaml's desired
# state: for every (milestone, repo) pair listed there, creates the
# milestone if it doesn't exist yet (matched by exact title), and updates
# its description and/or due date if either has drifted from policy.
# Never touches state (open/closed) or issue assignments -- those are
# per-repo operational data, not something this file dictates.
#
# Due dates are a ROLLING window, not a fixed date read from the policy
# file: each milestone's `due_offset_months` (policy) is added to whatever
# date the script actually runs on, then rolled forward to the 1st of the
# following month -- e.g. run on 2026-08-13 with offset 3 -> 2026-11-13 ->
# 2026-12-01. That "roll to the 1st of the next month" step (rather than
# "last day of the target month") is deliberate: it needs no per-month
# day-count/leap-year logic at all, and lands on the same date either way
# except for the one day the two conventions disagree on. Concretely: this
# means due dates advance automatically every time this script runs in a
# new calendar month -- there is nothing to edit in the policy file to
# "renew" them.
#
# Requires: gh (authenticated, write access on each target repo)
#
# Usage:
#   ruby scripts/sync-milestones.rb              # dry run: every planned change
#   ruby scripts/sync-milestones.rb <repo>        # dry run: just one repo
#   ruby scripts/sync-milestones.rb [<repo>] --apply   # actually apply it

require "yaml"
require "json"
require "date"
require "open3"

ORG = "cloudnative-pg"
INFRA_ROOT = File.expand_path("..", __dir__)
POLICY_FILE = File.join(INFRA_ROOT, "milestones-policy.yaml")

apply = !ARGV.delete("--apply").nil?
target_repo = ARGV.first

policy = YAML.load_file(POLICY_FILE)
milestones = policy.fetch("milestones", [])

def rolling_due_on(offset_months, today: Date.today) # -> "YYYY-MM-DDT00:00:00Z"
  shifted = today >> offset_months # same day-of-month, offset_months from now (day clamped if needed)
  first_of_next_month = Date.new(shifted.year, shifted.month, 1) >> 1
  first_of_next_month.strftime("%Y-%m-%dT00:00:00Z")
end

def gh_milestones(org, repo) # -> array of existing milestones (any state), or nil on failure
  # -X GET must be explicit: gh api defaults to POST whenever any -f/-F flag
  # is present, unless the method is spelled out, which would otherwise send
  # state=all as a POST body against a create endpoint instead of a query
  # param against a list endpoint.
  out, status = Open3.capture2("gh", "api", "-X", "GET", "repos/#{org}/#{repo}/milestones", "-f", "state=all", "--paginate")
  return nil unless status.success?

  JSON.parse(out)
rescue JSON::ParserError
  nil
end

changes = []

milestones.each do |m|
  title = m.fetch("title")
  description = m.fetch("description").strip
  due_on = rolling_due_on(m.fetch("due_offset_months"))

  Array(m["repos"]).each do |repo|
    next if target_repo && repo != target_repo

    existing = gh_milestones(ORG, repo)
    if existing.nil?
      changes << { repo: repo, title: title, action: :error, detail: "could not list milestones (repo missing, no access, or bad response)" }
      next
    end

    match = existing.find { |e| e["title"] == title }
    if match.nil?
      changes << { repo: repo, title: title, action: :create, description: description, due_on: due_on }
      next
    end

    diffs = {}
    diffs["description"] = description if match["description"].to_s.strip != description
    diffs["due_on"] = due_on if match["due_on"].to_s != due_on

    if diffs.empty?
      changes << { repo: repo, title: title, action: :ok }
    else
      changes << { repo: repo, title: title, action: :update, number: match["number"], old_due: match["due_on"], diffs: diffs }
    end
  end
end

if changes.empty?
  warn "no matching (milestone, repo) pairs -- check the repo name" if target_repo
  exit(target_repo ? 1 : 0)
end

puts "Milestone sync plan (#{milestones.map { |m| m['title'] }.join('/')}) " \
     "across #{changes.map { |c| c[:repo] }.uniq.size} repo(s):"
puts

changes.group_by { |c| c[:repo] }.each do |repo, entries|
  puts "#{repo}:"
  entries.each do |c|
    case c[:action]
    when :ok
      puts "  ✓ #{c[:title]} already matches policy"
    when :create
      puts "  + #{c[:title]}: missing, would create (due #{c[:due_on][0, 10]})"
    when :update
      fields = c[:diffs].keys.join(", ")
      line = "  ~ #{c[:title]} (##{c[:number]}): #{fields} differ, would update"
      if c[:diffs]["due_on"]
        old_due = c[:old_due] ? c[:old_due][0, 10] : "unset"
        line += " (due #{old_due} -> #{c[:diffs]['due_on'][0, 10]})"
      end
      puts line
    when :error
      puts "  ⚠️  #{c[:title]}: #{c[:detail]}"
    end
  end
  puts
end

to_apply = changes.select { |c| %i[create update].include?(c[:action]) }

if !apply
  puts(to_apply.empty? ? "Nothing to do." : "Dry run only -- re-run with --apply to make these changes.")
  exit 0
end

to_apply.each do |c|
  case c[:action]
  when :create
    _out, status = Open3.capture2(
      "gh", "api", "repos/#{ORG}/#{c[:repo]}/milestones",
      "-X", "POST",
      "-f", "title=#{c[:title]}",
      "-f", "description=#{c[:description]}",
      "-f", "due_on=#{c[:due_on]}",
      "-f", "state=open"
    )
    puts status.success? ? "  ✓ created #{c[:title]} in #{c[:repo]}" : "  ✗ failed to create #{c[:title]} in #{c[:repo]}"
  when :update
    args = ["gh", "api", "repos/#{ORG}/#{c[:repo]}/milestones/#{c[:number]}", "-X", "PATCH"]
    c[:diffs].each { |field, value| args += ["-f", "#{field}=#{value}"] }
    _out, status = Open3.capture2(*args)
    puts status.success? ? "  ✓ updated #{c[:title]} (##{c[:number]}) in #{c[:repo]}" : "  ✗ failed to update #{c[:title]} in #{c[:repo]}"
  end
end
