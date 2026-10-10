# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class CheckTest < Minitest::Test
  def with_check_fixture
    Dir.mktmpdir("action-check-") do |root|
      bin = File.join(root, "bin")
      scripts = File.join(root, ".github/scripts")
      FileUtils.mkdir_p([bin, scripts, File.join(root, "test")])
      FileUtils.cp(File.expand_path("../.github/scripts/check.rb", __dir__), scripts)
      %w[git shellcheck bundle zizmor pinprick lychee].each do |tool|
        path = File.join(bin, tool)
        File.write(path, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0755, path)
      end
      File.write(File.join(root, "action.sh"), "#!/bin/sh\nexit 0\n")
      environment = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "SHIM_MARKER" => File.join(root, "marker") }
      command = [RbConfig.ruby, File.join(scripts, "check.rb")]
      yield root, environment, command
    end
  end

  def test_shell_harnesses_must_be_executable_as_they_are_in_ci
    with_check_fixture do |root, environment, command|
      harness = File.join(root, "test/contract.sh")
      File.write(harness, "#!/bin/sh\nprintf ran > \"$SHIM_MARKER\"\n")
      marker = environment.fetch("SHIM_MARKER")

      _stdout, stderr, status = Open3.capture3(environment, *command, unsetenv_others: true)
      refute status.success?
      assert_includes stderr, "test/contract.sh could not be executed"
      refute File.exist?(marker)

      FileUtils.chmod(0755, harness)
      _stdout, stderr, status = Open3.capture3(environment, *command, unsetenv_others: true)
      assert status.success?, stderr
      assert_equal "ran", File.read(marker)
    end
  end

  def test_shell_harness_paths_are_executed_literally
    with_check_fixture do |root, environment, command|
      names = ["space name.sh", "literal; touch injected.sh", "$(touch substituted).sh"]
      names.each do |name|
        harness = File.join(root, "test", name)
        File.write(harness, "#!/bin/sh\nprintf '%s\\n' \"$0\" >> \"$SHIM_MARKER\"\n")
        FileUtils.chmod(0755, harness)
      end

      _stdout, stderr, status = Open3.capture3(environment, *command, unsetenv_others: true)
      refute File.exist?(File.join(root, "injected.sh")), "a filename must not run a shell command"
      refute File.exist?(File.join(root, "substituted")), "a filename must not perform command substitution"
      assert status.success?, stderr
      assert_equal names.map { |name| "test/#{name}" }.sort,
                   File.readlines(environment.fetch("SHIM_MARKER"), chomp: true).sort
    end
  end
end
