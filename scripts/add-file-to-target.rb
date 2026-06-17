#!/usr/bin/env ruby
# Add source file(s) to an Xcode target, placing each in the group that mirrors its
# on-disk folder. Idempotent: skips files already referenced. project.pbxproj is gitignored
# in this repo, so new files MUST be registered here or the build won't see them.
#
# Usage: ruby scripts/add-file-to-target.rb <TargetName> <file1> [file2 ...]
require 'xcodeproj'

proj_path = File.expand_path(File.join(__dir__, '..', 'Localpen.xcodeproj'))
project = Xcodeproj::Project.open(proj_path)
target_name = ARGV.shift
target = project.targets.find { |t| t.name == target_name }
abort("target not found: #{target_name}") unless target

def group_for(project, rel_dir)
  group = project.main_group
  rel_dir.split('/').reject(&:empty?).each do |part|
    group = group[part] || group.new_group(part, part)
  end
  group
end

added = []
ARGV.each do |file|
  abs = File.expand_path(file)
  rel = abs.sub(File.expand_path(File.join(__dir__, '..')) + '/', '')
  base = File.basename(rel)
  if project.files.any? { |f| f.real_path.to_s == abs }
    next
  end
  group = group_for(project, File.dirname(rel))
  ref = group.new_reference(abs)
  target.add_file_references([ref])
  added << rel
end

project.save
puts added.empty? ? "no new files (already present)" : "added: #{added.join(', ')}"
