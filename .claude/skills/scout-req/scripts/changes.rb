#!/usr/bin/env ruby
# frozen_string_literal: true

#
# scout-req -- read the merit badge requirement changes effective Jan. 1, 2026
# out of references/Major-Requirement-Changes-as-of-1_1_2026.pdf.
#
# `req.rb` reads the 2025 requirements book. This reads the change list Scouting
# America published on 11/14/2025 against it: 65 of the book's 139 merit badges,
# with the updated text of every changed requirement beside the 2025 text it
# replaces. Together the two are what a Scout must do in 2026 -- see the LIMITS
# note below for what that claim does *not* cover.
#
#   ruby scripts/changes.rb verify              check the parse -- run this first
#   ruby scripts/changes.rb list [--rows]       the changed badges
#   ruby scripts/changes.rb show NAME           the change table for one badge
#   ruby scripts/changes.rb check [NAME...]     which of these names changed
#   ruby scripts/changes.rb build [--force]
#
# Needs `pdftotext` (poppler): brew install poppler
#
# --------------------------------------------------------------------------
# LIMITS -- say these out loud, do not let them be inferred
#
# - **"Major" changes.** This is Scouting America's published change list, not
#   the 2026 requirements book. A requirement it does not mention is *probably*
#   unchanged, but this document cannot prove it. Never tell anyone "everything
#   else is the same"; say what this is.
# - **Merit badges only.** Every row of this table names a merit badge. No rank
#   and no award appears in it, which is not evidence that ranks did not change
#   -- only that this document does not cover them.
# - **Dated 11/14/2025.** Anything published after that date is not in here.
# --------------------------------------------------------------------------
#
# --------------------------------------------------------------------------
# EXTRACTION NOTES -- measured against the actual PDF (38 pages, 792x612pt
# landscape, Acrobat PDFMaker 25 for Word). Each was established by getting it
# wrong first; none is recoverable by reading the code alone.
#
# - **Row and column boundaries come from the table's own drawn rules, not from
#   the text.** Word emits every cell border as a thin filled rectangle -- 0.48pt
#   high, exactly as wide as the column -- and `pdf-reader` hands them over as
#   `append_rectangle`. That makes row segmentation exact. Every text-based rule
#   tried before this was wrong: the vertical gap between rows (9.0pt) is
#   *smaller* than the gap inside one (9.1pt), and "a line at the cell's base
#   indent starting with a requirement number" over-detects by a quarter,
#   because sub-items sit at base indent and are numbered too (Athletics 5's
#   original column runs "1. Left-side layup" through "8. Anywhere along the
#   three-point line", none of which starts a row).
# - **The badge name cell is vertically centered,** so it is level with whatever
#   happens to be in the middle of its row, not with the row's first line. That
#   is why `pdftotext -layout` is useless here -- it prints the name interleaved
#   into the middle column ("Athletics   or event.") -- and why the geometry has
#   to come from somewhere other than reading order.
# - **Slice columns at the `<word>` level, never `<line>`.** `pdftotext
#   -bbox-layout` merges words from different cells into one `<line>` when they
#   share a baseline: "Citizenship in the Community" and the updated column's
#   "(2) Fire station, police station, and hospital nearest your home" arrive as
#   a single line. Only per-word `xMin` separates the columns.
# - **Compare text against boundaries by the word's vertical center.** A word's
#   `yMin` can sit a half point above the rule that opens its row (65.6 against
#   66.12 on page 2); its center never does.
# - **`pdftotext` for the text, `pdf-reader` for the rules, and neither does
#   both.** `pdftotext -bbox-layout` gives clean word boxes and reading order but
#   no vector graphics; `pdf-reader` gives the rectangles but groups text far
#   worse. Do not swap one without re-measuring.
# - **A border is black; cell shading is the same shape and is not.** Word paints
#   a shaded cell as a stack of hairline strips at text-line pitch -- peach behind
#   the name column, light blue behind the updated one -- each one the exact width
#   of its column, which is to say the exact shape of a border. On page 29 that
#   put ten false boundaries through Search and Rescue requirement 3. Only the
#   fill colour separates them, so `RectCatcher` keeps a rectangle only at the
#   moment it is filled, when the colour in force is known.
# - **Row boundaries are the black rules the *name* and *updated* bands agree on,
#   not all three.** The original column's cell can be merged down across two rows
#   and then carries no rule between them (Veterinary Medicine 6(a) and 6(b), page
#   36); requiring all three welds those two rows into one. The original band also
#   carries strikethrough, which the width test rejects.
# - **A row can outrun its page.** Plant Science requirement 8 fills page 21 and
#   gets no closing horizontal rule; the vertical borders do reach the foot of the
#   page and are what close it. Page 22 is the blank remainder.
# - **Strikethrough is not recovered, and it costs nothing.** The ORIGINAL cell
#   is the 2025 text whether or not the deletions are marked, and pairing it with
#   the UPDATED cell is what carries the meaning. Red = added text *is*
#   recoverable (`pdftohtml -xml` exposes `color="#ff0000"` per fontspec) if
#   word-level change marking is ever wanted; it needs a second extraction.
# - **A cell can be empty, and that is the content.** An empty ORIGINAL means the
#   requirement is new (Traffic Safety 5 and 6, Wilderness Survival 10); an empty
#   UPDATED means it was deleted (Engineering 9). Neither is a parse failure.
# --------------------------------------------------------------------------

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "fileutils"
require "json"
require "open3"
require "optparse"
require "pdf-reader"
require "rbconfig"
require "rexml/document"

