#!/usr/bin/env ruby
# frozen_string_literal: true

# Search and quote the Guide to Advancement 2025.
#
# Builds a cached, page-tagged text extraction of docs/guide-to-advancement-2025.pdf
# and lets you search it, pull a whole numbered section, or dump printed pages.
#
# Every location is reported two ways:
#   - the Guide's own section number (e.g. 8.0.1.1) -- the citation scheme the
#     Guide itself and its index use
#   - the *printed* page number shown at the bottom of the page
#
# The PDF's internal page numbering runs ahead of the printed number (printed
# page 55 is PDF page 57). The offset is measured from the page footers at build
# time. Only pass printed numbers to this script; it converts internally. If you
# need the Read tool to look at a page image, use the PDF page number, which this
# script prints alongside every result.
#
# Usage:
#     gta.rb search "board of review" [--context 3] [--max 25]
#     gta.rb section 8.0.1.1
#     gta.rb page 55 [--to 57]
#     gta.rb toc [--section 8]
#     gta.rb build [--force]

require "json"
require "open3"
require "optparse"

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
PDF = File.join(REPO_ROOT, "docs", "guide-to-advancement-2025.pdf")
CACHE = File.join(SKILL_DIR, ".cache")
TEXT = File.join(CACHE, "pages.txt")
SECTIONS = File.join(CACHE, "sections.json")

PAGE_SEP = "\f"
# Front matter and table of contents: section numbers there are listings, not headings.
FIRST_BODY_PAGE = 8
# Fallback if no page footers can be read.
DEFAULT_PAGE_OFFSET = 2

# A heading line: "8.0.1.1 Not a Retest or “Examination”" -- four or five parts.
HEADING_RE = /\A((?:\d+\.){3,4}\d+)\s+(\S.*)\z/
# A line holding nothing but a page number, as contents listings produce.
BARE_NUMBER_RE = /\A\d{1,3}\z/
# "GUIDE TO ADVANCEMENT | 55" -- the printed page number, on odd PDF pages.
FOOTER_RE = /GUIDE TO ADVANCEMENT \| (\d+)/
# Junk the PDF text layer carries into headings.
CTRL_RE = /[\x00-\x08\x0b-\x1f]/

def die(msg)
  warn "error: #{msg}"
  exit 1
end

def section_key(num)
  num.split(".").map(&:to_i)
end

# --------------------------------------------------------------------------
# build

def extract_pages
  die "missing #{PDF}" unless File.exist?(PDF)
  # No -layout: raw mode follows reading order, so the Guide's two-column pages
  # come out as continuous prose instead of interleaved columns.
  #
  # This stays a pdftotext shellout even though the pdf-reader gem is in the
  # Gemfile. Measured against this PDF, pdf-reader reconstructs pages by glyph
  # position, which interleaves the two columns line by line, and it emits every
  # heading and contents entry without inter-word spaces ("8.0.1.1NotaRetestor"),
  # so HEADING_RE never matches and section titles are unrecoverable. pdf-reader
  # is fine on docs/Scouts-BSA-Requirements-2025.pdf, which is single-column.
  out, err, status = Open3.capture3("pdftotext", PDF, "-")
  die "pdftotext not found (brew install poppler)" if status.nil?
  die "pdftotext failed: #{err.strip}" unless status.success?
  out.split(PAGE_SEP)
rescue Errno::ENOENT
  die "pdftotext not found (brew install poppler)"
end

# printed_page + offset == pdf_page, measured from the footers themselves.
def measure_page_offset(pages)
  tally = Hash.new(0)
  pages.each_with_index do |text, idx|
    printed = text[FOOTER_RE, 1] or next
    tally[(idx + 1) - printed.to_i] += 1
  end
  return DEFAULT_PAGE_OFFSET if tally.empty?

  offset, count = tally.max_by { |_, n| n }
  warn "warning: page offset is inconsistent (#{tally.inspect}); using #{offset}" if count < tally.values.sum
  offset
end

