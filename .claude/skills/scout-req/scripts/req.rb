#!/usr/bin/env ruby
# frozen_string_literal: true

#
# scout-req -- read rank, merit badge, and award requirements out of
# docs/Scouts-BSA-Requirements-2025.pdf.
#
# The book has no section numbers to cite, so entries are found structurally:
# every rank, merit badge, and award heading in it is set in 21pt RockwellStd,
# and nothing else in the book is. That one fact is what the index rests on --
# see EXTRACTION NOTES below before changing any of it.
#
# Every result is reported with the *printed* page number (the number at the
# foot of the page) and the PDF page number, because they differ by two.
#
#   ruby scripts/req.rb show NAME [--kind rank|badge|award]
#   ruby scripts/req.rb list [--kind K] [--letter A] [--pamphlet-year YYYY]
#   ruby scripts/req.rb search PATTERN [--kind K] [--context N] [--max N]
#   ruby scripts/req.rb page PRINTED_PAGE [--to PRINTED_PAGE]
#   ruby scripts/req.rb updates [NAME]
#   ruby scripts/req.rb verify
#   ruby scripts/req.rb build [--force]
#
# Exit codes: 0 fine, 1 error, 3 the answer needs requirements this book does
# not carry (see NEED_NEWER).
#
# Needs `pdftotext` and `pdftohtml` (both poppler): brew install poppler

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "did_you_mean"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rexml/document"

PDF = File.join(REPO_ROOT, "docs", "Scouts-BSA-Requirements-2025.pdf")
CACHE = File.join(SKILL_DIR, ".cache")
TEXT = File.join(CACHE, "pages.txt")
INDEX = File.join(CACHE, "index.json")
BEYOND = File.join(SKILL_DIR, "data", "beyond-2025.json")

# The book's requirements are effective Jan. 1 of this year. Anything a Scout
# started after Dec. 31 of it is out of this book's scope.
BOOK_YEAR = 2025
BOOK_LABEL = "Scouts BSA Requirements #{BOOK_YEAR}".freeze

# Exit status for "this needs requirements the 2025 book does not carry."
# Distinct from 1 so the skill can tell a missing badge from a broken argument.
NEED_NEWER = 3

PAGE_SEP = "\f"

# --------------------------------------------------------------------------
# EXTRACTION NOTES -- measured against docs/Scouts-BSA-Requirements-2025.pdf
# (Adobe InDesign 20.0, 308 pages). Each of these was established by getting it
# wrong first; none is recoverable by reading the code alone.
#
# - **Headings are found by font, not by shape.** Every entry heading -- rank,
#   merit badge, and award alike -- is 21pt RockwellStd, and nothing else in the
#   book is. There is no other signal: a heading is an unnumbered line of plain
#   words, indistinguishable in `pdftotext` output from the many requirement
#   lines that are also unnumbered ("Note to the Counselor", continuation lines,
#   the option lists inside Sports and Athletics). Matching heading *text*
#   against a hardcoded badge list was the first attempt and it silently missed
#   every wrapped heading.
# - **`pdftohtml -xml` for the index, `pdftotext` for the body.** The XML carries
#   font size and glyph position, which is the whole basis of the index, but it
#   breaks the text into positioned fragments that read badly. Plain `pdftotext`
#   (no `-layout`; this book is single-column) gives clean reading order for the
#   requirement text itself. Both are run over the same PDF and cross-checked in
#   `verify`.
# - **Headings wrap, and a wrapped heading is two 21pt elements 21px apart.**
#   "Fish and Wildlife" / "Management", "National Court of Honor" / "Lifesaving,
#   Meritorious Action," / "and Heroism Awards". Distinct headings that share a
#   page are hundreds of px apart -- there is no near miss anywhere in the book,
#   so WRAP_GAP has wide margin.
# - **Page 277 carries an off-canvas duplicate of the 50-Miler Award** at
#   left=-408: InDesign overflow that never printed. `pdftotext` drops it and the
#   XML does not, so without the `left >= 0` filter the index gains a phantom
#   second 50-Miler whose body text cannot be located. Any element at negative
#   left is not on the page.
# - **Some headings carry an empty 21pt element** ahead of the real one (page
#   184, before Nuclear Science). Blank fragments must be dropped before wrapped
#   segments are joined, or the join starts from the blank.
# - **The Merit Badge Library on the last printed page is an independent list of
#   every merit badge,** with the year of each pamphlet's latest requirements.
#   `verify` reconciles the two lists against each other -- it is the only
#   cross-check this book offers, and it is what catches a heading the font rule
#   missed or invented. The library abbreviates ("Pulp & Paper", "Signs,
#   Signals, Codes"), which is why `normalize` folds "&" to "and" and then drops
#   "and" entirely.
# - **Printed page + 2 == PDF page,** measured from the page footers rather than
#   assumed.
# --------------------------------------------------------------------------