# Not `PDF`: the pdf-reader gem defines a module by that name, and shadowing it
# leaves `PDF::Reader` resolving to a string.
CHANGES_PDF = File.join(REPO_ROOT, "references", "Major-Requirement-Changes-as-of-1_1_2026.pdf")
CACHE = File.join(SKILL_DIR, ".cache")
INDEX = File.join(CACHE, "changes.json")
REQ_SCRIPT = File.join(__dir__, "req.rb")

# The date these requirements take effect, and the date the list itself was
# published. Both belong in every citation: the second is what bounds it.
EFFECTIVE = "Jan. 1, 2026"
EFFECTIVE_YEAR = 2026
PUBLISHED = "11/14/2025"
LABEL = "Scouts BSA Major Requirement Changes as of 1/1/#{EFFECTIVE_YEAR}".freeze

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# Identical to `normalize` in req.rb and mbc.rb -- see the note there. Badge
# names are matched against the book through it, so a drift between the copies
# surfaces in `verify` as a pile of unresolved badges rather than as silence.
IGNORED_WORDS = %w[and the].freeze

def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

# --------------------------------------------------------------------------
# the table's drawn rules
#
# The three column bands, as [x, width] of the border rectangles Word draws.
# The name column is 97.32pt wide and the other two 310.92pt; those widths are
# what tells a border apart from the strikethrough rectangles that share the
# page. Positions jitter by a few hundredths between pages, hence BAND_SLOP.
# --------------------------------------------------------------------------
module Rules
  # A row boundary is a black rule the name and updated bands agree on. All
  # three would be wrong: the original column's cell can be merged down across
  # two rows and then carries no rule between them (Veterinary Medicine, PDF
  # page 36), which silently welds the two rows into one.
  BANDS = { name: [36.0, 97.32], updated: [133.8, 310.92], original: [445.2, 310.92] }.freeze
  BAND_SLOP = 3.0
  RULE_HEIGHT = 1.0    # a border is 0.48pt high; nothing else thin is this wide
  SAME_RULE = 1.0      # two rules this close are the same rule
  # A vertical border: hairline wide, at least this tall. Used only for the foot
  # of the table -- see `table_foot`.
  MIN_VERTICAL = 5.0

  module_function

  # [{ height:, boundaries: [top-down y, ...], ... }, ...] -- one per page.
  def per_page(path)
    PDF::Reader.new(path).pages.map { |page| page_rules(page) }
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
    die "cannot read #{path}: #{e.message}"
  end

  def page_rules(page)
    height = page.attributes[:MediaBox][3].to_f
    catcher = RectCatcher.new
    page.walk(catcher)
    bands = horizontal(catcher.rects)
    shared = bands[:name].select { |y| near?(bands[:updated], y) }
    shared = close_last_row(shared, table_foot(catcher.rects))
    { height: height,
      # PDF y is measured up from the foot of the page; text y is measured down
      # from the head of it.
      boundaries: shared.map { |y| (height - y).round(2) }.sort,
      partial: bands.transform_values { |ys| ys.count { |y| !near?(shared, y) } } }
  end

  def horizontal(rects)
    BANDS.transform_values do |(bx, bw)|
      rects.filter_map do |x, y, w, h|
        y.round(2) if h.abs < RULE_HEIGHT && (x - bx).abs < BAND_SLOP && (w - bw).abs < BAND_SLOP
      end.uniq.sort
    end
  end

  # The lowest point the table's vertical borders reach on this page.
  def table_foot(rects)
    feet = rects.filter_map { |_, y, w, h| y if w.abs < RULE_HEIGHT && h.abs >= MIN_VERTICAL }
    feet.min
  end

  # A row too tall for one page runs off the bottom with no closing rule --
  # Plant Science requirement 8 fills PDF page 21 and gets none. Without this
  # the whole cell is silently dropped, which is exactly the kind of loss that
  # reads as "that badge had fewer changes" rather than as an error. The
  # vertical borders do reach the foot of the page, so they are what closes it.
  def close_last_row(shared, foot)
    return shared if foot.nil? || shared.empty?
    return shared if near?(shared, foot) || foot > shared.min

    shared + [foot]
  end

  def near?(list, value)
    list.any? { |other| (other - value).abs <= SAME_RULE }
  end
