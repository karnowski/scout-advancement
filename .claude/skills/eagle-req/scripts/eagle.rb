#!/usr/bin/env ruby
# frozen_string_literal: true

#
# eagle-req -- read the Eagle Scout Service Project Workbook (No. 512-927,
# revision 2023a) out of references/EagleProjectWorkbook2023a.pdf.
#
#   ruby scripts/eagle.rb search PATTERN [--context N] [--max N] [--part NAME]
#   ruby scripts/eagle.rb page LABEL [--to LABEL]
#   ruby scripts/eagle.rb part NAME
#   ruby scripts/eagle.rb toc
#   ruby scripts/eagle.rb verify
#   ruby scripts/eagle.rb build [--force]
#
# Needs no poppler: pdf-reader is pure Ruby, and this file has to be decoded by
# hand anyway (below).
#
# ---------------------------------------------------------------------------
# THE TEXT LAYER IS BROKEN. READ THIS BEFORE TOUCHING THE DECODER.
#
# Every off-the-shelf extractor gets this PDF wrong, and gets it wrong
# *quietly*. `pdftotext`, `pdftohtml`, and pdf-reader's own decoding all turn
# Eagle Scout requirement 5 --
#
#   "While a Life Scout, plan, develop, and give leadership to others in a
#    service project helpful to any religious institution, any school, ..."
#
# -- into this:
#
#   "W ile a  i e Scout   la   evelo  a   give lea er  i to ot er i a
#    ervice roject el ul to a    religiou i titutio a    c ool ..."
#
# Letters do not become garbage; they become *nothing*, so the output still
# looks like prose and still quotes cleanly. Nothing downstream can catch it.
#
# Why: the workbook embeds eleven Identity-H (CID-keyed) Arial subsets, and
# eight of them carry a ToUnicode CMap covering only some of the glyph IDs they
# actually use. An unmapped CID is dropped. The damage lands hardest on italic
# and heading text, which in this workbook is where the requirement itself, the
# boxed warnings, and most section titles live.
#
# The repair: every Arial subset here numbers its glyphs in the standard
# Macintosh ordering (what TrueType `post` format 1.0 defines), where
#
#     CID = ASCII code - 29
#
# -- CID 3 = space, 17 = ".", 36 = "A", 68 = "a", 93 = "z". That is measured,
# not assumed. The eleven CMaps between them map 65 distinct CIDs; every one
# obeys the rule and no two fonts disagree about any CID. Five CIDs above the
# ASCII block are used, and four of those are mapped by at least one font, so
# the union of the CMaps covers them; the fifth is the ellipsis, read off the
# page (see RepairedCMap::HIGH). `verify` re-derives all of this from the PDF
# on demand and fails if it ever stops holding.
#
# The rule is applied ONLY to Type0 fonts whose BaseFont contains "Arial":
#
#   - The Symbol CID font in this file uses a different glyph order (its CID
#     118 is a bullet, where the Arial order would make it an accented i).
#   - The simple WinAnsi TrueType fonts are byte-encoded, not CID-keyed, and
#     already decode correctly; offsetting them would rewrite good letters.
#
# Both mistakes would replace *missing* letters with *wrong* ones, which is the
# one outcome worse than the bug being fixed here.
#
# Two smaller facts about this file:
#
#   - It is encrypted (the 2023a revision's "Repaired Security Settings"), and
#     at least one object fails AES decryption. `ObjectHash#each` therefore
#     raises partway through; font objects are fetched one at a time instead.
#     Page content is unaffected.
#   - Side-by-side boxes (the four approval blocks on Proposal Page H, the
#     approval row on Fundraising Application Page A) come out interleaved line
#     by line, because they are laid out as table cells. The text is all there
#     and the interleaving is obvious rather than silent, but read the page
#     image before quoting those blocks.
#
# ---------------------------------------------------------------------------

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "fileutils"
require "json"
require "optparse"
require "pdf-reader"

PDF_PATH = File.join(REPO_ROOT, "references", "EagleProjectWorkbook2023a.pdf")
CACHE = File.join(SKILL_DIR, ".cache")
PAGES_JSON = File.join(CACHE, "pages.json")

# The 2023a printing. A different page count means a different revision, and
# every page label and extraction fact below was checked against this one.
EXPECTED_PAGES = 32

# CID 3 is the space glyph and ASCII space is 32.
ASCII_CID_OFFSET = 29
ASCII_CIDS = (3..96)

