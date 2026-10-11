#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "yaml"

module WorkflowPins
  ROOT = File.expand_path("..", __dir__)
  WORKFLOWS = File.join(ROOT, ".github", "workflows")
  FULL_SHA = /\A[0-9a-f]{40}\z/

  module_function

  def mutable_references(paths = Dir.glob(File.join(WORKFLOWS, "*.{yml,yaml}")))
    paths.sort.flat_map do |path|
      document = YAML.safe_load_file(
        path,
        permitted_classes: [Date, Time],
        aliases: true
      )
      action_references(document).filter_map do |reference|
        next if reference.start_with?("./")

        revision = reference.include?("@") ? reference.rpartition("@").last : ""
        next if FULL_SHA.match?(revision)

        "#{relative_path(path)}: #{reference}"
      end
    rescue Psych::SyntaxError => error
      ["#{relative_path(path)}: invalid YAML (#{error.problem})"]
    end
  end

  def action_references(document)
    jobs = document.is_a?(Hash) ? document["jobs"] : nil
    return [] unless jobs.is_a?(Hash)

    jobs.values.flat_map do |job|
      next [] unless job.is_a?(Hash)

      references = []
      references << String(job["uses"]) if job.key?("uses")
      if job["steps"].is_a?(Array)
        job["steps"].each do |step|
          references << String(step["uses"]) if step.is_a?(Hash) && step.key?("uses")
        end
      end
      references
    end
  end

  def relative_path(path)
    path.delete_prefix("#{ROOT}/")
  end
end

if $PROGRAM_NAME == __FILE__
  findings = WorkflowPins.mutable_references
  if findings.empty?
    puts "All external GitHub Action references are pinned to full SHAs."
    exit 0
  end

  warn "Mutable or invalid GitHub Action references found:"
  findings.each { |finding| warn "- #{finding}" }
  exit 1
end