end

# Every filled rectangle on a page, with the colour it was painted in.
#
# The colour is not decoration here, it is the whole distinction. Word paints
# each shaded cell as a stack of hairline strips at text-line pitch -- peach
# behind the name column, light blue behind the updated one -- and they are the
# same shape as a cell border. On PDF page 29 that put ten false boundaries
# through Search and Rescue requirement 3. Borders are pure black; shading is
# not; nothing else separates them.
#
# `PDF::Reader::Page#walk` only calls back what the receiver responds to, so
# this needs no catch-all.
class RectCatcher
  BLACK = 0.05

  attr_reader :rects

  def initialize
    @rects = []
    @pending = []
    @colour = nil
    @stack = []
  end

  # These names are pdf-reader's, one per PDF content-stream operator, so they
  # are not ours to rename however they read.
  # rubocop:disable Naming/AccessorMethodName
  def save_graphics_state = @stack.push(@colour)
  def restore_graphics_state = @colour = @stack.pop
  def set_rgb_color_for_nonstroking(red, green, blue) = @colour = [red, green, blue].map(&:to_f)
  def set_gray_for_nonstroking(gray) = @colour = [gray.to_f] * 3
  # rubocop:enable Naming/AccessorMethodName

  def append_rectangle(left, bottom, width, height)
    @pending << [left.to_f, bottom.to_f, width.to_f, height.to_f]
  end

  # Only filled rectangles are kept, and only at the moment they are filled --
  # that is when the colour in force is known.
  def fill_path_with_nonzero
    black = @colour&.all? { |c| c <= BLACK }
    @pending.each { |rect| @rects << rect if black }
    @pending = []
  end
  alias fill_path_with_even_odd fill_path_with_nonzero
end

# --------------------------------------------------------------------------
# the words
# --------------------------------------------------------------------------
module Words
  module_function

  # [[{ x:, y:, top:, bottom:, str: }, ...], ...] -- one array per page.
  def per_page(path)
    xml = run_pdftotext(path)
    doc = REXML::Document.new(xml)
    # `-bbox-layout` emits XHTML -- html/body/doc/page -- not pdftohtml's
    # <pdf2xml> root that req.rb reads.
    doc.elements.to_a("//page").map { |page| page_words(page) }
  end

  def run_pdftotext(path)
    out, err, status = Open3.capture3("pdftotext", "-bbox-layout", path, "-")
    die "pdftotext failed: #{err.strip}" unless status.success?
    out
  rescue Errno::ENOENT
    die "pdftotext not found (brew install poppler)"
  end

  def page_words(page)
    page.elements.to_a(".//word").map do |word|
      top = word.attributes["yMin"].to_f
      bottom = word.attributes["yMax"].to_f
      { x: word.attributes["xMin"].to_f, top: top, bottom: bottom,
        # A word's yMin can sit just above the rule that opens its row; its
        # center never does.
        y: (top + bottom) / 2, str: word.text.to_s }
    end
  end
