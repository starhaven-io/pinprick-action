# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class ReleaseGatingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHA = "a" * 40

  def setup
    @directory = Dir.mktmpdir("pinprick-action-release-")
    @bin = File.join(@directory, "bin")
    FileUtils.mkdir_p(@bin)
    FileUtils.cp(File.join(__dir__, "fixtures/gh-self-test.rb"), File.join(@bin, "gh"))
    FileUtils.chmod(0755, File.join(@bin, "gh"))
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def wait_for(mode, attempts = 3)
    File.write(File.join(@directory, "state"), "")
    Open3.capture3(
      { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "REPOSITORY" => "example/project", "COMMIT_SHA" => SHA,
        "SELF_TEST_MAX_ATTEMPTS" => attempts.to_s, "SELF_TEST_POLL_SECONDS" => "0",
        "SHIM_MODE" => mode, "SHIM_SHA" => SHA, "SHIM_STATE" => File.join(@directory, "state") },
      RbConfig.ruby, File.join(ROOT, ".github/scripts/wait-for-self-test.rb"), unsetenv_others: true
    )
  end

  def test_success_and_transient_failures
    { "success" => 1, "queued-then-success" => 2, "api-then-success" => 2,
      "jobs-api-then-success" => 2, "preview-failure" => 1 }.each do |mode, calls|
      output, error, status = wait_for(mode)
      assert status.success?, "#{mode}: #{output}\n#{error}"
      assert_equal calls, File.read(File.join(@directory, "state")).to_i
    end
  end

  def test_failed_or_missing_conclusion_cannot_release
    { "failure" => "Self-test conclusion completed with 'failure'",
      "missing-conclusion" => "Self-test completed with 'failure' but no conclusion job",
      "duplicate-conclusion" => "Self-test returned multiple conclusion jobs",
      "invalid-run-id" => "Self-test returned an invalid workflow run id",
      "newer-run-failure" => "Self-test conclusion completed with 'failure'",
      "malformed-runs" => "Could not parse the Self-test workflow runs response",
      "malformed-jobs" => "Could not parse the Self-test jobs response" }.each do |mode, diagnostic|
      _output, error, status = wait_for(mode)
      refute status.success?, mode
      assert_includes error, "::error::#{diagnostic}", mode
    end
  end

  def test_only_the_exact_push_on_main_can_satisfy_the_gate
    %w[missing wrong-sha wrong-branch wrong-event].each do |mode|
      _output, error, status = wait_for(mode, 2)
      refute status.success?, mode
      assert_includes error, "::error::Self-test did not succeed for #{SHA} after 2 attempts"
    end
  end

  def test_waiting_progress_is_visible_before_the_next_poll
    environment = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "REPOSITORY" => "example/project", "COMMIT_SHA" => SHA,
                    "SELF_TEST_MAX_ATTEMPTS" => "2", "SELF_TEST_POLL_SECONDS" => "30", "SHIM_MODE" => "missing",
                    "SHIM_SHA" => SHA, "SHIM_STATE" => File.join(@directory, "state") }
    Open3.popen3(environment, RbConfig.ruby, File.join(ROOT, ".github/scripts/wait-for-self-test.rb"),
                unsetenv_others: true) do |stdin, stdout, _stderr, child|
      stdin.close
      begin
        refute_nil IO.select([stdout], nil, nil, 2), "the first poll should be visible while the gate is still running"
        assert_includes stdout.gets, "Waiting for the Self-test push run"
        refute child.join(0), "the gate should still be waiting for the second poll"
      ensure
        Process.kill("TERM", child.pid) unless child.join(0)
        child.value
      end
    end
  end

  def fixture(name, version)
    directory = File.join(@directory, name)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "action.yml"), <<~YAML)
      inputs:
        version:
          description: Install #{version}; the pinned release is #{version}.
          default: "#{version}"
    YAML
    File.write(File.join(directory, "README.md"), "Default #{version}; example #{version}.\n")
    [File.join(directory, "action.yml"), File.join(directory, "README.md")]
  end

  def validate_bump(old_files, new_files)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, ".github/scripts/validate-engine-bump.rb"), *old_files, *new_files)
  end

  def test_canonical_stable_bump
    old_files = fixture("old", "1.2.9")
    output, error, status = validate_bump(old_files, fixture("new", "1.2.10"))
    assert status.success?, error
    assert_equal "1.2.10\n", output
  end

  def test_invalid_versions
    old_files = fixture("old", "1.2.3")
    { "1.2.4-rc.1" => "could not find a canonical stable version default",
      "1.2.4+build.1" => "could not find a canonical stable version default",
      "01.2.4" => "could not find a canonical stable version default",
      "1.2.2" => "the pinprick default version must increase",
      "1.2.3" => "the pinprick default version did not change" }.each do |version, diagnostic|
      _output, error, status = validate_bump(old_files, fixture("new", version))
      refute status.success?, version
      assert_includes error, diagnostic
    end
  end

  def test_unrelated_changes_and_drift_are_rejected
    %w[action.yml README.md].each do |file|
      old_files = fixture("old", "1.2.3")
      new_files = fixture("new", "1.2.4")
      File.write(File.join(@directory, "new", file), "unrelated change\n", mode: "a")
      _output, error, status = validate_bump(old_files, new_files)
      refute status.success?
      assert_includes error, "#{file} contains changes beyond the version replacement"
    end
    old_files = fixture("old", "1.2.3")
    File.write(old_files.last, "extra 1.2.3\n", mode: "a")
    _output, error, status = validate_bump(old_files, fixture("new", "1.2.4"))
    refute status.success?
    assert_includes error, "the previous version-reference contract has drifted"
  end

  def workflow(name)
    YAML.load_file(File.join(ROOT, ".github/workflows", name))
  end

  def test_both_release_paths_wait_before_publication
    { "release.yml" => "Create action release tag", "release-manual.yml" => "Create action tag and release" }.each do |name, publication|
      document = workflow(name)
      assert_equal({ "group" => "release", "cancel-in-progress" => false, "queue" => "max" }, document.fetch("concurrency"))
      steps = document.fetch("jobs").fetch("release").fetch("steps")
      wait = steps.index { |step| step["run"] == "ruby .github/scripts/wait-for-self-test.rb" }
      assert wait, name
      assert_operator wait, :<, steps.index { |step| step["name"] == publication }
      assert_includes steps.filter_map { |step| step["run"] }.join, 'repos/${REPOSITORY}/releases?per_page=100'
      setup = steps.index { |step| step["uses"]&.start_with?("ruby/setup-ruby@") }
      assert setup, name
      assert_operator setup, :<, wait
    end
  end

  def test_release_ruby_setup_skips_bundler_and_follows_eligibility
    automatic = workflow("release.yml").fetch("jobs").fetch("release").fetch("steps")
    manual = workflow("release-manual.yml").fetch("jobs").fetch("release").fetch("steps")
    [[automatic, "Identify merged bump PR"], [manual, "Validate release request"]].each do |steps, validation|
      setup_index = steps.index { |step| step["name"] == "Set up Ruby" }
      assert_operator steps.index { |step| step["name"] == validation }, :<, setup_index
      setup = steps.fetch(setup_index)
      assert_equal "none", setup.fetch("with").fetch("bundler")
      refute setup.fetch("env", {}).key?("GH_TOKEN")
    end
    assert_equal "steps.pr.outputs.eligible == 'true'", automatic.find { |step| step["name"] == "Set up Ruby" }.fetch("if")
    [automatic.find { |step| step["name"] == "Validate engine bump" },
     manual.find { |step| step["name"] == "Read engine version" }].each do |step|
      refute step.fetch("env", {}).key?("GH_TOKEN")
    end
  end

  def test_manual_engine_version_step_emits_only_a_canonical_stable_version
    step = workflow("release-manual.yml").fetch("jobs").fetch("release").fetch("steps")
           .find { |item| item["name"] == "Read engine version" }
    { "1.2.3" => true, "0.0.0" => true, "01.2.3" => false,
      "1.2.3-rc.1" => false, "1.2.3+build" => false }.each do |version, valid|
      action, = fixture("engine", version)
      root = File.dirname(action)
      scripts = File.join(root, ".github/scripts")
      FileUtils.mkdir_p(scripts)
      FileUtils.cp(File.join(ROOT, ".github/scripts/engine-version.rb"), scripts)
      output = File.join(root, "step-output")
      FileUtils.rm_f(output)
      _stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "GITHUB_OUTPUT" => output }, "bash", "-euo", "pipefail", "-c", step.fetch("run"),
        chdir: root, unsetenv_others: true
      )
      assert_equal valid, status.success?, "#{version}: #{stderr}"
      if valid
        assert_equal "engine_version=#{version}\n", File.read(output)
      else
        refute File.exist?(output)
        assert_includes stderr, "could not find a canonical stable version default"
      end
    end
  end

  def test_self_test_push_runs_are_sha_scoped_and_cannot_be_cancelled
    assert_equal({ "group" => "self-test-${{ github.event_name }}-${{ github.event_name == 'pull_request' && github.event.pull_request.number || github.sha }}",
                   "cancel-in-progress" => "${{ github.event_name == 'pull_request' }}" }, workflow("self-test.yml").fetch("concurrency"))
  end

  def test_manual_release_stops_on_release_history_api_failure
    script = workflow("release-manual.yml").fetch("jobs").fetch("release").fetch("steps")
              .find { |step| step["name"] == "Validate release request" }.fetch("run")
    { "gh" => 23, "git" => 1 }.each do |command, code|
      File.write(File.join(@bin, command), "#!/bin/sh\nexit #{code}\n")
      FileUtils.chmod(0755, File.join(@bin, command))
    end
    output = File.join(@directory, "request-output")
    _stdout, _stderr, status = Open3.capture3(
      { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "REF" => "refs/heads/main", "TAG" => "v999.0.0", "NOTES" => "Wrapper fix",
        "REPOSITORY" => "example/project", "GITHUB_OUTPUT" => output }, "bash", "-euo", "pipefail", "-c", script, unsetenv_others: true
    )
    assert_equal 23, status.exitstatus
    refute File.size?(output)
  end
end