# Entry headings: 21pt RockwellStd. The subset prefix ("FAGOTS+") varies by
# printing, so anchor on the family name only.
HEADING_SIZE = 21
HEADING_FAMILY = /\+RockwellStd\z/
# The A-Z tabs down the merit badge section.
LETTER_SIZE = 48
# The three section divider pages.
DIVIDER_SIZE = 30
# Vertical distance between the lines of one wrapped heading.
WRAP_GAP = 30
# The page footer sits at the very bottom of a 945px page: all 300 of them are
# at exactly top=848. The threshold is not merely "low on the page" -- requirement
# numbers on a full page reach top=818, and counting those as footers puts six
# nonsense offsets into the vote.
FOOTER_TOP = 840

KINDS = %w[rank badge award].freeze
KIND_LABEL = { "rank" => "rank", "badge" => "merit badge", "award" => "award" }.freeze

# Divider text that opens each region, in printed order.
REGION_DIVIDERS = { "rank" => "REQUIREMENTS", "badge" => "MERIT BADGES",
                    "award" => "OPPORTUNITIES" }.freeze

# Rank headings are "SCOUT" over "Rank Requirements"; the rank's name is the
# part that is not that boilerplate.
RANK_BOILERPLATE = /\s*Rank Requirements\z/i
MINOR_WORDS = %w[a an and for in of the].freeze

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# Fold the spelling differences between a heading, the Merit Badge Library's
# abbreviated version of it, and whatever the user typed.
#
# "and" goes because the library drops it ("Signs, Signals, Codes" for "Signs,
# Signals, and Codes"). "the" goes because the book alphabetizes without it --
# the Citizenship badges are filed Community, Nation, Society, World, which is
# only in order once "in the" is out of the way. No two entries in the book
# collide once both words are dropped.
IGNORED_WORDS = %w[and the].freeze

def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

def title_case(str)
  str.split.each_with_index.map do |word, idx|
    idx.positive? && MINOR_WORDS.include?(word.downcase) ? word.downcase : word.capitalize
  end.join(" ")
end

# --------------------------------------------------------------------------
# build: extraction

def run_poppler(*cmd)
  out, err, status = Open3.capture3(*cmd)
  die "#{cmd.first} failed: #{err.strip}" unless status.success?
  out
rescue Errno::ENOENT
  die "#{cmd.first} not found (brew install poppler)"
end

def extract_pages
  die "missing #{PDF}" unless File.exist?(PDF)
  # No -layout: this book is single-column, and raw mode follows reading order.
  run_poppler("pdftotext", PDF, "-").split(PAGE_SEP)
end

def elem_text(elem)
  elem.children.map { |c| c.is_a?(REXML::Text) ? c.value : elem_text(c) }.join
end

# Every positioned text fragment in the book, with the size and family of its
# font: [pdf_page, top, left, size, family, string].
def extract_fragments
  xml = run_poppler("pdftohtml", "-xml", "-i", "-stdout", PDF)
  doc = REXML::Document.new(xml)
  # fontspec ids are global; each is declared on the page that first uses it.
  specs = {}
  doc.elements.each("pdf2xml/page/fontspec") do |spec|
    specs[spec.attributes["id"]] = [spec.attributes["size"].to_i, spec.attributes["family"].to_s]
  end

  frags = []
  doc.elements.each("pdf2xml/page") do |page|
    pdf_page = page.attributes["number"].to_i
    page.elements.each("text") do |text|
      size, family = specs[text.attributes["font"]]
      next unless size

      frags << { page: pdf_page, top: text.attributes["top"].to_i,
                 left: text.attributes["left"].to_i, size: size, family: family,
                 str: elem_text(text).strip }
    end
  end
  frags
end