end

# --------------------------------------------------------------------------
# build: cutting the page into cells
# --------------------------------------------------------------------------
module Table
  # The table's left border. Word prints a page number in the margin outside it
  # (PDF page 21 carries a stray "11"), and without this cut it lands in the
  # name column and invents a badge called "Plant Science 11".
  TABLE_LEFT = 35.5
  # Midpoints of the gaps between the three column bands.
  NAME_EDGE = 133.56
  UPDATED_EDGE = 444.96
  COLUMNS = %i[name updated original].freeze

  # Words on the same rounded y are one line of a cell.
  LINE_SLOP = 1.0
  # A cell's nesting, in spaces per point of hanging indent. Calibri 11pt puts
  # the sub-item indents 6.7 and 13.5pt in, which this renders as 2 and 4.
  INDENT_PT = 3.35
  MAX_INDENT = 12

  # The repeated column header. `verify` asserts every page's first row is
  # exactly this, which is what proves the first pair of rules is the header and
  # not a content row whose text is about to be filed as a requirement.
  HEADER_CELLS = ["MERIT BADGE", "UPDATED REQUIREMENT", "ORIGINAL REQUIREMENT"].freeze
  # A word has to carry a letter or a digit to count as content left behind. PDF
  # page 22 -- the blank overflow page after Plant Science -- holds one stray
  # hyphen and nothing else.
  CONTENT = /[[:alnum:]]/

  module_function

  # Returns [content rows, header rows, words left behind]. That last one is
  # this parser's tally: rows tile the table exactly, so a boundary in the wrong
  # place or a page whose rules were missed leaves words unclaimed. Without it a
  # dropped cell reads as "that badge had fewer changes", which looks like an
  # answer rather than an error.
  def rows(pages_words, pages_rules)
    content = []
    headers = []
    stray = []
    pages_words.each_with_index do |words, i|
      inside = words.select { |w| w[:x] >= TABLE_LEFT }
      rows = page_rows(inside, pages_rules[i], i + 1)
      headers.concat(rows.take(1))
      content.concat(rows.drop(1))
      stray.concat(unclaimed(inside, rows, pages_rules[i], i + 1))
    end
    content.each { |row| row.delete(:top) }.each { |row| row.delete(:bottom) }
    [content, headers, stray]
  end

  # Every row on the page, header first: the first pair of rules brackets the
  # repeated column header, and the rest are content.
  def page_rows(words, rules, page_number)
    rules[:boundaries].each_cons(2).map do |top, bottom|
      inside = words.select { |w| w[:y] > top && w[:y] < bottom }
      { page: page_number, top: top, bottom: bottom,
        cells: COLUMNS.to_h { |col| [col, cell_text(inside.select { |w| column(w[:x]) == col })] } }
    end
  end

  # In-table words below the running head that no row claimed. On a page with
  # rules the head is exactly the table's top border; on one without (PDF page
  # 22) there is no border to measure, so fall back to a cutoff between the
  # running head at y≈21 and where the table would start at y≈56.
  HEAD_CUTOFF = 45.0

  def unclaimed(words, rows, rules, page_number)
    head = rules[:boundaries].first || HEAD_CUTOFF
    left = words.select do |w|
      w[:y] > head && w[:str].match?(CONTENT) &&
        rows.none? { |r| w[:y] > r[:top] && w[:y] < r[:bottom] }
    end
    return [] if left.empty?

    [{ page: page_number, count: left.size, sample: left.first(8).map { |w| w[:str] }.join(" ") }]
  end

  def column(left)
    return :name if left < NAME_EDGE
    return :updated if left < UPDATED_EDGE

    :original
  end

  # A cell's text, keeping the PDF's own line breaks and its hanging indents:
  # "(a) Seabird" belongs on a line of its own, and the nesting of "(1) Brake
  # fluid" under "(a) Demonstrate how to check the following:" is the structure
  # of the requirement, not decoration.
  def cell_text(words)
    return "" if words.empty?

    base = words.map { |w| w[:x] }.min
    lines(words).map do |line|
      indent = [((line.first[:x] - base) / INDENT_PT).round, 0].max
      (" " * [indent, MAX_INDENT].min) + line.map { |w| w[:str] }.join(" ")
    end.join("\n")
  end

  def lines(words)
    words.sort_by { |w| [w[:top], w[:x]] }
         .chunk_while { |a, b| (b[:top] - a[:top]).abs < LINE_SLOP }
         .map { |line| line.sort_by { |w| w[:x] } }
  end