# Map section number -> full title, read from the front-matter contents listing.
#
# Body headings wrap across lines in the Guide's two-column layout and there is no
# reliable way to tell a heading's second line from the body text that follows it,
# so titles taken from body pages come out truncated. The contents listing wraps
# too, but there a continuation is unambiguous: any line that is neither a new
# entry nor a bare page number.
def parse_toc(pages)
  titles = {}
  (1...FIRST_BODY_PAGE).each do |pdf_page|
    lines = pages[pdf_page - 1].to_s.split("\n").map { |l| l.gsub(CTRL_RE, "").strip }
    idx = 0
    while idx < lines.size
      match = HEADING_RE.match(lines[idx])
      unless match
        idx += 1
        next
      end

      title = match[2].dup
      idx += 1
      while idx < lines.size && !lines[idx].empty? &&
            !HEADING_RE.match?(lines[idx]) && !/\A\d+\z/.match?(lines[idx])
        title << " " << lines[idx]
        idx += 1
      end
      titles[match[1]] = title.squeeze(" ").strip
    end
  end
  titles
end

# Map section number -> {pdf_page, line, printed_page, title}.
#
# A section number can appear three ways once layout is stripped: as a real
# heading, as the running header at the top of the page, and as a cross-reference
# in body text. The running header always repeats a heading found later on the
# same page, so drop a first-line match that recurs below it. Sections run in
# ascending order through the document, so for the rest we collect every
# candidate and walk the numbers in order, taking the first candidate at or after
# the position where the previous section landed.
# Several heading-shaped lines plus several lines holding only a page number: that
# is a contents listing, not a run of real headings.
def contents_listing?(lines)
  stripped = lines.map { |l| l.gsub(CTRL_RE, "").strip }
  stripped.count { |l| HEADING_RE.match?(l) } >= 3 &&
    stripped.count { |l| BARE_NUMBER_RE.match?(l) } >= 2
end

# On a contents listing, map each entry to the printed page it points at: either a
# number trailing the entry itself or the next line holding only a number.
def parse_listing_pages(lines)
  stripped = lines.map { |l| l.gsub(CTRL_RE, "").strip }
  listed = {}
  stripped.each_with_index do |line, idx|
    match = HEADING_RE.match(line) or next
    if (trailing = match[2][/\s(\d{1,3})\z/, 1])
      listed[match[1]] = trailing.to_i
      next
    end
    following = stripped[(idx + 1)..].find { |l| BARE_NUMBER_RE.match?(l) || HEADING_RE.match?(l) }
    listed[match[1]] = following.to_i if following && BARE_NUMBER_RE.match?(following)
  end
  listed
end

def find_headings(pages, offset)
  titles = parse_toc(pages)
  listed_pages = {}
  candidates = Hash.new { |h, k| h[k] = [] }

  pages.each_with_index do |text, idx|
    pdf_page = idx + 1
    next if pdf_page < FIRST_BODY_PAGE

    lines = text.split("\n")
    matches = []
    lines.each_with_index do |raw, line_no|
      match = HEADING_RE.match(raw.gsub(CTRL_RE, "").strip) or next
      next if match[2].strip.length < 4

      matches << [line_no, match[1], match[2].strip]
    end

    # Drop the running header when the same number appears again on this page.
    if matches.size > 1 && matches.first[0].zero?
      running = matches.first[1]
      matches.shift if matches.drop(1).any? { |m| m[1] == running }
    end

    # A section-divider page announces the section and then lists its children with
    # their page numbers (Section 11's appendix page does this). Only the first
    # heading really begins here; the rest begin on the pages being listed.
    if contents_listing?(lines)
      listed_pages.merge!(parse_listing_pages(lines))
      matches = matches.first(1)
    end

    matches.each { |line_no, num, title| candidates[num] << [pdf_page, line_no, title] }
  end

  resolved = {}
  floor = [0, 0]
  candidates.keys.sort_by { |num| section_key(num) }.each do |num|
    options = candidates[num]
    pick = options.find { |page, line, _| ([page, line] <=> floor) >= 0 } || options.first
    resolved[num] = {
      "pdf_page" => pick[0],
      "line" => pick[1],
      "printed_page" => pick[0] - offset,
      # The contents listing has the untruncated title; fall back to the body heading.
      "title" => titles[num] || pick[2]
    }
    floor = [pick[0], pick[1]] if ([pick[0], pick[1]] <=> floor) > 0
  end

  # Appendix forms print their title but not their section number, so they have no
  # body candidate at all. The listing that points at them is the only source.
  listed_pages.each do |num, printed|
    next if resolved.key?(num)

    resolved[num] = {
      "pdf_page" => printed + offset,
      "line" => 0,
      "printed_page" => printed,
      "title" => titles[num] || num,
      "from_listing" => true
    }
  end
  resolved
