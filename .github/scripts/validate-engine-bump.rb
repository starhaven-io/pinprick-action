#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "engine-version"

abort "usage: validate-engine-bump.rb OLD_ACTION OLD_README NEW_ACTION NEW_README" unless ARGV.length == 4
old_action, old_readme, new_action, new_readme = ARGV.map { |path| EngineVersion.read(path) }
old_version = EngineVersion.parse(old_action, "the previous action.yml")
new_version = EngineVersion.parse(new_action, "action.yml")
abort "the pinprick default version did not change" if old_version == new_version
unless (new_version.split(".").map(&:to_i) <=> old_version.split(".").map(&:to_i)).positive?
  abort "the pinprick default version must increase"
end
unless old_action.scan(old_version).length == 3 && old_readme.scan(old_version).length == 2
  abort "the previous version-reference contract has drifted"
end
unless new_action == old_action.gsub(old_version, new_version)
  abort "action.yml contains changes beyond the version replacement"
end
unless new_readme == old_readme.gsub(old_version, new_version)
  abort "README.md contains changes beyond the version replacement"
end
puts new_version