end

# --------------------------------------------------------------------------
# build: rows into badges
# --------------------------------------------------------------------------
module Index
  # "9.", "1(c)", "6(a).", "10." -- the requirement this row replaces. Anything
  # after the number is a heading Word bolded into the cell ("2. General
  # Maintenance.") and is not part of the key.
  REQ_KEY = /\A(\d+)\s*(\([a-z0-9]+\))?/

  module_function

  def build(rows)
    badges = []
    rows.each do |row|
      name = row[:cells][:name].tr("\n", " ").squeeze(" ").strip
      if name.empty? && badges.last
        # A row tall enough to break across a page prints its name cell once.
        merge_continuation(badges.last[:rows].last, row)
        next
      end

      badges << { name: name, norm: normalize(name), rows: [] } if badges.last&.dig(:name) != name
      badges.last[:rows] << entry(row)
    end
    badges
  end

  # A cell with no letter or digit in it is empty, whatever glyphs it holds:
  # Engineering's deleted requirement leaves a lone "." behind in the updated
  # column, and reading that as text turns a deletion into a revision.
  def content(text)
    text.match?(/[[:alnum:]]/) ? text.rstrip : ""
  end

  def entry(row)
    updated = content(row[:cells][:updated])
    original = content(row[:cells][:original])
    { req: requirement_key(updated) || requirement_key(original),
      page: row[:page], updated: updated, original: original }
  end

  def requirement_key(text)
    return nil if text.empty?
    return nil unless (m = text.lstrip.match(REQ_KEY))

    "#{m[1]}#{m[2]}"
  end

  def merge_continuation(entry, row)
    %i[updated original].each do |col|
      text = row[:cells][col].rstrip
      next if text.empty?

      entry[col] = [entry[col], text].reject(&:empty?).join("\n")
    end
  end
end

# --------------------------------------------------------------------------
# the requirements book's badge list, via req.rb
#
# Nothing here opens the requirements book. `scout-req`'s own `req.rb` is the
# only reader of it (see CLAUDE.md); this wants the list only to confirm that
# every badge the change table names is a badge the book actually carries.
# --------------------------------------------------------------------------
module Book
  LIST_LINE = /\Amerit badge\s+p\.(\d+)\s+(.+?)\s*(?:\[pamphlet (\d+)\])?\z/

  module_function

  def badge_names
    out, err, status = Open3.capture3(RbConfig.ruby, REQ_SCRIPT, "list", "--kind", "badge")
    unless status.success?
      die "scout-req could not list the merit badges (#{err.strip.split("\n").first}).\n" \
          "#{' ' * 7}Try: ruby #{REQ_SCRIPT} build"
    end
    names = out.lines.filter_map { |line| line.strip.match(LIST_LINE)&.[](2)&.strip }
    die "scout-req listed no merit badges; its cache may be empty" if names.empty?
    names
  end
end

# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

def build(force: false)
  return if !force && File.exist?(INDEX) && File.mtime(INDEX) >= File.mtime(CHANGES_PDF)

  die "missing #{CHANGES_PDF}" unless File.exist?(CHANGES_PDF)
  FileUtils.mkdir_p(CACHE)
  rules = Rules.per_page(CHANGES_PDF)
  rows, headers, stray = Table.rows(Words.per_page(CHANGES_PDF), rules)
  badges = Index.build(rows)

  File.write(INDEX, JSON.pretty_generate(
                      "source" => "references/#{File.basename(CHANGES_PDF)}",
                      "label" => LABEL, "published" => PUBLISHED,
                      "effective" => EFFECTIVE, "effective_year" => EFFECTIVE_YEAR,
                      "page_count" => rules.size,
                      # Cells before and after page-split rows are rejoined.
                      "raw_row_count" => rows.size,
                      "row_count" => badges.sum { |b| b[:rows].size },
                      "rules" => rules.each_with_index.map { |r, i| r.merge(page: i + 1) },
                      "headers" => headers.map { |h| { page: h[:page], cells: h[:cells] } },
                      "stray" => stray,
                      "badges" => badges
                    ))
  warn "built cache: #{badges.size} badges, " \
       "#{badges.sum { |b| b[:rows].size }} changed requirements, #{rules.size} pages"
