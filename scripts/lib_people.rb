# frozen_string_literal: true
#
# Shared helper for the two roster renderers (render-component-owners.rb,
# render-contributors.rb): turns a GitHub handle from repo-tiers.yaml into
# the Name / GitHub Handle / Country row both files use.
#
# Not a script -- require_relative this, don't run it.

require "yaml"

module People
  PEOPLE_FILE = File.expand_path("../people.yaml", __dir__)

  module_function

  def all
    @all ||= (YAML.load_file(PEOPLE_FILE)["people"] || {})
  end

  # A handle with no entry, or an entry missing a field, is normal: the row
  # falls back to the handle and leaves the cell empty, rather than the
  # renderer failing or inventing a value.
  def row(handle)
    entry = all[handle] || {}
    name = entry["name"] || "@#{handle}"
    country = entry["country"] || ""
    "| #{name} | [@#{handle}](https://github.com/#{handle}) | #{country} |"
  end

  # Sorted the way governance/CONTRIBUTORS.md sorted: by last name where a
  # name is on file, otherwise by handle, so the ordering stays stable and
  # doesn't reshuffle when someone's name is filled in mid-list.
  def sort_key(handle)
    name = all.dig(handle, "name")
    return handle.downcase if name.nil?

    parts = name.split(" ")
    [parts.last, parts.first].join(" ").downcase
  end

  def sorted(handles)
    handles.sort_by { |h| sort_key(h) }
  end
end