# printed_page + offset == pdf_page, read off the footers themselves.
def measure_page_offset(frags)
  tally = Hash.new(0)
  frags.each do |f|
    next unless f[:top] >= FOOTER_TOP && f[:str].match?(/\A\d{1,3}\z/)

    tally[f[:page] - f[:str].to_i] += 1
  end
  die "no page footers found; cannot map printed pages" if tally.empty?

  offset, count = tally.max_by { |_, n| n }
  warn "warning: page offset varies (#{tally.inspect}); using #{offset}" if count < tally.values.sum
  offset
end

# First page carrying each section divider, e.g. "MERIT BADGES" on PDF page 28.
def find_regions(frags, page_count, library_page)
  starts = REGION_DIVIDERS.transform_values do |label|
    frag = frags.find { |f| f[:size] == DIVIDER_SIZE && f[:str] == label }
    frag && frag[:page]
  end

  last = page_count
  # The Merit Badge Library is back matter, not part of the awards section.
  last = library_page - 1 if library_page
  regions = {}
  KINDS.reverse_each do |kind|
    next unless starts[kind]

    regions[kind] = { first: starts[kind], last: last }
    last = starts[kind] - 1
  end
  regions
end

def kind_for(regions, pdf_page)
  KINDS.find { |k| regions[k] && (regions[k][:first]..regions[k][:last]).cover?(pdf_page) }
end

# Join the fragments of each heading, then name it.
def build_headings(frags, regions, offset)
  headings = group_wrapped(heading_fragments(frags), regions, offset)
  annotate_headings(headings, letter_tabs(frags))
  headings
end

def heading_fragments(frags)
  frags.select do |f|
    f[:size] == HEADING_SIZE && f[:family].match?(HEADING_FAMILY) &&
      f[:left] >= 0 && !f[:str].empty?
  end
end

# The A-Z tabs, by the page each opens.
def letter_tabs(frags)
  frags.select { |f| f[:size] == LETTER_SIZE && f[:str].match?(/\A[A-Z]\z/) }
       .to_h { |f| [f[:page], f[:str]] }
end

def group_wrapped(frags, regions, offset)
  headings = []
  frags.each do |frag|
    prev = headings.last
    if prev && prev[:pdf_page] == frag[:page] && frag[:top] - prev[:bottom] <= WRAP_GAP
      prev[:segments] << frag[:str]
      prev[:bottom] = frag[:top]
      next
    end
    kind = kind_for(regions, frag[:page]) or next # the front matter has headings too

    headings << { kind: kind, pdf_page: frag[:page], printed_page: frag[:page] - offset,
                  bottom: frag[:top], segments: [frag[:str]] }
  end
  headings
end

def annotate_headings(headings, letters)
  letter = nil
  headings.each do |h|
    h[:title] = h[:segments].join(" ").squeeze(" ").strip
    h[:name] = h[:kind] == "rank" ? rank_name(h[:title]) : h[:title]
    letter = letters[h[:pdf_page]] || letter
    h[:letter] = letter if h[:kind] == "badge"
    h.delete(:bottom)
  end
end

# "SCOUT Rank Requirements" -> "Scout"; the two alternative-requirements
# entries have no such suffix and keep their whole heading as the name.
def rank_name(title)
  title_case(title.sub(RANK_BOILERPLATE, ""))
end

# Anchor each heading to a line of the page's text, so a body can be sliced out.
# Headings print their first segment on a line of its own; when a page holds two
# headings, search forward from where the previous one landed.
#
# A footnote marker is set smaller than the heading, so it is a separate XML
# fragment but the same `pdftotext` line: the Den Chief Service Award's heading
# arrives here as "Den Chief Service Award" and reads back as
# "Den Chief Service Award*". Strip the marker before comparing.
FOOTNOTE_MARK = /[*†‡]+\z/

def locate_headings(headings, pages)
  cursor = Hash.new(0)
  headings.each do |h|
    lines = pages[h[:pdf_page] - 1].to_s.split("\n")
    wanted = h[:segments].first
    from = cursor[h[:pdf_page]]
    found = (from...lines.size).find { |i| lines[i].strip.sub(FOOTNOTE_MARK, "") == wanted }
    h[:line] = found || from
    h[:located] = !found.nil?
    cursor[h[:pdf_page]] = h[:line] + 1
  end
end

# --------------------------------------------------------------------------
# build: the Merit Badge Library table (back matter)
#
# Three fixed-width columns of "name .... year", sliced at the offsets of the
# repeated "Merit Badge Pamphlet" column header. A name too long for its column
# wraps, and the year then sits on the indented second line.