end

def load_changes
  build
  JSON.parse(File.read(INDEX), symbolize_names: true)
rescue JSON::ParserError => e
  die "#{INDEX} is not valid JSON (#{e.message}); try: changes.rb build --force"
end

def find_badge(data, query)
  target = normalize(query)
  data[:badges].find { |b| b[:norm] == target } ||
    data[:badges].find { |b| b[:norm].include?(target) }
end

# --------------------------------------------------------------------------
# printing
# --------------------------------------------------------------------------

# What the pairing of the two cells means when one of them is empty, or when the
# document spells the answer out in the cell instead of leaving it blank.
NEW_MARKER = /\Anew requirement/i
DELETED_MARKER = /\Adeleted requirement/i

def row_status(row)
  return :deleted if row[:updated].empty? || row[:updated].match?(DELETED_MARKER)
  return :new if row[:original].empty? || row[:original].match?(NEW_MARKER)

  :revised
end

STATUS_NOTE = { new: " (new)", deleted: " (deleted)", revised: "" }.freeze

def print_badge(badge)
  puts "=== #{badge[:name]} — #{badge[:rows].size} " \
       "#{badge[:rows].size == 1 ? 'requirement' : 'requirements'} changed effective #{EFFECTIVE}"
  puts
  badge[:rows].each { |row| print_row(row) }
  print_source
end

def print_row(row)
  label = row[:req] ? "Requirement #{row[:req]}" : "Requirement (unnumbered)"
  status = row_status(row)
  puts "--- #{label}#{STATUS_NOTE[status]} — PDF p.#{row[:page]}"
  print_cell("#{EFFECTIVE_YEAR}:", row[:updated], status == :deleted ? "(deleted)" : nil)
  missing = status == :new ? "(new requirement — nothing to replace)" : nil
  print_cell("2025:", row[:original], missing)
  puts
end

def print_cell(tag, text, empty_note)
  body = text.empty? ? empty_note.to_s : text
  puts "  #{tag}"
  body.split("\n").each { |line| puts "    #{line}" }
end

def print_source
  puts "Source: #{LABEL}, published #{PUBLISHED} " \
       "(references/#{File.basename(CHANGES_PDF)})."
  puts "Requirements not listed above come from Scouts BSA Requirements 2025 " \
       "(`req.rb show`)."
  puts "This is the published list of MAJOR changes, not the 2026 requirements " \
       "book; it covers merit badges only."
end

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_show(argv)
  OptionParser.new { |o| o.banner = "usage: changes.rb show NAME" }.parse!(argv)
  query = argv.join(" ").strip
  die "usage: changes.rb show NAME" if query.empty?

  data = load_changes
  badge = find_badge(data, query)
  unless badge
    puts "#{query}: no major requirement changes listed for #{EFFECTIVE_YEAR}."
    puts "(#{LABEL} names #{data[:badges].size} merit badges; this is not one of them.)"
    return
  end
  print_badge(badge)
end

def cmd_list(argv)
  with_rows = false
  OptionParser.new do |o|
    o.banner = "usage: changes.rb list [--rows]"
    o.on("--rows", "list the changed requirement numbers too") { with_rows = true }
  end.parse!(argv)

  data = load_changes
  data[:badges].each do |badge|
    detail = with_rows ? "  #{badge[:rows].map { |r| r[:req] || '?' }.join(', ')}" : ""
    puts format("%-30s %2d%s", badge[:name], badge[:rows].size, detail)
  end
  puts "\n(#{data[:badges].size} merit badges, #{data[:row_count]} changed requirements, " \
       "effective #{EFFECTIVE})"
end

