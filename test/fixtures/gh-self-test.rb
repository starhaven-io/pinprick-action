#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

mode = ENV.fetch("SHIM_MODE")
sha = ENV.fetch("SHIM_SHA")
state = ENV.fetch("SHIM_STATE")
args = ARGV.join(" ")
count = File.exist?(state) ? File.read(state).to_i : 0
if args.include?("repos/example/project/actions/workflows/self-test.yml/runs")
  ["head_sha=#{sha}", "branch=main", "event=push", "per_page=100"].each do |constraint|
    abort "shim: missing workflow-run constraint #{constraint}" unless args.include?(constraint)
  end
  count += 1
  File.write(state, count.to_s)
  exit 1 if mode == "api-then-success" && count == 1
  if mode == "malformed-runs"
    puts "{"
    exit
  end
  run = { id: 123, head_sha: sha, head_branch: "main", event: "push", status: "completed",
          conclusion: "success", created_at: "2026-09-06T00:00:00Z", html_url: "https://example.com/run/123" }
  run[:head_sha] = "b" * 40 if mode == "wrong-sha"
  run[:head_branch] = "other" if mode == "wrong-branch"
  run[:event] = "pull_request" if mode == "wrong-event"
  run[:status] = "queued" if mode == "queued-then-success" && count == 1
  run[:conclusion] = "failure" if %w[failure missing-conclusion preview-failure].include?(mode)
  run[:id] = "invalid" if mode == "invalid-run-id"
  runs = mode == "missing" ? [] : [run]
  if mode == "newer-run-failure"
    runs.unshift(run.merge(id: 456, created_at: "2026-09-07T00:00:00Z", conclusion: "failure"))
  end
  puts JSON.generate(workflow_runs: runs)
elsif args.match?(%r{repos/example/project/actions/runs/(123|456)/jobs})
  ["filter=latest", "per_page=100"].each do |constraint|
    abort "shim: missing jobs constraint #{constraint}" unless args.include?(constraint)
  end
  exit 1 if mode == "jobs-api-then-success" && count == 1
  if mode == "malformed-jobs"
    puts JSON.generate(jobs: nil)
    exit
  end
  job = { name: "conclusion", status: "completed", conclusion: "success", html_url: "https://example.com/job/456" }
  job[:status] = "queued" if mode == "queued-then-success" && count == 1
  job[:conclusion] = "failure" if mode == "failure" || (mode == "newer-run-failure" && args.include?("/456/"))
  jobs = mode == "missing-conclusion" ? [] : [job]
  jobs << job if mode == "duplicate-conclusion"
  puts JSON.generate(jobs: jobs)
else
  abort "shim: unexpected API route: #{args}"
end