# The workbook restarts its page numbering in every part and cites itself by
# those labels -- "page B of the fundraising application", "page 3 of this
# workbook" -- so the labels are the citation scheme, not the PDF page numbers.
#
# A label in parentheses is one the page does not actually print at its foot;
# `verify` checks every unparenthesized one against the page itself.
PAGE_SPEC = [
  ["front", ["(Cover)", "Page 2", "Page 3", "Page 4", "(Page 5)", "(blank)"]],
  ["proposal", ["(Proposal Cover)"] + ("A".."H").map { |l| "Proposal Page #{l}" }],
  ["plan", ["(Project Plan Cover)"] + ("A".."F").map { |l| "Project Plan Page #{l}" }],
  ["fundraising", ["Fundraising Application Page A", "Fundraising Application Page B", "(blank)"]],
  ["report", ["(Project Report Cover)"] + ("A".."C").map { |l| "Project Report Page #{l}" }],
  ["navigating", ["(Navigating Page 1)", "(Navigating Page 2)"]],
  ["revisions", ["(Revision Tracking)"]]
].freeze

PART_TITLES = {
  "front" => "Front matter",
  "proposal" => "Eagle Scout Service Project Proposal",
  "plan" => "Eagle Scout Service Project Plan",
  "fundraising" => "Eagle Scout Service Project Fundraising Application",
  "report" => "Eagle Scout Service Project Report",
  "navigating" => "Navigating the Eagle Scout Service Project",
  "revisions" => "Revision tracking"
}.freeze

# One passage from every part that carries prose. Each is mangled without the
# repair -- they sit in the italic and heading subsets whose CMaps are the most
# incomplete -- so if the decoder regresses these break first. Deliberately
# none of them crosses a side-by-side box, where the columns interleave.
CANARIES = [
  "Only the Official Workbook May Be Used",                             # Page 2
  "While a Life Scout, plan, develop, and give leadership to others",   # Page 3
  "Eagle Scout Service Project Workbook, No. 512-927",                  # Page 2
  "What Is Meant by “Give Leadership to Others …?”",                    # Page 5
  "Materials are things that become part of the finished project",      # Proposal Page D
  "On my honor as a Scout, I have read this entire workbook",           # Proposal Page H
  "Note that property owners should obtain and pay for permits",        # Proposal Page E
  "Procedures and Limitations on Eagle Scout",                          # Fundraising Page B
  "There is no requirement for a minimum number of hours",              # Project Report Page B
  "Coaches must be registered with the BSA"                             # Page 5
].freeze

# The signature of the damage: "W ile a  i e Scout" leaves runs of stranded
# single letters that ordinary English prose never produces.
DAMAGE_RE = /(?:\b[a-zA-Z]\b[ \t]+){3,}/

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# --------------------------------------------------------------------------
# page labels

# [[pdf_page, part, label, printed_footer_or_nil], ...]
def page_table
  page = 0
  PAGE_SPEC.flat_map do |part, labels|
    labels.map do |label|
      page += 1
      bare = label.delete_prefix("(").delete_suffix(")")
      [page, part, bare, label.start_with?("(") ? nil : bare]
    end
  end
end

# --------------------------------------------------------------------------
# decoding

# Fills the holes in a font's ToUnicode CMap. `decode` is the only method
# pdf-reader calls on a CMap (Font#to_utf8_via_cmap), so wrapping it is enough.
class RepairedCMap
  # CIDs above the ASCII block, where the offset rule does not reach. All but
  # one are read off other Arial CMaps in this same file, which is why `verify`
  # can check them: 178 em dash, 179/180 curly double quotes, 182 right single
  # quote. CID 171 is the exception -- no CMap here maps it, so it was read off
  # the page: it is the ellipsis in Page 5's heading, "Give Leadership to
  # Others …?", and it occurs exactly once in the workbook.
  #
  # Note what is *not* here: the bullet. It is CID 118 in this file's Symbol
  # font, but 118 in the Arial order is an accented i, and this table is only
  # ever consulted for Arial. Adding it would corrupt Arial text.
  HIGH = { 171 => 0x2026, 178 => 0x2014,
           179 => 0x201C, 180 => 0x201D, 182 => 0x2019 }.freeze

  @unresolved = Hash.new(0)
  @enabled = true

  class << self
    attr_reader :unresolved
    attr_accessor :enabled
  end

  def initialize(inner)
    @inner = inner
  end

  def decode(cid)
    mapped = @inner ? Array(@inner.decode(cid)) : []
    return mapped unless mapped.empty?
    return [] unless RepairedCMap.enabled
    return [cid + ASCII_CID_OFFSET] if ASCII_CIDS.cover?(cid)
    return [HIGH[cid]] if HIGH.key?(cid)

    RepairedCMap.unresolved[cid] += 1
    []
  end
