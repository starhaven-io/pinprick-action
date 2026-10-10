# frozen_string_literal: true

module EngineVersion
  PATTERN = /^inputs:\n(?:(?!^\S).)*?^  version:\n(?:    [^\n]*\n)*?^    default: "((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"$/m

  def self.read(path)
    File.read(path, encoding: "UTF-8").gsub(/\r\n?/, "\n")
  end

  def self.parse(content, label)
    match = PATTERN.match(content)
    abort "could not find a canonical stable version default in #{label}" unless match

    match[1]
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: engine-version.rb [ACTION_YML]" if ARGV.length > 1
  path = ARGV.fetch(0, "action.yml")
  puts EngineVersion.parse(EngineVersion.read(path), path)
end