# Silent for a name with no changes, so a whole report costs one call. This
# never exits nonzero: a badge whose 2026 text is right here is one this skill
# *can* answer for, which is what `req.rb`'s exit 3 is reserved for.
def cmd_check(argv)
  usage = "usage: changes.rb check [NAME...]  (or names on stdin)"
  OptionParser.new { |o| o.banner = usage }.parse!(argv)
  names = argv.reject { |a| a.start_with?("-") }
  names = $stdin.read.lines unless !names.empty? || $stdin.tty?
  names = names.map(&:strip).reject(&:empty?).uniq
  die usage if names.empty?

  data = load_changes
  hits = names.filter_map { |name| find_badge(data, name) }.uniq
  return if hits.empty?

  puts "#{hits.size} of these changed effective #{EFFECTIVE}: " \
       "#{hits.map { |b| b[:name] }.join(', ')}"
  puts "Use `changes.rb show NAME` for the updated text before planning any of them."
end

def cmd_build(argv)
  force = false
  OptionParser.new do |o|
    o.banner = "usage: changes.rb build [--force]"
    o.on("--force", "rebuild even if the cache is current") { force = true }
  end.parse!(argv)
  build(force: force)
end

# --------------------------------------------------------------------------
# verify
#
# Never quote from a parse that fails this. A row boundary in the wrong place
# does not look like an error -- it looks like one badge's updated text filed
# under the requirement number of the row above it, which reads as a perfectly
# good answer. There is no tally row in this document, so the checks below are
# what stands in for one: the table's three columns must agree on where the rows
# are, every row must carry exactly one badge name, and every badge name must be
# one the 2025 book carries.
# --------------------------------------------------------------------------

# Passages destroyed by a column split or a row boundary in the wrong place.
# Each is the *whole* of the cell it names, so a row that swallowed its
# neighbour fails here even though every word of it is present.
CANARIES = [
  # A plain row, to catch a column split.
  ["Archaeology", "9", :updated,
   /\A9\. Explore careers related to this merit badge\..*interesting career\.\z/m],
  # Shading strips through this cell used to shatter it into ten slivers.
  ["Search and Rescue", "3", :updated,
   /\A3\. Maps\..*human-made boundaries\.\z/m],
  # The original column merges these two rows into one cell; the name and
  # updated columns do not, and a boundary taken from all three welds them.
  ["Veterinary Medicine", "6(a)", :updated,
   /\A6\(a\)\. Visit a veterinary clinic.*with your counselor\.\z/m],
  ["Veterinary Medicine", "6(b)", :updated,
   /\A6\(b\)\. Spend as much time.*needs of the general public\.\z/m],
  # The cell that fills a whole page and runs off the foot of it with no
  # closing rule.
  ["Plant Science", "8", :updated,
   /\A8\. Option C—Field Botany\..*used by botanists in an herbarium\.\z/m],
  # Numbered sub-items at the cell's base indent -- the shape that defeated
  # every attempt to find rows in the text.
  ["Athletics", "5", :updated,
   /\A5\. Option G—Basketball Shooting\..*three-point line\.\z/m],
  ["Athletics", "5", :original,
   /\A5\. Option 7: Basketball Shooting.*Anywhere along the three-point line\z/m],
  # A name cell that shares a baseline with the updated column's text.
  ["Citizenship in the Community", "2", :updated,
   /Fire station, police station, and hospital nearest your home/],
  # An empty cell in each direction: deleted, then new.
  ["Cycling", "1(c)", :updated, /\Adeleted requirement\z/],
  ["Engineering", "9", :updated, /\A\z/],
  ["Wilderness Survival", "10", :original, /\A\z/],
  ["Swimming", "2", :updated,
   /\A2\. Before doing the following requirements.*Swimming merit badge pamphlet\.\z/m]
].freeze

def cmd_verify(_argv)
  data = load_changes
  problems = []
  problems.concat(verify_rules(data))
  problems.concat(verify_rows(data))
  problems.concat(verify_order(data))
  problems.concat(verify_book(data))
  problems.concat(verify_canaries(data))

  if problems.empty?
    puts "PASS — #{data[:page_count]} pages, #{data[:badges].size} merit badges, " \
         "#{data[:row_count]} changed requirements, effective #{EFFECTIVE}."
    return
  end

  puts "FAIL — #{problems.size} problem(s):"
  problems.each { |p| puts "  - #{p}" }
  exit 1
end