end

def build(force: false)
  if !force && File.exist?(TEXT) && File.exist?(SECTIONS) &&
     File.mtime(TEXT) >= File.mtime(PDF)
    return
  end

  Dir.mkdir(CACHE) unless Dir.exist?(CACHE)
  pages = extract_pages
  offset = measure_page_offset(pages)
  sections = find_headings(pages, offset)
  File.write(TEXT, pages.join(PAGE_SEP))
  File.write(SECTIONS, JSON.pretty_generate("page_offset" => offset, "sections" => sections))
  warn "built cache: #{pages.size} pages, #{sections.size} sections, page offset #{offset}"
end

def load_guide
  build
  pages = File.read(TEXT).split(PAGE_SEP)
  data = JSON.parse(File.read(SECTIONS))
  [pages, data["sections"], data["page_offset"]]
end

# --------------------------------------------------------------------------
# lookup helpers

# [pdf_page, line, section_number] in document order, for locating a hit.
def heading_positions(sections)
  sections.map { |num, meta| [meta["pdf_page"], meta["line"], num] }
          .sort_by { |page, line, num| [page, line, section_key(num)] }
end

# Last section that begins at or before this position.
def section_for(positions, pdf_page, line = Float::INFINITY)
  best = ""
  positions.each do |page, heading_line, num|
    break if page > pdf_page || (page == pdf_page && heading_line > line)

    best = num
  end
  best
end

def cite(sections, num, printed_page, offset)
  title = sections.dig(num, "title").to_s
  # Titles carry their own curly quotes, so separate with a dash rather than nesting.
  label = title.empty? ? num : "#{num} — #{title}"
  label = "(before first numbered section)" if num.empty?
  "[#{label}, printed p.#{printed_page} / PDF p.#{printed_page + offset}]"
end

# --------------------------------------------------------------------------
# commands

def cmd_search(argv)
  context = 3
  max = 25
  parser = OptionParser.new do |o|
    o.banner = "usage: gta.rb search PATTERN [--context N] [--max N]"
    o.on("--context N", Integer, "lines around each hit (default 3)") { |v| context = v }
    o.on("--max N", Integer, "max matches to print (default 25)") { |v| max = v }
  end
  parser.parse!(argv)
  pattern_src = argv.shift or die parser.banner

  begin
    pattern = Regexp.new(pattern_src, Regexp::IGNORECASE)
  rescue RegexpError => e
    die "bad regex: #{e.message}"
  end

  pages, sections, offset = load_guide
  positions = heading_positions(sections)

  shown = 0
  pages.each_with_index do |text, idx|
    pdf_page = idx + 1
    next if pdf_page < FIRST_BODY_PAGE

    lines = text.split("\n")
    lines.each_with_index do |line, line_no|
      next unless pattern.match?(line)

      if shown >= max
        puts "\n... stopped at #{max} matches; narrow the pattern or raise --max"
        return
      end
      shown += 1
      num = section_for(positions, pdf_page, line_no)
      puts "\n=== #{cite(sections, num, pdf_page - offset, offset)}"
      lo = [0, line_no - context].max
      hi = [lines.size - 1, line_no + context].min
      (lo..hi).each do |j|
        puts " #{j == line_no ? '>' : ' '} #{lines[j]}"
      end
    end
  end

  puts shown.zero? ? "no matches" : "\n(#{shown} matches)"
end

