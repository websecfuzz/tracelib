#!/bin/sh

set -u

EMPTY_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

COVDIR="${TRACELIB_COVERAGE_DIR:-/coverage}"
JSON="$COVDIR/coverage.json"

if [ ! -s "$JSON" ]; then
    echo "coverage_report: 0 files, 0 / 0 lines covered (0.00%)"
    echo "coverage_hash: $EMPTY_HASH"
    exit 0
fi

ruby -rjson -rdigest -e '
  data = JSON.parse(File.read(ARGV[0])) rescue {}
  files = 0
  total = 0
  hit = 0
  covered = []
  data.each do |path, lines|
    next unless lines.is_a?(Array)
    files += 1
    lines.each_with_index do |c, index|
      next if c.nil?
      total += 1
      if c.is_a?(Integer) && c > 0
        hit += 1
        covered << "#{path}:#{index + 1}"
      end
    end
  end
  pct = total > 0 ? (100.0 * hit / total) : 0.0
  printf("coverage_report: %d files, %d / %d lines covered (%.2f%%)\n", files, hit, total, pct)
  print("coverage_hash: ", Digest::SHA256.hexdigest(covered.sort.uniq.join("\n")), "\n")
  if ENV["TRACELIB_COVERAGE_INCLUDE_ITEMS"] == "1"
    covered.sort.uniq.each { |item| print("coverage_item: ", item, "\n") }
  end
' "$JSON"
