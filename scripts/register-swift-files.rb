#!/usr/bin/env ruby
# Register new Swift source files in HermesMobile.xcodeproj.
#
# Usage: ruby scripts/register-swift-files.rb <repo-relative-path>...
#
# The target is inferred from the path prefix (HermesMobile/ -> app target,
# HermesMobileTests/ -> test target, etc.), and the file is placed in the
# group matching its directory, creating intermediate groups as needed.
# Idempotent: paths already present in the project are skipped.

require "xcodeproj"

TARGET_BY_PREFIX = {
  "HermesMobile/" => "HermesMobile",
  "HermesMobileTests/" => "HermesMobileTests",
  "HermesShareExtension/" => "HermesShareExtension",
  "HermesLiveActivityWidget/" => "HermesLiveActivityWidget",
}.freeze

repo_root = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(repo_root, "HermesMobile.xcodeproj"))

existing = project.files.map { |f| f.real_path.to_s }.to_set rescue nil
if existing.nil?
  require "set"
  existing = project.files.map { |f| f.real_path.to_s }.to_set
end

changed = false

ARGV.each do |rel|
  abort "Path must be repo-relative: #{rel}" if rel.start_with?("/")
  abs = File.join(repo_root, rel)
  abort "No such file: #{rel}" unless File.file?(abs)

  prefix, target_name = TARGET_BY_PREFIX.find { |pfx, _| rel.start_with?(pfx) }
  abort "Cannot infer target for #{rel}" unless prefix

  if existing.include?(abs)
    puts "already registered: #{rel}"
    next
  end

  target = project.targets.find { |t| t.name == target_name }
  abort "Target not found: #{target_name}" unless target

  # Walk/create the group hierarchy matching the directory path.
  group = project.main_group.children.find { |c| c.display_name == prefix.chomp("/") }
  abort "Root group not found for #{prefix}" unless group
  dirs = File.dirname(rel).split("/")[1..] || []
  dirs.each do |dir|
    next if dir == "."
    sub = group.children.find { |c| c.display_name == dir && c.is_a?(Xcodeproj::Project::Object::PBXGroup) }
    sub ||= group.new_group(dir, dir)
    group = sub
  end

  ref = group.new_file(File.basename(rel))
  target.add_file_references([ref])
  puts "registered: #{rel} -> #{target_name}"
  changed = true
end

project.save if changed
puts changed ? "project saved" : "no changes"