end

# pdf-reader builds its Font objects deep inside PageState, so this is the only
# seam available. Scoped as tightly as the defect: Type0 Arial subsets only.
module RepairArialCMaps
  def initialize(ohash, obj)
    super
    return unless subtype == :Type0 && basefont.to_s.include?("Arial")

    self.tounicode = RepairedCMap.new(tounicode)
  end
end
PDF::Reader::Font.prepend(RepairArialCMaps)

def extract_pages
  die "missing #{PDF_PATH}" unless File.exist?(PDF_PATH)
  reader = PDF::Reader.new(PDF_PATH)
  reader.pages.map { |page| page.text.rstrip }
rescue PDF::Reader::MalformedPDFError => e
  die "could not read #{PDF_PATH}: #{e.message}"
end

# --------------------------------------------------------------------------
# build / load

def build(force: false)
  return if !force && File.exist?(PAGES_JSON) && File.mtime(PAGES_JSON) >= File.mtime(PDF_PATH)

  texts = extract_pages
  unless texts.size == EXPECTED_PAGES
    die "expected #{EXPECTED_PAGES} pages (the 2023a printing), got #{texts.size} -- " \
        "this is a different revision; re-check the page labels and run verify"
  end

  pages = page_table.map do |pdf_page, part, label, footer|
    { "pdf_page" => pdf_page, "part" => part, "label" => label,
      "footer" => footer, "text" => texts[pdf_page - 1] }
  end
  FileUtils.mkdir_p(CACHE)
  File.write(PAGES_JSON, JSON.pretty_generate("pages" => pages))
  warn "built cache: #{pages.size} pages"
end

def load_pages
  build
  JSON.parse(File.read(PAGES_JSON))["pages"]
end

def cite(page)
  "#{page['label']} [#{page['part']} · PDF p.#{page['pdf_page']}]"
end

# --------------------------------------------------------------------------
# resolving a page argument

def normalize_label(str)
  str.downcase.gsub(/[^a-z0-9]/, "")
end

# Accepts the printed label, the label with "Page" left out, a unique fragment
# of it, or a bare PDF page number.
def resolve_page(token, pages)
  if /\A\d+\z/.match?(token)
    page = pages.find { |p| p["pdf_page"] == token.to_i }
    return page if page

    die "PDF page #{token} out of range (1..#{pages.size})"
  end

  want = normalize_label(token)
  exact = pages.find { |p| normalize_label(p["label"]) == want }
  return exact if exact

  loose = pages.find { |p| normalize_label(p["label"].sub(" Page ", " ")) == want }
  return loose if loose

  partial = pages.select { |p| normalize_label(p["label"]).include?(want) }
  return partial.first if partial.size == 1

  near = partial.empty? ? pages : partial
  die "no single page matches #{token.inspect}. Pages: #{near.map { |p| p['label'] }.join(', ')}"
end

# --------------------------------------------------------------------------
# commands

def cmd_search(argv)
  context = 2
  max = 25
  part = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: eagle.rb search PATTERN [--context N] [--max N] [--part NAME]"
    o.on("--context N", Integer, "lines around each hit (default 2)") { |v| context = v }
    o.on("--max N", Integer, "max matches to print (default 25)") { |v| max = v }
    o.on("--part NAME", "restrict to one part (#{PART_TITLES.keys.join(', ')})") { |v| part = v }
  end
  parser.parse!(argv)
  source = argv.shift or die parser.banner

  begin
    pattern = Regexp.new(source, Regexp::IGNORECASE)
  rescue RegexpError => e
    die "bad regex: #{e.message}"
  end
  if part && !PART_TITLES.key?(part)
    die "unknown part #{part.inspect} (#{PART_TITLES.keys.join(', ')})"
  end

  shown = 0
  load_pages.each do |page|
    next if part && page["part"] != part

    lines = page["text"].split("\n")
    lines.each_with_index do |line, idx|
      next unless pattern.match?(line)

      if shown >= max
        puts "\n... stopped at #{max} matches; narrow the pattern or raise --max"
        return # rubocop:disable Lint/NonLocalExitFromIterator -- stops both loops
      end
      shown += 1
      puts "\n=== #{cite(page)}"
      lo = [0, idx - context].max
      hi = [lines.size - 1, idx + context].min
      (lo..hi).each { |j| puts " #{j == idx ? '>' : ' '} #{lines[j]}" }
    end
  end

  puts shown.zero? ? "no matches" : "\n(#{shown} matches)"
