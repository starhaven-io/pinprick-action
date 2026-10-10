#!/usr/bin/env ruby
# frozen_string_literal: true

require "rbconfig"

Dir.chdir(File.expand_path("../..", __dir__))
$stdout.sync = true
failed = false
run = lambda do |label, *command|
  puts "--- #{label} ---"
  success = system([command.first, command.first], *command.drop(1))
  unless success
    warn "#{label}: #{command.first} could not be executed" if success.nil?
    failed = true
  end
end
run.call("diff", "git", "diff", "--check")
shell_files = ["action.sh", *Dir[".githooks/*", "test/*.sh"]]
shell_files.each { |path| run.call("shell-syntax #{path}", "bash", "-n", path) }
Dir[".github/scripts/*.rb", "test/**/*.rb"].sort.each { |path| run.call("ruby-syntax #{path}", RbConfig.ruby, "-c", path) }
run.call("shellcheck", "shellcheck", *shell_files)
Dir["test/*.sh"].sort.each { |path| run.call(File.basename(path), path) }
run.call("ruby-tests", "bundle", "exec", "ruby", "-e", 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }')
run.call("audit", "zizmor", "--strict-collection", "--persona", "auditor", ".")
run.call("pinprick-audit", "pinprick", "audit", ".")
run.call("lychee", "lychee", "--config", "lychee.toml", "README.md", "RELEASING.md", "SECURITY.md")
exit(failed ? 1 : 0)