LIBRARY_TITLE = "MERIT BADGE LIBRARY"
LIBRARY_HEADER = "Merit Badge Pamphlet"

def find_library_page(pages)
  idx = pages.index { |text| text.include?(LIBRARY_TITLE) }
  idx && (idx + 1)
end

def parse_library(pdf_page)
  return [] unless pdf_page

  lines = run_poppler("pdftotext", "-layout", "-f", pdf_page.to_s, "-l", pdf_page.to_s, PDF, "-")
          .split("\n")
  header = lines.index { |l| l.scan(LIBRARY_HEADER).size >= 2 } or return []

  bounds = column_bounds(lines[header])
  entries = []
  pending = Array.new(bounds.size, nil)
  lines[(header + 1)..].each do |line|
    bounds.each_with_index do |(from, to), col|
      cell = line[from...to].to_s.strip
      next if cell.empty?

      if (m = cell.match(/\A(.+?)\s+(\d{4})\z/))
        entries << { name: [pending[col], m[1]].compact.join(" "), pamphlet_year: m[2].to_i }
        pending[col] = nil
      else
        pending[col] = cell
      end
    end
  end
  entries
end

def column_bounds(header_line)
  starts = []
  offset = 0
  while (idx = header_line.index(LIBRARY_HEADER, offset))
    starts << idx
    offset = idx + 1
  end
  starts.each_with_index.map { |start, i| [start, starts[i + 1]] }
end

# --------------------------------------------------------------------------
# build: the front-matter "THIS PRINTING INCLUDES" list
#
# Which merit badges had requirements changed in this printing, and which
# numbered requirements changed. Three wrapped columns read in order, so both
# names and requirement lists spill onto continuation lines.