end

def cmd_page(argv)
  last = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: eagle.rb page LABEL [--to LABEL]  " \
               "(e.g. \"Proposal Page D\", \"Page 3\", 11)"
    o.on("--to LABEL", "print through this page as well") { |v| last = v }
  end
  parser.parse!(argv)
  first = argv.shift or die parser.banner

  pages = load_pages
  from = resolve_page(first, pages)
  to = last ? resolve_page(last, pages) : from
  die "#{to['label']} comes before #{from['label']}" if to["pdf_page"] < from["pdf_page"]

  (from["pdf_page"]..to["pdf_page"]).each do |num|
    page = pages[num - 1]
    puts "=== #{cite(page)}"
    puts page["text"].empty? ? "(no text)" : page["text"]
    puts
  end
end

def cmd_part(argv)
  name = argv.shift or die "usage: eagle.rb part NAME   (#{PART_TITLES.keys.join(', ')})"
  die "unknown part #{name.inspect} (#{PART_TITLES.keys.join(', ')})" unless PART_TITLES.key?(name)

  puts "=== #{PART_TITLES[name]}\n\n"
  load_pages.select { |p| p["part"] == name }.each do |page|
    puts "--- #{cite(page)}"
    puts page["text"].empty? ? "(no text)" : page["text"]
    puts
  end
end

def cmd_toc(_argv)
  current = nil
  load_pages.each do |page|
    if page["part"] != current
      current = page["part"]
      puts "\n#{current} — #{PART_TITLES[current]}"
    end
    heading = page["text"].split("\n").map(&:strip).find { |l| !l.empty? }.to_s
    heading = "#{heading[0, 58]}…" if heading.length > 58
    printf("  p.%-3d %-32s %s\n", page["pdf_page"], page["label"], heading)
  end
end

# --------------------------------------------------------------------------
# verify

# Read every Type0 font's ToUnicode CMap. Objects are fetched one at a time
# because ObjectHash#each raises on this file (see the header note on
# encryption), which would take the whole cross-check down with it.
def collect_cid_maps
  ohash = PDF::Reader::ObjectHash.new(PDF_PATH)
  maps = {}
  # The trailer's /Size is one past the highest object number in the file.
  (1...ohash.trailer[:Size].to_i).each do |num|
    obj = begin
      ohash[PDF::Reader::Reference.new(num, 0)]
    rescue StandardError
      nil
    end
    next unless obj.is_a?(Hash) && obj[:Type] == :Font && obj[:Subtype] == :Type0
    next unless obj[:BaseFont].to_s.include?("Arial")

    stream = begin
      ohash.deref(obj[:ToUnicode])
    rescue StandardError
      nil
    end
    next unless stream

    maps[obj[:BaseFont].to_s] ||= parse_cmap(stream.unfiltered_data)
  end
  maps
end

def parse_cmap(src)
  map = {}
  src.scan(/beginbfchar(.*?)endbfchar/m) do |(body)|
    body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |cid, uni|
      map[cid.to_i(16)] = [uni].pack("H*").unpack("n*").pack("U*")
    end
  end
  src.scan(/beginbfrange(.*?)endbfrange/m) do |(body)|
    body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |lo, hi, uni|
      base = [uni].pack("H*").unpack1("n")
      (lo.to_i(16)..hi.to_i(16)).each_with_index { |cid, i| map[cid] = [base + i].pack("U") }
    end
  end
  map
end

def check_glyph_order(results)
  maps = collect_cid_maps
  entries = 0
  broken = []
  union = {}
  maps.each_value do |map|
    map.each do |cid, char|
      entries += 1
      broken << [cid, char] if ASCII_CIDS.cover?(cid) && char != (cid + ASCII_CID_OFFSET).chr
      broken << [cid, char] if union.key?(cid) && union[cid] != char
      union[cid] = char
    end
  end
  results << if maps.empty?
               # Otherwise "0 mappings, all consistent" would read as a pass.
               [false, "glyph order: found no Arial CID font to check the rule against — " \
                       "the CMaps could not be read, so the repair is unverified"]
             elsif broken.empty?
               [true, "glyph order: #{entries} CID→character mappings across #{maps.size} Arial " \
                      "CID fonts (#{union.size} distinct CIDs), all obey " \
                      "CID = ASCII−#{ASCII_CID_OFFSET}, none disagree"]
             else
               [false, "glyph order: #{broken.size} mapping(s) contradict CID = " \
                       "ASCII−#{ASCII_CID_OFFSET} — the repair is unsafe: " \
                       "#{broken.first(6).inspect}"]
             end
  union
end

def check_unresolved(results)
  left = RepairedCMap.unresolved
  results << if left.empty?
               [true, "every CID used in the document resolves to a character"]
             else
               [false, "#{left.size} CID(s) still unresolved and dropped: #{left.inspect} — " \
                       "add them to RepairedCMap::HIGH once identified from the page image"]
             end
end

def check_footers(results, pages)
  expected = pages.reject { |p| p["footer"].nil? }
  wrong = expected.reject { |p| p["text"].split("\n").map(&:strip).include?(p["footer"]) }
  results << if wrong.empty?
               [true, "#{expected.size} printed page footers match the expected labels"]
             else
               [false, "#{wrong.size} page(s) do not print the label this script assigns them: " \
                       "#{wrong.map { |p| "PDF p.#{p['pdf_page']} wants #{p['footer'].inspect}" }
                            .join('; ')}"]
             end
end

def check_canaries(results, whole)
  missing = CANARIES.reject { |phrase| whole.include?(phrase) }
  results << if missing.empty?
               [true, "#{CANARIES.size} canary passages intact"]
             else
               [false, "#{missing.size} canary passage(s) missing — the decoder has regressed: " \
                       "#{missing.map(&:inspect).join('; ')}"]
             end
end

# Extract once more with the repair switched off, so the check reports what the
# repair is actually worth rather than only that nothing is wrong now.
def check_damage(results, whole)
  repaired = whole.scan(DAMAGE_RE).size
  RepairedCMap.enabled = false
  raw = extract_pages.join("\n").scan(DAMAGE_RE).size
  RepairedCMap.enabled = true

  results << if repaired.zero? && raw.positive?
               [true, "no dropped-glyph signature left (#{raw} runs of stranded single letters " \
                      "with the repair off, #{repaired} with it on)"]
             elsif raw.zero?
               [false, "the raw text layer shows no damage (#{raw} runs) — either this is a " \
                       "different, unbroken printing or the repair is not being bypassed"]
             else
               [false, "#{repaired} run(s) of stranded single letters remain after repair " \
                       "(#{raw} before) — letters are still being dropped"]
             end
end

def cmd_verify(_argv)
  pages = load_pages
  whole = pages.map { |p| p["text"] }.join("\n")
  results = []

  results << [pages.size == EXPECTED_PAGES,
              "#{pages.size} pages, as the 2023a printing has"]
  check_glyph_order(results)
  extract_pages # re-decode so unresolved CIDs are counted against this run, not the cache
  check_unresolved(results)
  check_footers(results, pages)
  check_canaries(results, whole)
  check_damage(results, whole)

  puts "eagle.rb verify — Eagle Scout Service Project Workbook No. 512-927, revision 2023a\n\n"
  results.each { |ok, msg| puts "  #{ok ? 'ok  ' : 'FAIL'}  #{msg}" }
  failed = results.count { |ok, _| !ok }
  puts "\n#{failed.zero? ? 'verify passed' : "verify FAILED (#{failed} check(s))"}"
  exit(failed.zero? ? 0 : 1)
end

def cmd_build(argv)
  force = false
  OptionParser.new do |o|
    o.banner = "usage: eagle.rb build [--force]"
    o.on("--force", "rebuild even if the cache is current") { force = true }
  end.parse!(argv)
  build(force: force)
end

USAGE = <<~TEXT.freeze
  usage: eagle.rb COMMAND [options]

    search PATTERN [--context N] [--max N] [--part NAME]   case-insensitive regex search
    page LABEL [--to LABEL]     print a page: "Proposal Page D", "Page 3", or a PDF page number
    part NAME                   print a whole part (#{PART_TITLES.keys.join(', ')})
    toc                         list every page with its workbook label
    verify                      cross-check the decoding — run this before quoting
    build [--force]             (re)build the text cache
TEXT

argv = ARGV.dup
case argv.shift
when "search" then cmd_search(argv)
when "page" then cmd_page(argv)
when "part" then cmd_part(argv)
when "toc" then cmd_toc(argv)
when "verify" then cmd_verify(argv)
when "build" then cmd_build(argv)
else die USAGE
end
