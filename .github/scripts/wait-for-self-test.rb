#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

class SelfTestGate
  class Error < StandardError; end

  def initialize(env = ENV)
    @repository = env.fetch("REPOSITORY", "")
    @sha = env.fetch("COMMIT_SHA", "")
    @branch = env.fetch("SELF_TEST_BRANCH", "")
    @branch = "main" if @branch.empty?
    attempts = env.fetch("SELF_TEST_MAX_ATTEMPTS", "")
    attempts = "120" if attempts.empty?
    seconds = env.fetch("SELF_TEST_POLL_SECONDS", "")
    seconds = "10" if seconds.empty?
    validate!(@repository, %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}, "REPOSITORY must be an owner/repository name")
    validate!(@sha, /\A[0-9a-f]{40}\z/, "COMMIT_SHA must be a full lowercase commit SHA")
    validate!(@branch, %r{\A[A-Za-z0-9._/-]+\z}, "SELF_TEST_BRANCH is invalid")
    validate!(attempts, /\A[1-9][0-9]*\z/, "SELF_TEST_MAX_ATTEMPTS must be a positive integer")
    validate!(seconds, /\A[0-9]+\z/, "SELF_TEST_POLL_SECONDS must be a non-negative integer")
    @attempts = attempts.to_i
    @seconds = seconds.to_i
  end

  def run
    1.upto(@attempts) do |attempt|
      return if poll(attempt)

      sleep @seconds if attempt < @attempts
    end
    raise Error, "Self-test did not succeed for #{@sha} after #{@attempts} attempts"
  end

  private

  def validate!(value, pattern, message)
    raise Error, message unless pattern.match?(value)
  end

  def api(path, fields, label)
    output, status = Open3.capture2("gh", "api", "--method", "GET", "repos/#{@repository}/#{path}",
                                   *fields.flat_map { |key, value| ["-f", "#{key}=#{value}"] })
    return nil unless status.success?

    data = JSON.parse(output)
    raise Error, "Could not parse the Self-test #{label} response" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise Error, "Could not parse the Self-test #{label} response"
  end

  def entries(data, key, label)
    items = data[key]
    unless items.is_a?(Array) && items.all? { |item| item.is_a?(Hash) }
      raise Error, "Could not parse the Self-test #{label} response"
    end
    items
  end

  def poll(attempt)
    suffix = "for #{@sha} (attempt #{attempt}/#{@attempts})"
    response = api("actions/workflows/self-test.yml/runs",
                   { head_sha: @sha, branch: @branch, event: "push", per_page: 100 }, "workflow runs")
    unless response
      warn "Waiting after a Self-test API error #{suffix}"
      return false
    end

    runs = entries(response, "workflow_runs", "workflow runs").select do |run|
      run["head_sha"] == @sha && run["head_branch"] == @branch && run["event"] == "push"
    end
    unless runs.all? { |run| run["created_at"].is_a?(String) }
      raise Error, "Could not parse the Self-test workflow runs response"
    end
    run = runs.sort_by { |item| item.fetch("created_at") }.last
    unless run
      puts "Waiting for the Self-test push run #{suffix}"
      return false
    end
    validate!(run["id"].to_s, /\A[1-9][0-9]*\z/, "Self-test returned an invalid workflow run id")

    response = api("actions/runs/#{run.fetch('id')}/jobs", { filter: "latest", per_page: 100 }, "jobs")
    unless response
      warn "Waiting after a Self-test jobs API error #{suffix}"
      return false
    end
    jobs = entries(response, "jobs", "jobs").select { |job| job["name"] == "conclusion" }
    raise Error, "Self-test returned multiple conclusion jobs" if jobs.length > 1

    job = jobs.first
    if job
      status = job.fetch("status", "unknown")
      conclusion = job["conclusion"]
      url = job.fetch("html_url", "unknown")
      if status == "completed"
        if conclusion == "success"
          puts "Self-test conclusion succeeded for #{@sha}: #{url}"
          return true
        end
        raise Error, "Self-test conclusion completed with '#{conclusion.to_s.empty? ? 'no conclusion' : conclusion}' for #{@sha}: #{url}"
      end
      puts "Waiting for the Self-test conclusion on #{@sha} (#{status}, attempt #{attempt}/#{@attempts})"
    elsif run["status"] == "completed"
      conclusion = run["conclusion"]
      raise Error, "Self-test completed with '#{conclusion.to_s.empty? ? 'no conclusion' : conclusion}' but no conclusion job for #{@sha}: #{run.fetch('html_url', 'unknown')}"
    else
      puts "Waiting for the Self-test conclusion job on #{@sha} (attempt #{attempt}/#{@attempts})"
    end
    false
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  begin
    SelfTestGate.new.run
  rescue SelfTestGate::Error, SystemCallError => e
    warn "::error::#{e.message}"
    exit 1
  end
end
