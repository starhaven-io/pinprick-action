# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "yaml"

class ConclusionGatingTest < Minitest::Test
  def setup
    workflow = YAML.load_file(File.expand_path("../.github/workflows/self-test.yml", __dir__))
    @conclusion = workflow.fetch("jobs").fetch("conclusion")
    @step = @conclusion.fetch("steps").find { |step| step["name"] == "Result" }
  end

  def concludes(results, event, sarif)
    job_results = %w[validate console contract zizmor].zip(results).to_h.merge("sarif" => sarif)
    needs = job_results.slice(*@conclusion.fetch("needs"))
    env = @step.fetch("env").transform_values do |expression|
      if expression == "${{ github.event_name }}"
        event
      elsif (match = expression.match(/\A\$\{\{ needs\.([a-z_]+)\.result \}\}\z/))
        needs.fetch(match[1], "")
      else
        raise "Unsupported workflow expression: #{expression}"
      end
    end
    env["PATH"] = ENV.fetch("PATH")
    Open3.capture3(env, "bash", "-euo", "pipefail", "-c", @step.fetch("run"), unsetenv_others: true).last.success?
  end

  def test_event_specific_sarif_and_every_required_job
    { "pull_request" => "skipped", "push" => "success", "workflow_dispatch" => "success" }.each do |event, sarif|
      assert concludes(["success"] * 4, event, sarif), event
      %w[failure cancelled skipped].each do |result|
        4.times do |index|
          results = ["success"] * 4
          results[index] = result
          refute concludes(results, event, sarif), "#{event}: #{results}"
        end
      end
      (%w[success failure cancelled skipped] - [sarif]).each do |result|
        refute concludes(["success"] * 4, event, result), "#{event}: SARIF #{result}"
      end
    end
    refute concludes(["success"] * 4, "unknown", "skipped")
  end
end
