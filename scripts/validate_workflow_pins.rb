#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

module WorkflowPins
  ROOT = File.expand_path("..", __dir__)
  WORKFLOWS = File.join(ROOT, ".github", "workflows")
  FULL_SHA = /\A[0-9a-f]{40}\z/

  module_function

  def mutable_references(paths = Dir.glob(File.join(WORKFLOWS, "*.{yml,yaml}")))
    paths.sort.flat_map do |path|
      document = YAML.safe_load_file(path, aliases: true)
      references(document).filter_map do |reference|
        next if reference.start_with?("./")

        revision = reference.include?("@") ? reference.rpartition("@").last : ""
        next if FULL_SHA.match?(revision)

        "#{relative_path(path)}: #{reference}"
      end
    rescue Psych::SyntaxError => error
      ["#{relative_path(path)}: invalid YAML (#{error.problem})"]
    end
  end

  def references(node)
    case node
    when Hash
      node.flat_map do |key, value|
        current = key == "uses" ? [String(value)] : []
        current + references(value)
      end
    when Array
      node.flat_map { |value| references(value) }
    else
      []
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
