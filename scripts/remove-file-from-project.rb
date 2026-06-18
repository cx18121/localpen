#!/usr/bin/env ruby
# Remove file reference(s) from the Xcode project (all targets + groups). Mirror of
# add-file-to-target.rb. project.pbxproj is gitignored here, so deletions must be
# de-referenced or the build breaks on a missing file.
#
# Usage: ruby scripts/remove-file-from-project.rb <file1> [file2 ...]
require 'xcodeproj'

proj_path = File.expand_path(File.join(__dir__, '..', 'Localpen.xcodeproj'))
project = Xcodeproj::Project.open(proj_path)

removed = []
ARGV.each do |file|
  abs = File.expand_path(file)
  project.files.select { |f| f.real_path.to_s == abs }.each do |ref|
    ref.remove_from_project
    removed << File.basename(abs)
  end
end

project.save
puts removed.empty? ? "no matching references" : "removed: #{removed.join(', ')}"