def cmd_section(argv)
  num = argv.shift or die "usage: gta.rb section NUMBER (e.g. 8.0.1.1)"
  pages, sections, offset = load_guide

  unless sections.key?(num)
    # Try the number itself as a prefix, then widen to its parents: 8.0.9.9 -> 8.0 -> 8.
    prefixes = num.split(".").length.downto(1).map { |n| num.split(".").first(n).join(".") }
    near = prefixes.lazy.map { |p| sections.keys.select { |s| s.start_with?(p) } }
                   .find { |hits| !hits.empty? } || []
    near = near.sort_by { |s| section_key(s) }.first(8)
    hint = near.empty? ? "" : " Did you mean: #{near.join(', ')}"
    die "unknown section #{num}.#{hint}"
  end

  positions = heading_positions(sections)
  index = positions.index { |_, _, n| n == num }
  start_page, start_line, = positions[index]
  nxt = positions[index + 1]
  end_page = nxt ? nxt[0] : pages.size
  end_line = nxt ? nxt[1] : Float::INFINITY

  puts "=== #{cite(sections, num, start_page - offset, offset)}\n\n"
  (start_page..[end_page, pages.size].min).each do |pdf_page|
    lines = pages[pdf_page - 1].split("\n")
    lo = pdf_page == start_page ? start_line : 0
    hi = pdf_page == end_page ? end_line - 1 : lines.size - 1
    hi = [hi, lines.size - 1].min
    next if hi < lo

    puts "--- printed p.#{pdf_page - offset} ---"
    puts lines[lo..hi].join("\n").sub(/\n+\z/, "")
    puts
  end
end

def cmd_page(argv)
  last = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: gta.rb page PRINTED_PAGE [--to PRINTED_PAGE]"
    o.on("--to N", Integer, "print through this printed page") { |v| last = v }
  end
  parser.parse!(argv)
  first = argv.shift or die parser.banner
  first = Integer(first, exception: false) or die parser.banner
  last ||= first

  pages, sections, offset = load_guide
  positions = heading_positions(sections)

  (first..last).each do |printed|
    pdf_page = printed + offset
    die "printed page #{printed} out of range (1..#{pages.size - offset})" unless (1..pages.size).cover?(pdf_page)

    # What the page opens in, then what begins on it -- a page usually spans several.
    opens_in = section_for(positions, pdf_page, -1)
    starts = positions.select { |page, _, _| page == pdf_page }.map(&:last)
    header = "=== printed p.#{printed} / PDF p.#{pdf_page} — opens in #{opens_in.empty? ? '?' : opens_in}"
    header += "; begins here: #{starts.join(', ')}" unless starts.empty?
    puts header
    puts pages[pdf_page - 1].sub(/\A\n+/, "").sub(/\n+\z/, "")
    puts
  end
end

def cmd_toc(argv)
  restrict = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: gta.rb toc [--section N]"
    o.on("--section N", "restrict to a top-level section number") { |v| restrict = v }
  end
  parser.parse!(argv)

  _, sections, = load_guide
  sections.keys.sort_by { |num| section_key(num) }.each do |num|
    next if restrict && !num.start_with?("#{restrict}.")

    meta = sections[num]
    indent = "  " * [num.count(".") - 3, 0].max
    puts format("%-12s %s%s  (p.%d)", num, indent, meta["title"], meta["printed_page"])
  end
end

def cmd_build(argv)
  force = false
  OptionParser.new do |o|
    o.banner = "usage: gta.rb build [--force]"
    o.on("--force", "rebuild even if the cache is current") { force = true }
  end.parse!(argv)
  build(force: force)
end

USAGE = <<~TEXT
  usage: gta.rb COMMAND [options]

    search PATTERN [--context N] [--max N]   case-insensitive regex search
    section NUMBER                           print a numbered section, e.g. 8.0.1.1
    page PRINTED_PAGE [--to N]               print printed page(s)
    toc [--section N]                        list sections with printed pages
    build [--force]                          (re)build the text cache
TEXT

argv = ARGV.dup
case argv.shift
when "search" then cmd_search(argv)
when "section" then cmd_section(argv)
when "page" then cmd_page(argv)
when "toc" then cmd_toc(argv)
when "build" then cmd_build(argv)
else die USAGE
end