# The name and updated columns must agree on every row boundary. The original
# column carries strikethrough rectangles as well, so it is only ever a superset.
# Nothing inside the table may go unclaimed by a row. Rows tile the table
# exactly, so this is what catches a boundary the band intersection dropped. A
# page with no rules at all is fine only if it is blank -- PDF page 22 is, being
# the overflow page left behind by the Plant Science cell that fills page 21.
#
# The opposite failure, two rows *merged* because a real boundary went missing,
# loses no words and so cannot show up here. It shows up in verify_book and
# verify_order instead: a merged row swallows both rows' centered badge labels,
# and "Search and Rescue Search and Rescue" is not a merit badge in the book.
def verify_rules(data)
  problems = data[:stray].map do |page|
    "p.#{page[:page]}: #{page[:count]} word(s) inside the table belong to no " \
      "row: #{page[:sample].inspect}"
  end
  problems + verify_headers(data)
end

# Every page's first row must be the repeated column header. If it is not, the
# first pair of rules is not the header, and every row on that page is shifted.
def verify_headers(data)
  return ["no column header found on any page"] if data[:headers].empty?

  data[:headers].filter_map do |header|
    cells = Table::COLUMNS.map { |col| header[:cells][col].to_s.tr("\n", " ").strip }
    next if cells == Table::HEADER_CELLS

    "p.#{header[:page]}: first row is #{cells.inspect}, not the column header"
  end
end

def verify_rows(data)
  rows = data[:badges].flat_map { |b| b[:rows] }
  problems = []
  problems << "row count #{rows.size} does not match #{data[:row_count]} indexed" if
    rows.size != data[:row_count]
  if data[:raw_row_count] < data[:row_count]
    problems << "#{data[:raw_row_count]} cells became #{data[:row_count]} requirements; " \
                "rejoining page-split rows can only reduce the count"
  end

  blank = rows.reject { |r| r[:req] }
  unless blank.empty?
    problems << "#{blank.size} row(s) carry no requirement number " \
                "(PDF p.#{blank.map { |r| r[:page] }.uniq.join(', ')})"
  end

  empty = rows.select { |r| r[:updated].empty? && r[:original].empty? }
  problems << "#{empty.size} row(s) are empty in both columns" unless empty.empty?
  problems
end

def verify_order(data)
  names = data[:badges].map { |b| b[:norm] }
  problems = []
  dupes = names.tally.select { |_, n| n > 1 }.keys
  problems << "badges appear in more than one run: #{dupes.join(', ')}" unless dupes.empty?
  data[:badges].each_cons(2) do |a, b|
    next unless a[:norm] > b[:norm]

    problems << "out of alphabetical order: #{a[:name]} then #{b[:name]}"
  end
  problems
end

def verify_book(data)
  known = Book.badge_names.to_h { |n| [normalize(n), n] }
  unknown = data[:badges].reject { |b| known.key?(b[:norm]) }
  return [] if unknown.empty?

  ["named here but not a merit badge in the 2025 book: " \
   "#{unknown.map { |b| b[:name] }.join(', ')}"]
end

def verify_canaries(data)
  CANARIES.filter_map do |name, req, column, pattern|
    badge = find_badge(data, name)
    next "canary: #{name} is not in the change list at all" unless badge

    row = badge[:rows].find { |r| r[:req] == req }
    next "canary: #{name} has no row for requirement #{req}" unless row

    "canary: #{name} #{req} #{column} does not match #{pattern.inspect}" unless
      row[column.to_sym].match?(pattern)
  end
end

USAGE = <<~TEXT.freeze
  usage: changes.rb COMMAND [options]

    show NAME             the #{EFFECTIVE_YEAR} change table for one merit badge
    list [--rows]         the merit badges that changed
    check [NAME...]       which of these names changed (silent if none)
    verify                check the parse — run this first
    build [--force]       (re)build the cache

  #{LABEL}, published #{PUBLISHED}.
  Major changes only, merit badges only; the rest comes from `req.rb`.
TEXT

argv = ARGV.dup
case argv.shift
when "show" then cmd_show(argv)
when "list" then cmd_list(argv)
when "check" then cmd_check(argv)
when "verify" then cmd_verify(argv)
when "build" then cmd_build(argv)
else die USAGE
end
