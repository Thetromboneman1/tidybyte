# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../scripts/validate_workflow_pins"

class WorkflowPinsTest < Minitest::Test
  PINNED = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"

  def findings_for(source)
    Tempfile.create(["workflow", ".yml"]) do |file|
      file.write(source)
      file.flush
      return WorkflowPins.mutable_references([file.path])
    end
  end

  def test_accepts_pinned_and_local_actions
    source = <<~YAML
      jobs:
        test:
          uses: ./.github/workflows/reusable.yml
        build:
          steps:
            - uses: #{PINNED}
            - uses: ./local-action
            - uses: #{PINNED}
              with:
                uses: production
    YAML

    assert_empty findings_for(source)
  end

  def test_rejects_mutable_references_for_all_valid_yaml_key_styles
    sources = [
      "jobs: {test: {steps: [{uses: actions/checkout@v4}]}}",
      "jobs:\n  test:\n    steps:\n      - uses : actions/checkout@v4\n",
      "jobs:\n  test:\n    steps:\n      - \"uses\": actions/checkout@v4\n"
    ]

    sources.each do |source|
      assert_equal 1, findings_for(source).length
    end
  end

  def test_rejects_mutable_job_level_reusable_workflow
    source = "jobs: {test: {uses: owner/repository/.github/workflows/test.yml@main}}"

    assert_equal 1, findings_for(source).length
  end

  def test_rejects_invalid_yaml
    refute_empty findings_for("jobs: [")
  end
end
