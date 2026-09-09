# frozen_string_literal: true

require "erb"
require "formulary"
require "resource_auditor"
require "simulate_system"

TEMPLATE_PATH = Pathname.new(ARGV.fetch(0))
PACKAGE = {
  "class_name" => "FsLint",
  "command" => "fs-lint",
  "repo" => "yowainwright/fs-lint",
  "desc" => "Enforce project file and folder structure",
  "homepage" => "https://github.com/yowainwright/fs-lint",
  "license" => "MIT",
  "asset_prefix" => "fs-lint"
}.freeze
TARGETS = {
  "darwin-arm64" => [:macos, :arm],
  "darwin-amd64" => [:macos, :intel],
  "linux-arm64" => [:linux, :arm],
  "linux-amd64" => [:linux, :intel]
}.freeze
VERSIONS = %w[0.2.0 0.2.1 1.2.3].freeze
FORMATS = %w[binary archive].freeze

def release_assets(data, version)
  tag = data.fetch("tag_template", "v%{version}") % { version: version }
  suffix = data.fetch("archive", false) ? ".tar.gz" : ""
  TARGETS.to_h do |target, _|
    asset = "#{data.fetch("asset_prefix")}-#{target}#{suffix}"
    url = "https://github.com/#{data.fetch("repo")}/releases/download/#{tag}/#{asset}"
    # Version detection is offline; downloading and checksum verification remain
    # part of the release's real Homebrew audit/install/test steps.
    [target, { "url" => url, "sha256" => "0" * 64 }]
  end
end

def render_formula(template, data, version, assets)
  values = data.transform_keys(&:to_sym)
  values.merge!(data: data, version: version, assets: assets)
  ERB.new(template, trim_mode: "-").result_with_hash(values)
end

def audit_formula(source, target, version, expected_url)
  path = Pathname.new(__dir__)/"#{target}-#{version}"/"fs-lint.rb"
  tap = Tap.fetch("yowainwright/tap")
  formula = Formulary.from_contents("fs-lint", path, source, tap: tap)
  abort "#{target}: expected version #{version}, got #{formula.version}" unless formula.version.to_s == version
  abort "#{target}: unexpected asset URL #{formula.stable.url}" unless formula.stable.url == expected_url

  auditor = Homebrew::ResourceAuditor.new(formula.stable, :stable, strict: true)
  auditor.audit_version
  abort "#{target} #{version}: #{auditor.problems.join("; ")}" unless auditor.problems.empty?
end

def audit_release(template, version, format)
  data = PACKAGE.merge("archive" => format == "archive")
  assets = release_assets(data, version)
  source = render_formula(template, data, version, assets)
  TARGETS.each do |target, (os, arch)|
    Homebrew::SimulateSystem.with(os: os, arch: arch) do
      audit_formula(source, "#{format}-#{target}", version, assets.fetch(target).fetch("url"))
    end
  end
end

template = TEMPLATE_PATH.read
VERSIONS.each do |version|
  FORMATS.each { |format| audit_release(template, version, format) }
end
case_count = TARGETS.length * VERSIONS.length * FORMATS.length
puts "Homebrew template: all #{case_count} platform/version/format cases passed"