UPDATES_START = "Requirement Updates"
UPDATES_ENTRY = /\A(.*?[a-z])\s+(\(.+)\z/
UPDATES_CONT = /\A\(/

def parse_updates(pages)
  page = pages.find { |text| text.include?(UPDATES_START) } or return {}
  lines = page.split("\n").map(&:strip)
  start = lines.index { |l| l.include?(UPDATES_START) } or return {}

  updates = {}
  current = nil
  pending = nil
  lines[(start + 1)..].each do |line|
    break if !updates.empty? && line == BOOK_YEAR.to_s

    if line.empty?
      current = nil
    elsif line.match?(UPDATES_CONT) && current
      updates[current] << " #{line}"
    elsif (m = line.match(UPDATES_ENTRY))
      current = [pending, m[1]].compact.join(" ")
      pending = nil
      updates[current] = m[2].dup
    else
      pending = line
    end
  end
  updates.transform_values { |v| v.squeeze(" ").strip }
end

# --------------------------------------------------------------------------
# build

def build(force: false)
  return if !force && File.exist?(TEXT) && File.exist?(INDEX) && File.mtime(TEXT) >= File.mtime(PDF)

  FileUtils.mkdir_p(CACHE)
  pages = extract_pages
  frags = extract_fragments
  offset = measure_page_offset(frags)
  library_page = find_library_page(pages)
  regions = find_regions(frags, pages.size, library_page)
  headings = build_headings(frags, regions, offset)
  locate_headings(headings, pages)

  library = parse_library(library_page).to_h { |e| [normalize(e[:name]), e[:pamphlet_year]] }
  headings.each { |h| h[:pamphlet_year] = library[normalize(h[:name])] if h[:kind] == "badge" }

  File.write(TEXT, pages.join(PAGE_SEP))
  File.write(INDEX, JSON.pretty_generate(
                      "page_offset" => offset, "page_count" => pages.size,
                      "library_page" => library_page, "regions" => regions,
                      "library" => library, "updates" => parse_updates(pages),
                      "entries" => headings
                    ))
  warn "built cache: #{pages.size} pages, #{headings.size} entries, page offset #{offset}"
end

def load_book
  build
  pages = File.read(TEXT).split(PAGE_SEP)
  data = JSON.parse(File.read(INDEX), symbolize_names: true)
  [pages, data]
end

def load_beyond
  return { badges: [] } unless File.exist?(BEYOND)

  JSON.parse(File.read(BEYOND), symbolize_names: true)
rescue JSON::ParserError => e
  die "#{BEYOND} is not valid JSON: #{e.message}"
end

# --------------------------------------------------------------------------
# the loud part
#
# The one thing this skill must never do quietly is answer a question about a
# merit badge the 2025 book does not carry. A Scout working a 2026 badge from
# 2025 text is being told to do the wrong work, and the failure is invisible --
# the answer looks exactly like a correct one. So it gets a banner, an explicit
# instruction, and its own exit status.

BANNER_WIDTH = 78

def banner(title, lines)
  puts "#" * BANNER_WIDTH
  puts "###{' ' * (BANNER_WIDTH - 4)}##"
  puts "##  #{title.center(BANNER_WIDTH - 8)}  ##"
  puts "###{' ' * (BANNER_WIDTH - 4)}##"
  puts "#" * BANNER_WIDTH
  puts
  lines.each { |line| puts line.to_s.empty? ? "" : "  #{line}" }
  puts
end

def beyond_entry(beyond, query)
  target = normalize(query)
  Array(beyond[:badges]).find do |b|
    normalize(b[:name]) == target || normalize(b[:renamed_from]) == target
  end
end

def describe_beyond(entry)
  bits = ["status: #{entry[:status] || 'unknown'}"]
  bits << "effective #{entry[:effective]}" if entry[:effective]
  bits << "renamed from \"#{entry[:renamed_from]}\"" if entry[:renamed_from]
  lines = ["#{entry[:name]} -- #{bits.join(', ')}"]
  lines << entry[:note] if entry[:note]
  lines << "Source: #{entry[:source]}" if entry[:source]
  lines
end

FETCH_INSTRUCTION = [
  "DO NOT answer from memory and DO NOT substitute the 2025 text.",
  "Tell the Advancement Chair plainly that this skill cannot supply these",
  "requirements, and get them from www.scouting.org/meritbadges before any",
  "Scout is asked to work on them."
].freeze

def announce_unknown(query, suggestions, beyond_entry)
  if beyond_entry
    banner("#{beyond_entry[:effective] || 'POST-2025'} MERIT BADGE -- NOT IN THE #{BOOK_YEAR} BOOK",
           describe_beyond(beyond_entry) + [""] + FETCH_INSTRUCTION)
    return
  end

  lines = [
    "\"#{query}\" is not a rank, merit badge, or award in #{BOOK_LABEL}.",
    "",
    "It is either introduced or renamed after this book (2026 or later), or",
    "it is misspelled. Check the spelling first; if it is right, treat it as a",
    "post-#{BOOK_YEAR} requirement."
  ]
  lines += ["", "Closest names in the book: #{suggestions.join(', ')}"] unless suggestions.empty?
  banner("NOT IN THE #{BOOK_YEAR} REQUIREMENTS BOOK", lines + [""] + FETCH_INSTRUCTION)
end

def announce_superseded(entry, beyond)
  banner("SUPERSEDED -- REVISED AFTER #{BOOK_YEAR}",
         describe_beyond(beyond) + [
           "",
           "The #{BOOK_YEAR} text below is printed for reference only. Do not plan a",
           "Scout's work from it without checking www.scouting.org/meritbadges.",
           "(#{entry[:name]}, printed p.#{entry[:printed_page]})"
         ])
end

# --------------------------------------------------------------------------
# lookup

def entries_of(data, kind: nil)
  kind ? data[:entries].select { |e| e[:kind] == kind } : data[:entries]
end

def resolve(data, query, kind: nil)
  pool = entries_of(data, kind: kind)
  target = normalize(query)
  exact = pool.select { |e| normalize(e[:name]) == target }
  return exact unless exact.empty?

  pool.select { |e| normalize(e[:name]).include?(target) }
end

def suggest(data, query)
  names = data[:entries].map { |e| e[:name] }
  hits = DidYouMean::SpellChecker.new(dictionary: names).correct(query)
  hits.empty? ? names.select { |n| normalize(n).split.first == normalize(query).split.first } : hits
end

# Where an entry's text ends: at the next heading, or at the end of its section.
def body_extent(data, index)
  entry = data[:entries][index]
  region_last = data[:regions][entry[:kind].to_sym][:last]
  nxt = data[:entries][index + 1]
  if nxt && nxt[:pdf_page] <= region_last
    [nxt[:pdf_page], nxt[:line]]
  else
    [region_last, Float::INFINITY]
  end
end

# One page of body text: footer number dropped, and the A-Z tab dropped with it.
def page_body(pages, pdf_page, printed_page, from, to)
  lines = pages[pdf_page - 1].to_s.split("\n")
  upper = [to, lines.size - 1].min
  return [] if upper < from

  lines[from..upper].reject { |l| l.strip == printed_page.to_s || l.strip.match?(/\A[A-Z]\z/) }
end

def print_entry(pages, data, index)
  entry = data[:entries][index]
  print_entry_header(entry, data)
  print_entry_body(pages, data, index)
  puts "Source: #{BOOK_LABEL}, effective Jan. 1, #{BOOK_YEAR} " \
       "(docs/#{File.basename(PDF)}), printed p.#{entry[:printed_page]}."
end

def print_entry_header(entry, data)
  puts "=== #{entry[:title]} — #{KIND_LABEL[entry[:kind]]} — " \
       "printed p.#{entry[:printed_page]} / PDF p.#{entry[:pdf_page]}"
  if entry[:pamphlet_year]
    puts "    Merit Badge Library: pamphlet requirements dated #{entry[:pamphlet_year]}"
  end
  if (changed = data[:updates][entry[:name].to_sym])
    puts "    Changed in the #{BOOK_YEAR} printing: requirements #{changed}"
  end
  puts
end

def print_entry_body(pages, data, index)
  entry = data[:entries][index]
  offset = data[:page_offset]
  end_page, end_line = body_extent(data, index)

  (entry[:pdf_page]..end_page).each do |pdf_page|
    from = pdf_page == entry[:pdf_page] ? entry[:line] : 0
    to = pdf_page == end_page ? end_line - 1 : Float::INFINITY
    body = page_body(pages, pdf_page, pdf_page - offset, from, to)
    next if body.join.strip.empty?

    puts "--- printed p.#{pdf_page - offset} ---"
    puts body.join("\n").sub(/\n+\z/, "")
    puts
  end
end

# --------------------------------------------------------------------------
# commands

def parse_kind(value)
  kind = value.to_s.downcase.sub(/\Amerit ?badges?\z/, "badge").sub(/s\z/, "")
  KINDS.include?(kind) ? kind : die("unknown kind #{value.inspect} (#{KINDS.join(', ')})")
end

def cmd_show(argv)
  kind = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: req.rb show NAME [--kind rank|badge|award]"
    o.on("--kind K", "restrict to one kind of entry") { |v| kind = parse_kind(v) }
  end
  parser.parse!(argv)
  query = argv.join(" ").strip
  die parser.banner if query.empty?

  pages, data = load_book
  beyond = beyond_entry(load_beyond, query)
  matches = resolve(data, query, kind: kind)

  if matches.empty?
    announce_unknown(query, suggest(data, query), beyond)
    exit NEED_NEWER
  end

  if matches.size > 1
    puts "\"#{query}\" matches #{matches.size} entries; name one exactly or pass --kind:"
    matches.each do |e|
      puts "  #{e[:name]}  (#{KIND_LABEL[e[:kind]]}, printed p.#{e[:printed_page]})"
    end
    exit 1
  end

  entry = matches.first
  announce_superseded(entry, beyond) if beyond
  print_entry(pages, data, data[:entries].index(entry))
  exit NEED_NEWER if beyond
end

def cmd_list(argv)
  kind = nil
  letter = nil
  year = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: req.rb list [--kind K] [--letter A] [--pamphlet-year YYYY]"
    o.on("--kind K", "rank, badge, or award") { |v| kind = parse_kind(v) }
    o.on("--letter A", "merit badges under one alphabet tab") { |v| letter = v.upcase }
    o.on("--pamphlet-year N", Integer, "badges whose pamphlet requirements are dated N") do |v|
      year = v
    end
  end
  parser.parse!(argv)

  _, data = load_book
  rows = entries_of(data, kind: kind)
  rows = rows.select { |e| e[:letter] == letter } if letter
  rows = rows.select { |e| e[:pamphlet_year] == year } if year
  print_list(rows)
end

def print_list(rows)
  rows.each do |entry|
    suffix = entry[:pamphlet_year] ? "  [pamphlet #{entry[:pamphlet_year]}]" : ""
    puts format("%-11s p.%-4d %s%s", KIND_LABEL[entry[:kind]], entry[:printed_page],
                entry[:name], suffix)
  end
  counts = rows.group_by { |e| e[:kind] }.transform_values(&:size)
  puts "\n(#{rows.size} entries: #{counts.map { |k, n| "#{n} #{KIND_LABEL[k]}" }.join(', ')})"
end

def cmd_search(argv)
  kind = nil
  context = 2
  max = 25
  parser = OptionParser.new do |o|
    o.banner = "usage: req.rb search PATTERN [--kind K] [--context N] [--max N]"
    o.on("--kind K", "restrict to one kind of entry") { |v| kind = parse_kind(v) }
    o.on("--context N", Integer, "lines around each hit (default 2)") { |v| context = v }
    o.on("--max N", Integer, "max matches to print (default 25)") { |v| max = v }
  end
  parser.parse!(argv)
  source = argv.shift or die parser.banner

  begin
    pattern = Regexp.new(source, Regexp::IGNORECASE)
  rescue RegexpError => e
    die "bad regex: #{e.message}"
  end

  pages, data = load_book
  shown = search_pages(pages, data, pattern, kind: kind, context: context, max: max)
  puts shown.zero? ? "no matches" : "\n(#{shown} matches)"
end

def search_pages(pages, data, pattern, kind:, context:, max:)
  offset = data[:page_offset]
  shown = 0
  data[:entries].each_with_index do |entry, index|
    next if kind && entry[:kind] != kind

    end_page, end_line = body_extent(data, index)
    (entry[:pdf_page]..end_page).each do |pdf_page|
      from = pdf_page == entry[:pdf_page] ? entry[:line] : 0
      to = pdf_page == end_page ? end_line - 1 : Float::INFINITY
      lines = page_body(pages, pdf_page, pdf_page - offset, from, to)
      lines.each_with_index do |line, i|
        next unless pattern.match?(line)
        return shown if shown >= max

        shown += 1
        puts "\n=== #{entry[:name]} (#{KIND_LABEL[entry[:kind]]}), printed p.#{pdf_page - offset}"
        lo = [0, i - context].max
        hi = [lines.size - 1, i + context].min
        (lo..hi).each { |j| puts " #{j == i ? '>' : ' '} #{lines[j]}" }
      end
    end
  end
  shown
end

def cmd_page(argv)
  last = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: req.rb page PRINTED_PAGE [--to PRINTED_PAGE]"
    o.on("--to N", Integer, "print through this printed page") { |v| last = v }
  end
  parser.parse!(argv)
  first = Integer(argv.shift.to_s, exception: false) or die parser.banner
  last ||= first

  pages, data = load_book
  offset = data[:page_offset]
  (first..last).each do |printed|
    pdf_page = printed + offset
    unless (1..pages.size).cover?(pdf_page)
      die "printed page #{printed} out of range (#{1 - offset}..#{pages.size - offset})"
    end

    opens = data[:entries].select { |e| e[:pdf_page] == pdf_page }.map { |e| e[:name] }
    header = "=== printed p.#{printed} / PDF p.#{pdf_page}"
    header += " — begins here: #{opens.join(', ')}" unless opens.empty?
    puts header
    puts pages[pdf_page - 1].sub(/\A\n+/, "").sub(/\n+\z/, "")
    puts
  end
end

def cmd_updates(argv)
  _, data = load_book
  query = argv.join(" ").strip
  updates = data[:updates]

  if query.empty?
    puts "Merit badges whose requirements changed in the #{BOOK_YEAR} printing:\n\n"
    updates.each { |name, reqs| puts format("  %-30s %s", name, reqs) }
    puts "\n(#{updates.size} badges)"
    return
  end

  match = updates.keys.find { |name| normalize(name) == normalize(query) }
  if match
    puts "#{match}: requirements #{updates[match]} changed in the #{BOOK_YEAR} printing."
  else
    puts "#{query}: no requirement changes listed in the #{BOOK_YEAR} printing."
  end
end

# --------------------------------------------------------------------------
# verify
#
# Never report requirements from a parse that fails this. A dropped or invented
# heading does not produce an obvious error -- it produces a neighbouring
# badge's requirements under the wrong name, which reads as perfectly plausible.

EXPECTED_RANKS = ["Scout", "Tenderfoot", "Second Class", "First Class",
                  "Scout, Tenderfoot, Second Class, and First Class Ranks Alternative Requirements",
                  "Star", "Life", "Eagle", "Eagle Scout Rank Alternative Requirements"].freeze

def cmd_verify(_argv)
  _, data = load_book
  problems = []
  problems.concat(verify_structure(data))
  problems.concat(verify_ranks(data))
  problems.concat(verify_library(data))
  problems.concat(verify_alphabet(data))
  problems.concat(verify_updates(data))

  if problems.empty?
    counts = data[:entries].group_by { |e| e[:kind] }.transform_values(&:size)
    puts "PASS — #{data[:page_count]} pages, page offset #{data[:page_offset]}, " \
         "#{KINDS.map { |k| "#{counts[k].to_i} #{KIND_LABEL[k]}s" }.join(', ')}, " \
         "#{data[:library].size} in the Merit Badge Library."
    return
  end

  puts "FAIL — #{problems.size} problem(s):"
  problems.each { |p| puts "  - #{p}" }
  exit 1
end

def verify_structure(data)
  problems = []
  KINDS.each { |k| problems << "no #{k} section divider found" unless data[:regions][k.to_sym] }
  bounds = KINDS.filter_map { |k| data[:regions][k.to_sym] }
  unless bounds.each_cons(2).all? { |a, b| a[:last] < b[:first] }
    problems << "section dividers are out of order: #{bounds.inspect}"
  end
  problems << "no Merit Badge Library page found" unless data[:library_page]
  data[:entries].reject { |e| e[:located] }.each do |entry|
    problems << "#{entry[:name]}: heading not found in the text of PDF p.#{entry[:pdf_page]}"
  end
  problems
end

def verify_ranks(data)
  found = entries_of(data, kind: "rank").map { |e| e[:name] }
  return [] if found == EXPECTED_RANKS

  ["rank entries are #{found.inspect}, expected #{EXPECTED_RANKS.inspect}"]
end

# The only independent list of merit badges this book contains.
def verify_library(data)
  badges = entries_of(data, kind: "badge")
  indexed = badges.to_h { |e| [normalize(e[:name]), e[:name]] }
  library = data[:library].transform_keys(&:to_s)

  missing = library.keys - indexed.keys
  extra = indexed.keys - library.keys
  problems = []
  unless missing.empty?
    problems << "in the Merit Badge Library but not indexed: #{missing.join(', ')}"
  end
  problems << "indexed but not in the Merit Badge Library: #{extra.join(', ')}" unless extra.empty?
  no_year = badges.reject { |e| e[:pamphlet_year] }.map { |e| e[:name] }
  problems << "no pamphlet year: #{no_year.join(', ')}" unless no_year.empty?
  problems
end

# Merit badges run alphabetically under A-Z tabs; a heading that is out of order
# or under the wrong tab is a heading the font rule got wrong.
def verify_alphabet(data)
  badges = entries_of(data, kind: "badge")
  problems = []
  badges.each_cons(2) do |a, b|
    next unless normalize(a[:name]) > normalize(b[:name])

    problems << "out of alphabetical order: #{a[:name]} then #{b[:name]}"
  end
  badges.each do |entry|
    next if entry[:letter] && entry[:name].start_with?(entry[:letter])

    problems << "#{entry[:name]} filed under the #{entry[:letter].inspect} tab"
  end
  problems
end

def verify_updates(data)
  known = data[:entries].map { |e| normalize(e[:name]) }
  unknown = data[:updates].keys.map(&:to_s).reject { |name| known.include?(normalize(name)) }
  return [] if unknown.empty?

  ["\"THIS PRINTING INCLUDES\" names no entry matches: #{unknown.join(', ')}"]
end

def cmd_build(argv)
  force = false
  OptionParser.new do |o|
    o.banner = "usage: req.rb build [--force]"
    o.on("--force", "rebuild even if the cache is current") { force = true }
  end.parse!(argv)
  build(force: force)
end

USAGE = <<~TEXT.freeze
  usage: req.rb COMMAND [options]

    show NAME [--kind K]                  print one rank, merit badge, or award
    list [--kind K] [--letter A]          list entries (--pamphlet-year YYYY too)
    search PATTERN [--kind K]             regex search of requirement text
    page PRINTED_PAGE [--to N]            print printed page(s)
    updates [NAME]                        what changed in the #{BOOK_YEAR} printing
    verify                                check the parse — run this first
    build [--force]                       (re)build the cache

  Exit 3 means the answer needs requirements this #{BOOK_YEAR} book does not carry.
TEXT

argv = ARGV.dup
case argv.shift
when "show" then cmd_show(argv)
when "list" then cmd_list(argv)
when "search" then cmd_search(argv)
when "page" then cmd_page(argv)
when "updates" then cmd_updates(argv)
when "verify" then cmd_verify(argv)
when "build" then cmd_build(argv)
else die USAGE
end
