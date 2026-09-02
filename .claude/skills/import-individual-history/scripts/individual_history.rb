#!/usr/bin/env ruby
# frozen_string_literal: true

#
# import-individual-history — read a TroopMaster "Individual History" report
# into the SQLite cache that the advancement-plan skills answer from.
#
#   ruby scripts/individual_history.rb verify [REPORT.pdf]
#   ruby scripts/individual_history.rb import [REPORT.pdf] [--force]
#   ruby scripts/individual_history.rb list
#   ruby scripts/individual_history.rb show   "Last, First"
#   ruby scripts/individual_history.rb json   ["Last, First"]
#   ruby scripts/individual_history.rb stale  [--days N]
#   ruby scripts/individual_history.rb badges [REPORT.pdf]
#   ruby scripts/individual_history.rb notes  [REPORT.pdf]
#
# With no REPORT.pdf, the newest `IndividualHistoryReport-*.pdf` in `reports/`
# is used. This script owns exactly one thing: turning the report into rows.
# It plans nothing and quotes no requirement text — that comes from scout-req.
#
# --------------------------------------------------------------------------
# Facts about the report this script depends on
# --------------------------------------------------------------------------
#
# * **`-bbox-layout`, not `-layout`, and the reason is measured.** The report is
#   a table, and under plain `-layout` two of its columns cannot be separated by
#   whitespace at all: in the Merit Badges list a long name runs right up to its
#   date, so the troop's own rows read `Soil and Water Conservation 02/28/26`
#   and `Environmental Science* 11/09/24` — **one space**, the same as the space
#   inside the name. Splitting on runs of spaces silently merges the two, and
#   the badge then has no date. `-bbox-layout` gives every word an x, which is
#   the only thing that separates them.
#
# * **Every table cell is its own `<line>`, and a row is a set of lines sharing
#   a `yMin`.** TroopMaster draws the report column by column, so poppler emits
#   the name column and the date column as separate blocks; `Art` and its
#   `08/29/23` never appear in the same line element. Rows are therefore
#   recovered by clustering on y and then sorting the cells by x — not by
#   reading lines top to bottom, which interleaves the columns.
#
# * **The column x-origins differ from Scout to Scout.** A Scout with long badge
#   names gets wider columns, so the requirement dates sit at x=216 on one page
#   and elsewhere on another. Nothing here hard-codes an x. Cells are paired
#   left to right — label, then the next cell that looks like a date — which is
#   what makes a *missing* value (a Scout with no `Position:`, or with no date
#   of birth) shift nothing: the cell is simply absent from the row.
#
# * **A long label and its date can still land in one cell.** Even under
#   `-bbox-layout`, when the two nearly touch poppler merges them, which is why
#   `Row#pairs` splits a trailing date back off. The guard is that the text
#   before it must not end in `-`: a Leadership cell reads `04/22/25 - 10/22/25`
#   and would otherwise be torn into a label and a date.
#
# * **`__/__/__` is a requirement that is printed but not signed off.** It is
#   not missing data. Storing it as NULL alongside a genuinely absent cell would
#   lose the distinction between "the report says this is not done" and "the
#   report did not mention this", and every plan built on it turns on that.
#
# * **Only ranks the Scout has NOT earned get a requirement block.** A Scout who
#   is Star has blocks for Life and Eagle and none for Tenderfoot — the earned
#   ones appear as one line each under "Completed Ranks". So an empty
#   requirement set for a rank means *earned*, never *nothing done*, and
#   `verify` asserts the two lists never overlap.
#
# * **`*` on a badge name means Eagle-required; `#` means something else and
#   this script does not guess.** The page legend defines `#` only for
#   positions ("Position not credited toward rank"), yet it also turns up on a
#   partial badge (`Citizenship in Society#`). The marker is stored verbatim and
#   reported as a note; nothing downstream is allowed to read a meaning into it.
#
# * **A parenthesised line under a requirement is an annotation on the
#   requirement above it, in the same column.** The Palm block prints
#   `(discontinued 2024)` on its own row at the x of the left column under
#   `Participation`, and again at the x of the right column under `Scoutmaster
#   Conference`. It is attached by x, because by y alone it looks like a row of
#   its own with a missing date.
#
# * **The report carries its own tally, and it is the one real cross-check.**
#   Each Scout's badge list is headed `Merit Badges : N`. `verify` checks N
#   against the rows parsed, and — independently — that every badge named in a
#   Star/Life/Eagle slot appears in that list with the same date. A misaligned
#   parse fails both.
#
# * **Sections are optional and the last one can simply stop.** A Scout with no
#   leadership history has no Leadership section at all, and the report ends
#   mid-page. A parser that expects a fixed section order to terminate will read
#   the next Scout's header as this one's data.
#
# * **Freshness is per Scout, not per file.** The report date is printed
#   top-left of each Scout's first page (`9/1/2026`) and is what a row's
#   currency is measured by — not the file's mtime and not the filename. An
#   import of an older report therefore leaves a Scout alone rather than
#   rewinding them; `--force` is the only way past that.
#
# --------------------------------------------------------------------------
# Privacy
# --------------------------------------------------------------------------
#
# This report is a roster of minors — names, emails, phone numbers, dates of
# birth, BSA IDs. The database lives under the skill's `.cache/`, which
# `.gitignore` covers. Nothing this script writes belongs in a tracked file.

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "fileutils"
require "open3"
require "rbconfig"
require "time"

require "rexml/document"
require "sqlite3"

CACHE_DIR   = File.join(SKILL_DIR, ".cache")
DB_PATH     = File.join(CACHE_DIR, "individual-history.db")
REPORTS_DIR = File.join(REPO_ROOT, "reports")
REQ_SCRIPT  = File.join(REPO_ROOT, ".claude", "skills", "scout-req", "scripts", "req.rb")

SCHEMA_VERSION = 1
STALE_DAYS     = 30    # a plan built on data older than this wants a fresh report

# The rank ladder, in order. Palms follow Eagle and are tracked the same way,
# so they get requirement blocks of their own.
RANK_LADDER = ["Scout", "Tenderfoot", "Second Class", "First Class",
               "Star", "Life", "Eagle"].freeze
PALMS       = ["Bronze Palm", "Gold Palm", "Silver Palm"].freeze
RANK_BLOCKS = (RANK_LADDER + PALMS).freeze

DATE_SRC = '\d{1,2}/\d{1,2}/\d{2}'
DATE_RE  = /\A#{DATE_SRC}\z/o
BLANK    = "__/__/__"

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# Fold spelling differences between TroopMaster, the requirements book, and
# whatever the user typed. **This must stay identical to `normalize` in
# `req.rb`, `mbc.rb`, and `inventory.rb`** — "and" and "the" go because the
# book's own Merit Badge Library abbreviates that way. It is what makes the
# report's "Fly Fishing" resolve against the book's "Fly-Fishing", and its
# "Signs, Signals & Codes" against "Signs, Signals, and Codes".
IGNORED_WORDS = %w[and the].freeze

def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

# TroopMaster prints two-digit years throughout; every date in the report is
# this century.
def parse_date(text)
  return nil if text.nil? || text.empty? || text == BLANK

  if (m = text.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}))
    return Date.new(m[3].to_i, m[1].to_i, m[2].to_i)
  end

  m = text.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{2})\z}) or return nil
  Date.new(2000 + m[3].to_i, m[1].to_i, m[2].to_i)
rescue Date::Error
  nil
end

# --------------------------------------------------------------------------
# extraction
# --------------------------------------------------------------------------
Cell = Struct.new(:x, :xmax, :text) do
  def date?  = text == BLANK || text.match?(DATE_RE)
  def blank? = text == BLANK
end

Row = Struct.new(:page, :y, :cells) do
  def one   = cells.size == 1 ? cells.first : nil
  def text  = cells.map(&:text).join("  ")
  def words = cells.sum { |c| c.text.split.size }

  # Split a trailing date back off a cell poppler merged with its label. The
  # `-` guard keeps a Leadership range ("04/22/25 - 10/22/25") intact.
  def split_dates
    cells.flat_map do |c|
      m = c.text.match(%r{\A(.*[A-Za-z0-9].*?)\s+(#{DATE_SRC}|__/__/__)\z}o)
      next [c] if m.nil? || m[1].end_with?("-")

      [Cell.new(c.x, c.xmax, m[1]), Cell.new(c.xmax, c.xmax, m[2])]
    end
  end

  # Label cells paired with the date that follows them, if any.
  def pairs
    out = []
    cs  = split_dates
    i   = 0
    while i < cs.size
      if cs[i + 1]&.date?
        out << [cs[i], cs[i + 1]]
        i += 2
      else
        out << [cs[i], nil]
        i += 1
      end
    end
    out
  end
end

module Extract
  Y_TOLERANCE = 2.0

  module_function

  def pages(path)
    xml, err, status = Open3.capture3("pdftotext", "-bbox-layout", path, "-")
    unless status.success?
      die "pdftotext failed on #{path} (#{err.strip.lines.first}). Is poppler installed?"
    end

    REXML::Document.new(xml).elements.to_a("//page")
                   .each_with_index.map { |page, i| rows(page, i + 1) }
  end

  def rows(page, number)
    lines = page.elements.to_a(".//line").filter_map do |line|
      words = line.elements.to_a("word").filter_map { |w| w.text&.strip }
      next if words.empty?

      xs = line.elements.to_a("word").map { |w| w.attributes["xMin"].to_f }
      [line.attributes["yMin"].to_f,
       Cell.new(xs.min, line.attributes["xMax"].to_f, words.join(" "))]
    end
    cluster(lines).map { |y, cells| Row.new(number, y, cells.sort_by(&:x)) }
  end

  def cluster(lines)
    lines.sort_by(&:first).each_with_object([]) do |(y, cell), out|
      if out.last && (y - out.last[0]).abs <= Y_TOLERANCE
        out.last[1] << cell
      else
        out << [y, [cell]]
      end
    end
  end
end

# --------------------------------------------------------------------------
# the parsed report
# --------------------------------------------------------------------------
Scout = Struct.new(
  :last_name, :first_name, :patrol, :email, :phone, :rank, :rank_date,
  :position, :dob, :age, :joined, :bsa_id,
  :nights_camping, :miles_hiking, :service_hours,
  :completed_ranks, :requirements, :merit_badges, :partials,
  :awards, :leadership, :declared_badges, :pages,
  keyword_init: true
) do
  def name = "#{last_name}, #{first_name}"

  # BSA ID is the real identity; two Scouts can share a name, and a Scout can
  # be renamed. Fall back to the name only when the report omits the ID.
  def key = bsa_id.to_s.empty? ? name : bsa_id

  def blocks = requirements.map { |r| r[:rank] }.uniq

  def badge_names
    (merit_badges.map { |b| b[:name] } +
     partials.map { |p| p[:name] } +
     requirements.filter_map { |r| r[:badge] }).uniq
  end
end

# --------------------------------------------------------------------------
# One handler per section of the report. They are a mixin rather than part of
# `Parser` so that the state machine — which row belongs to which section — stays
# separable from what each section means.
# --------------------------------------------------------------------------
module Sections
  HEADER_LABELS = ["Name:", "Patrol:", "Rank:", "Position:", "Email:", "Phone:",
                   "Date:", "Date of Birth:", "Age:", "Date Joined Unit:", "BSA ID:"].freeze

  ACTIVITY = { "Total Nights Camping:" => :nights_camping,
               "Miles Hiking:" => :miles_hiking,
               "Service Hours:" => :service_hours }.freeze

  PARTIAL_HEAD = /\A(.+?)\s*\((\d{4})\)\s*:\s*(\d+)%\z/
  RANGE        = /\A(#{DATE_SRC})\s*-\s*(#{DATE_SRC}|present)\s*(\#?)\z/o
  EMPTY_SLOT   = /\A_+\z/

  private

  # Walk a row of `Label:` / value cells. A label may carry its value inline
  # ("BSA ID: 100000000") or in the next cell ("Date Joined Unit:", "12/01/24"),
  # and a value that is simply absent shifts nothing because the cell is gone.
  def labelled(cells, labels, row)
    out = {}
    i = 0
    while i < cells.size
      text  = cells[i].text
      label = labels.find { |l| text == l || text.start_with?("#{l} ") }
      if label.nil?
        unclaim_cell(row, cells[i])
        i += 1
      elsif (inline = text[label.size..].to_s.strip) != ""
        out[label] = inline
        i += 1
      elsif cells[i + 1] && labels.none? { |candidate| cells[i + 1].text.start_with?(candidate) }
        out[label] = cells[i + 1].text
        i += 2
      else
        i += 1
      end
    end
    out
  end

  # The header spans four rows, so every field is assigned with `||=`: a later
  # row must not blank out what an earlier one already set.
  def handle_header(row)
    fields = labelled(row.cells, HEADER_LABELS, row)
    identity(fields)
    standing(fields)
  end

  def identity(fields)
    if (printed = fields["Name:"])
      last, first = printed.split(",", 2).map(&:strip)
      @scout.last_name  = last
      @scout.first_name = first
    end
    @scout.bsa_id ||= fields["BSA ID:"]
    @scout.patrol ||= fields["Patrol:"]
    @scout.email  ||= fields["Email:"]
    @scout.phone  ||= fields["Phone:"]
  end

  def standing(fields)
    @scout.rank      ||= fields["Rank:"]
    @scout.position  ||= fields["Position:"]
    @scout.age       ||= fields["Age:"]&.to_i
    @scout.rank_date ||= parse_date(fields["Date:"])
    @scout.dob       ||= parse_date(fields["Date of Birth:"])
    @scout.joined    ||= parse_date(fields["Date Joined Unit:"])
  end

  def handle_completed_ranks(row)
    row.pairs.each do |label, date|
      if date.nil? || date.blank?
        unclaim_cell(row, label)
      else
        @scout.completed_ranks << { rank: label.text, on: parse_date(date.text) }
      end
    end
  end

  def handle_rank_block(row)
    pairs = row.pairs
    return annotate(row, pairs[0][0]) if pairs.size == 1 && pairs[0][1].nil?

    pairs.each do |label, date|
      next unclaim_cell(row, label) if date.nil?

      @column_last[label.x.round] = @scout.requirements.size
      @scout.requirements << requirement(label.text, date, label.x, row.y)
    end
  end

  def requirement(text, date, xpos, ypos)
    m = text.match(/\A(\d+[a-z]?)\.\s*(.*)\z/)
    req_id, label = m ? [m[1], m[2]] : [nil, text]
    slot = label.match(/\A(.*?)\s*MB\z/)
    entry = { rank: @block, req_id: req_id, label: label, note: nil,
              kind: slot ? "badge_slot" : "requirement",
              badge: nil, eagle_required: false, x: xpos, y: ypos, seq: nil,
              on: parse_date(date.text), signed: !date.blank? }
    if slot && !slot[1].match?(EMPTY_SLOT)
      entry[:eagle_required] = slot[1].end_with?("*")
      entry[:badge] = slot[1].sub(/\*\z/, "").strip
    end
    entry
  end

  # `(discontinued 2024)` sits on a row of its own at the x of the column whose
  # requirement it belongs to.
  def annotate(row, cell)
    idx = @column_last[cell.x.round]
    return unclaim_cell(row, cell) if idx.nil?

    @scout.requirements[idx][:note] = cell.text
  end

  def handle_merit_badges(row)
    row.pairs.each do |label, date|
      next unclaim_cell(row, label) if date.nil?

      @scout.merit_badges << badge_fields(label.text).merge(on: parse_date(date.text))
    end
  end

  # `*` is Eagle-required. `#` is recorded and left uninterpreted.
  def badge_fields(name)
    { name: name.sub(/[*#]+\z/, "").strip,
      eagle_required: name.end_with?("*"),
      marker: name.include?("#") ? "#" : nil }
  end

  def handle_partials(row)
    first = row.cells.first
    if (head = first.text.match(PARTIAL_HEAD))
      start_partial(row, head)
    elsif first.text.start_with?("Counselor:")
      partial_counselor(row)
    elsif first.text.start_with?("Open Reqts:")
      set_open_reqts(row, first.text.sub(/\AOpen Reqts:\s*/, ""))
    elsif row.one && @scout.partials.last&.dig(:open_reqts)
      set_open_reqts(row, "#{@scout.partials.last[:open_reqts]} #{first.text}")
    else
      unclaim(row)
    end
  end

  def start_partial(row, head)
    f = labelled(row.cells.drop(1), ["Start Date:", "Last Progress:"], row)
    @scout.partials << badge_fields(head[1]).merge(
      year: head[2].to_i, percent: head[3].to_i,
      start: parse_date(f["Start Date:"]), last_progress: parse_date(f["Last Progress:"]),
      counselor: nil, counselor_bsa_id: nil, open_reqts: nil
    )
  end

  def partial_counselor(row)
    partial = @scout.partials.last or return unclaim(row)

    f = labelled(row.cells, ["Counselor:", "BSA ID:"], row)
    partial[:counselor]        = f["Counselor:"]
    partial[:counselor_bsa_id] = f["BSA ID:"]
  end

  def set_open_reqts(row, text)
    partial = @scout.partials.last or return unclaim(row)

    partial[:open_reqts] = text.strip
  end

  def handle_activity(row)
    labelled(row.cells, ACTIVITY.keys, row).each do |label, value|
      @scout[ACTIVITY[label]] = value&.to_f
    end
  end

  def handle_awards(row)
    row.pairs.each do |label, date|
      next unclaim_cell(row, label) if date.nil?

      @scout.awards << { name: label.text, on: parse_date(date.text) }
    end
  end

  def handle_leadership(row)
    cells = row.cells
    i = 0
    while i < cells.size
      m = cells[i + 1]&.text&.match(RANGE)
      if m.nil?
        unclaim_cell(row, cells[i])
        i += 1
      else
        @scout.leadership << { position: cells[i].text, from: parse_date(m[1]),
                               to: m[2] == "present" ? nil : parse_date(m[2]),
                               current: m[2] == "present", credited: m[3] != "#" }
        i += 2
      end
    end
  end

  def unclaim(row)
    row.cells.each { |c| unclaim_cell(row, c) }
  end

  def unclaim_cell(row, cell)
    @unclaimed << { page: row.page, scout: @scout&.name, section: @section, text: cell.text }
  end
end

class Parser
  include Sections

  # Page furniture: the report date, the legend, the running title, and the
  # continuation header. A row made up entirely of these carries no data.
  FURNITURE = [%r{\A\d{1,2}/\d{1,2}/\d{4}\z},
               /\A\(\s*#\s*-\s*Position not credited toward rank\s*\)\z/,
               /\ATroop .+ Individual History\z/,
               /\(continued\)\z/,
               /\APage \d+\z/].freeze

  attr_reader :scouts, :report_date, :troop, :unclaimed, :continuations, :source

  def initialize(path)
    @source        = path
    @scouts        = []
    @unclaimed     = []
    @continuations = []
    @scout         = nil
    @section       = nil
    @block         = nil
    @column_last   = {}
    Extract.pages(path).each { |rows| rows.each { |row| dispatch(row) } }
    @scouts.each { |scout| order_requirements(scout) }
  end

  private

  # The report prints a rank block as two columns read top to bottom, so a row
  # holds requirement 1a beside 5a. Sorting by column, then by row, restores
  # 1a..4d, 5a..11 — the order the requirements are actually numbered in.
  def order_requirements(scout)
    order = RANK_BLOCKS.each_with_index.to_h
    scout.requirements.sort_by!.with_index { |r, i| [order.fetch(r[:rank], 99), r[:x], r[:y], i] }
    scout.requirements.each_with_index { |r, i| r[:seq] = i }
  end

  def dispatch(row)
    return if furniture?(row)
    return if start_scout?(row)
    return unclaim(row) if @scout.nil?
    return if section_header?(row)

    case @section
    when :header          then handle_header(row)
    when :completed_ranks then handle_completed_ranks(row)
    when :rank_block      then handle_rank_block(row)
    when :merit_badges    then handle_merit_badges(row)
    when :partials        then handle_partials(row)
    when :activity        then handle_activity(row)
    when :awards          then handle_awards(row)
    when :leadership      then handle_leadership(row)
    else unclaim(row)
    end
  end

  def furniture?(row)
    return false unless row.cells.all? { |c| FURNITURE.any? { |re| c.text.match?(re) } }

    row.cells.each do |cell|
      @report_date ||= parse_date(cell.text) if cell.text.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z})
      @troop       ||= Regexp.last_match(1) if cell.text =~ /\ATroop (.+?) Individual History\z/
      next unless cell.text.end_with?("(continued)")

      @continuations << [row.page,
                         cell.text.sub(/\s*\(continued\)\z/,
                                       "")]
    end
    true
  end

  def start_scout?(row)
    return false unless row.cells.first&.text == "Name:"

    @scout = Scout.new(completed_ranks: [], requirements: [], merit_badges: [],
                       partials: [], awards: [], leadership: [], pages: [])
    @scouts << @scout
    @section = :header
    @block = nil
    @column_last = {}
    handle_header(row)
    true
  end

  def section_header?(row)
    cell = row.one or return false

    case cell.text
    when "Completed Ranks" then @section = :completed_ranks
    when /\AMerit Badges\s*:\s*(\d+)\z/
      @scout.declared_badges = Regexp.last_match(1).to_i
      @section = :merit_badges
    when "Partial Merit Badges"     then @section = :partials
    when "Activity Totals"          then @section = :activity
    when "Special Awards"           then @section = :awards
    when "Leadership"               then @section = :leadership
    else
      return false unless RANK_BLOCKS.include?(cell.text) && @section != :rank_block_body

      @block = cell.text
      @section = :rank_block
      @column_last = {}
    end
    true
  end
end

# --------------------------------------------------------------------------
# the merit badge list, from scout-req
# --------------------------------------------------------------------------
# A TroopMaster report is exactly where a post-2025 badge enters unannounced,
# so every badge name the report carries is reconciled against the requirements
# book. Like `mbc.rb` and `inventory.rb` this uses `list`, not `check`: it needs
# the *whole* list, because "the book does not carry that badge" and "that is
# not a badge" are different answers and only the book tells them apart. It
# reports no requirement text, so it does not propagate req.rb's exit 3.
module Book
  LIST_LINE  = /\Amerit badge\s+p\.(\d+)\s+(.+?)\s*(?:\[pamphlet (\d+)\])?\z/
  LIST_TOTAL = /\A\((\d+) entries:/

  module_function

  def badges
    @badges ||= begin
      out, err, status = Open3.capture3(RbConfig.ruby, REQ_SCRIPT, "list", "--kind", "badge")
      unless status.success?
        die "scout-req could not list the merit badges (#{err.strip.lines.first})"
      end

      names = out.lines.filter_map { |l| l.strip.match(LIST_LINE)&.[](2)&.strip }
      total = out.lines.filter_map { |l| l.strip.match(LIST_TOTAL)&.[](1)&.to_i }.first
      if total && total != names.size
        die "parsed #{names.size} badges from scout-req but it reported #{total}"
      end

      names.to_h { |n| [normalize(n), n] }
    end
  end
end

# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------
# A misparse of a grid this dense does not look like an error — it looks like a
# Scout who is behind. Nothing is imported until these pass.
module Verify
  module_function

  def run(parser)
    fails = []
    notes = []
    fails << "no report date found on any page" if parser.report_date.nil?
    fails << "no Scout found in the report" if parser.scouts.empty?
    parser.unclaimed.each do |cell|
      who = cell[:scout] || "(no Scout yet)"
      fails << "p#{cell[:page]} #{who}: unread text #{cell[:text].inspect}"
    end
    duplicates(parser, fails)
    continuations(parser, fails)
    parser.scouts.each { |scout| checks(scout, parser, fails, notes) }
    [fails, notes]
  end

  def duplicates(parser, fails)
    parser.scouts.group_by(&:key).each do |key, group|
      next unless group.size > 1

      fails << "#{group.first.name}: appears #{group.size} times under the same id (#{key})"
    end
  end

  # Every page after a Scout's first repeats the name; a page attributed to the
  # wrong Scout is how a section silently migrates between them.
  def continuations(parser, fails)
    known = parser.scouts.map(&:name)
    parser.continuations.each do |page, name|
      next if known.include?(name)

      fails << "p#{page}: continuation header names #{name.inspect}, " \
               "who has no record in this report"
    end
  end

  def checks(scout, parser, fails, notes)
    fails << "#{scout.name}: no BSA ID" if scout.bsa_id.to_s.empty?
    tally(scout, fails)
    ladder(scout, fails)
    slots(scout, fails)
    dates(scout, parser, fails)
    partials(scout, fails)
    book(scout, notes)
    markers(scout, notes)
    gaps(scout, notes)
  end

  # The one tally the report prints of its own accord.
  def tally(scout, fails)
    declared = scout.declared_badges
    return fails << "#{scout.name}: no \"Merit Badges : N\" heading" if declared.nil?
    return if declared == scout.merit_badges.size

    fails << "#{scout.name}: report declares #{declared} merit badges, " \
             "parsed #{scout.merit_badges.size}"
  end

  # Completed ranks are a prefix of the ladder, the header agrees with them, and
  # a rank never has both a completion date and a requirement block.
  def ladder(scout, fails)
    completed = scout.completed_ranks.map { |rank| rank[:rank] }
    earned    = completed.last
    on        = scout.completed_ranks.last&.dig(:on)

    if completed != RANK_LADDER.first(completed.size)
      fails << "#{scout.name}: completed ranks #{completed.inspect} are not the ladder in order"
    end
    if earned != scout.rank
      fails << "#{scout.name}: header rank #{scout.rank.inspect} but " \
               "last completed rank is #{earned.inspect}"
    end
    if earned && on != scout.rank_date
      fails << "#{scout.name}: header rank date #{scout.rank_date} but #{earned} completed #{on}"
    end
    blocks(scout, completed, fails)
  end

  def blocks(scout, completed, fails)
    both = completed & scout.blocks
    unless both.empty?
      fails << "#{scout.name}: #{both.join(', ')} is both completed and " \
               "printed as an unfinished block"
    end

    missing = RANK_LADDER.drop(completed.size) - scout.blocks
    fails << "#{scout.name}: no requirement block for #{missing.join(', ')}" unless missing.empty?
  end

  # A badge named in a Star/Life/Eagle slot must be in the Scout's badge list
  # with the same date. The two are printed from the same data by different code
  # paths, so a column that has slipped disagrees here.
  def slots(scout, fails)
    earned = scout.merit_badges.to_h { |badge| [normalize(badge[:name]), badge[:on]] }
    scout.requirements.each do |req|
      next if req[:badge].nil?

      key = normalize(req[:badge])
      if !earned.key?(key)
        fails << "#{scout.name}: #{req[:rank]} credits #{req[:badge]} " \
                 "but it is not in the badge list"
      elsif earned[key] != req[:on]
        fails << "#{scout.name}: #{req[:rank]} dates #{req[:badge]} #{req[:on]}, " \
                 "badge list says #{earned[key]}"
      end
    end
  end

  def dates(scout, parser, fails)
    limit = parser.report_date or return

    dated(scout).each do |label, date|
      next unless date && date > limit

      fails << "#{scout.name}: #{label} dated #{date}, after the report date #{limit}"
    end
  end

  def dated(scout)
    scout.completed_ranks.map { |rank| [rank[:rank], rank[:on]] } +
      scout.merit_badges.map { |badge| [badge[:name], badge[:on]] } +
      scout.awards.map { |award| [award[:name], award[:on]] } +
      scout.requirements.filter_map { |req| [req[:label], req[:on]] if req[:on] } +
      scout.leadership.map { |post| ["#{post[:position]} start", post[:from]] }
  end

  def partials(scout, fails)
    earned = scout.merit_badges.map { |badge| normalize(badge[:name]) }
    scout.partials.each do |part|
      unless (0..100).cover?(part[:percent])
        fails << "#{scout.name}: #{part[:name]} is #{part[:percent]}% complete"
      end
      if earned.include?(normalize(part[:name]))
        fails << "#{scout.name}: #{part[:name]} is listed as both earned and partial"
      end
      next unless part[:open_reqts].to_s.empty?

      fails << "#{scout.name}: partial #{part[:name]} has no open requirements"
    end
  end

  # Not a failure: a badge the 2025 printing does not carry is a true fact about
  # the troop, not a parse error.
  def book(scout, notes)
    scout.badge_names.each do |name|
      next if Book.badges.key?(normalize(name))

      notes << "#{scout.name}: #{name} is not in Scouts BSA Requirements 2025 — " \
               "get its requirements from scouting.org"
    end
  end

  def markers(scout, notes)
    (scout.merit_badges + scout.partials).select { |badge| badge[:marker] }.each do |badge|
      notes << "#{scout.name}: #{badge[:name]} carries a \"#{badge[:marker]}\" in the " \
               "report; the page legend defines that only for positions, so its " \
               "meaning here is unconfirmed"
    end
    scout.requirements.select { |req| req[:note] }.each do |req|
      notes << "#{scout.name}: #{req[:rank]} \"#{req[:label]}\" is annotated #{req[:note]}"
    end
    scout.leadership.reject { |post| post[:credited] }.each do |post|
      notes << "#{scout.name}: #{post[:position]} (#{post[:from]}–#{post[:to]}) is marked " \
               "as not credited toward rank"
    end
  end

  def gaps(scout, notes)
    notes << "#{scout.name}: no date of birth in the report" if scout.dob.nil?
    notes << "#{scout.name}: no date joined unit in the report" if scout.joined.nil?
    notes << "#{scout.name}: no leadership history in the report" if scout.leadership.empty?
    return unless current_gap?(scout)

    notes << "#{scout.name}: holds a current position (#{scout.position}) that is not " \
             "in the leadership list"
  end

  def current_gap?(scout)
    return false if scout.position.to_s.empty?

    scout.leadership.none? { |post| post[:current] && post[:position] == scout.position }
  end
end

# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------
module DB
  CHILD_TABLES = %w[completed_ranks requirements merit_badges partials
                    special_awards leadership].freeze

  module_function

  def handle
    @handle ||= begin
      FileUtils.mkdir_p(CACHE_DIR)
      db = SQLite3::Database.new(DB_PATH)
      db.results_as_hash = true
      db
    end
  end

  def query(sql, params = []) = handle.execute(sql, params)

  def ready? = File.exist?(DB_PATH)

  SCHEMA = <<~SQL
    CREATE TABLE IF NOT EXISTS scouts (
      key            TEXT PRIMARY KEY,       -- BSA ID, or "Last, First" when absent
      name           TEXT NOT NULL,
      last_name      TEXT NOT NULL,
      first_name     TEXT NOT NULL,
      bsa_id         TEXT NOT NULL DEFAULT '',
      patrol         TEXT NOT NULL DEFAULT '',
      email          TEXT NOT NULL DEFAULT '',
      phone          TEXT NOT NULL DEFAULT '',
      rank           TEXT NOT NULL DEFAULT '',
      rank_date      TEXT,
      position       TEXT NOT NULL DEFAULT '',
      dob            TEXT,
      age            INTEGER,
      joined         TEXT,
      nights_camping REAL,
      miles_hiking   REAL,
      service_hours  REAL,
      troop          TEXT NOT NULL DEFAULT '',
      report_date    TEXT NOT NULL,          -- printed on the report; what freshness means
      source_file    TEXT NOT NULL,
      imported_at    TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS completed_ranks (
      key TEXT NOT NULL, rank TEXT NOT NULL, rank_order INTEGER NOT NULL, earned_on TEXT
    );
    CREATE TABLE IF NOT EXISTS requirements (
      key TEXT NOT NULL, seq INTEGER NOT NULL, rank TEXT NOT NULL,
      req_id TEXT, label TEXT NOT NULL, kind TEXT NOT NULL,
      badge TEXT, badge_norm TEXT, eagle_required INTEGER NOT NULL DEFAULT 0,
      completed_on TEXT,                     -- NULL when the report prints __/__/__
      signed INTEGER NOT NULL DEFAULT 0,     -- ...which is what this distinguishes
      note TEXT
    );
    CREATE TABLE IF NOT EXISTS merit_badges (
      key TEXT NOT NULL, name TEXT NOT NULL, norm TEXT NOT NULL,
      eagle_required INTEGER NOT NULL DEFAULT 0, marker TEXT, earned_on TEXT
    );
    CREATE TABLE IF NOT EXISTS partials (
      key TEXT NOT NULL, name TEXT NOT NULL, norm TEXT NOT NULL,
      eagle_required INTEGER NOT NULL DEFAULT 0, marker TEXT,
      req_year INTEGER, percent INTEGER, start_date TEXT, last_progress TEXT,
      counselor TEXT, counselor_bsa_id TEXT, open_reqts TEXT
    );
    CREATE TABLE IF NOT EXISTS special_awards (
      key TEXT NOT NULL, name TEXT NOT NULL, earned_on TEXT
    );
    CREATE TABLE IF NOT EXISTS leadership (
      key TEXT NOT NULL, position TEXT NOT NULL, start_date TEXT, end_date TEXT,
      current INTEGER NOT NULL DEFAULT 0, credited INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS idx_req_key  ON requirements (key, rank);
    CREATE INDEX IF NOT EXISTS idx_mb_key   ON merit_badges (key);
    CREATE INDEX IF NOT EXISTS idx_part_key ON partials (key);
  SQL

  def init
    handle.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")

    # Unlike the calendar and inventory caches this one is not re-downloadable —
    # it is the only copy of an imported report — so a schema change drops the
    # tables and the reports have to be imported again, deliberately.
    if meta("schema_version") != SCHEMA_VERSION.to_s
      (CHILD_TABLES + ["scouts"]).each { |t| handle.execute("DROP TABLE IF EXISTS #{t}") }
    end

    handle.execute_batch(SCHEMA)
    set_meta("schema_version", SCHEMA_VERSION.to_s)
  end

  def meta(key)
    handle.get_first_value("SELECT value FROM meta WHERE key = ?", key)
  rescue SQLite3::SQLException
    nil
  end

  def set_meta(key, value)
    handle.execute("INSERT INTO meta (key, value) VALUES (?, ?) " \
                   "ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value.to_s])
  end

  # Dates come back out of SQLite in ISO form, not the report's M/D/YY, so this
  # is `Date.iso8601` and not `parse_date` — reading it with the report parser
  # returns nil for every row and silently disables the freshness guard.
  def stored_report_date(key)
    stored = handle.get_first_value("SELECT report_date FROM scouts WHERE key = ?", key)
    stored.to_s.empty? ? nil : Date.iso8601(stored)
  rescue Date::Error
    nil
  end

  def replace_scout(scout, parser, now)
    key = scout.key
    handle.transaction do
      CHILD_TABLES.each { |t| handle.execute("DELETE FROM #{t} WHERE key = ?", [key]) }
      handle.execute("DELETE FROM scouts WHERE key = ?", [key])
      insert_scout(key, scout, parser, now)
      insert_children(key, scout)
    end
  end

  SCOUT_COLUMNS = %w[key name last_name first_name bsa_id patrol email phone
                     rank rank_date position dob age joined
                     nights_camping miles_hiking service_hours
                     troop report_date source_file imported_at].freeze

  def insert_scout(key, scout, parser, now)
    values = [key, scout.name, scout.last_name, scout.first_name, scout.bsa_id.to_s,
              scout.patrol.to_s, scout.email.to_s, scout.phone.to_s,
              scout.rank.to_s, scout.rank_date&.to_s, scout.position.to_s,
              scout.dob&.to_s, scout.age, scout.joined&.to_s,
              scout.nights_camping, scout.miles_hiking, scout.service_hours,
              parser.troop.to_s, parser.report_date.to_s, File.basename(parser.source), now]
    placeholders = (["?"] * SCOUT_COLUMNS.size).join(", ")
    handle.execute("INSERT INTO scouts (#{SCOUT_COLUMNS.join(', ')}) VALUES (#{placeholders})",
                   values)
  end

  def insert_children(key, scout)
    insert_ranks(key, scout)
    insert_requirements(key, scout)
    insert_badges(key, scout)
    insert_awards(key, scout)
  end

  def insert_ranks(key, scout)
    scout.completed_ranks.each do |rank|
      handle.execute("INSERT INTO completed_ranks VALUES (?, ?, ?, ?)",
                     [key, rank[:rank], RANK_LADDER.index(rank[:rank]) || 99, rank[:on]&.to_s])
    end
  end

  def insert_requirements(key, scout)
    scout.requirements.each do |req|
      handle.execute("INSERT INTO requirements VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     [key, req[:seq], req[:rank], req[:req_id], req[:label], req[:kind],
                      req[:badge], req[:badge] && normalize(req[:badge]),
                      req[:eagle_required] ? 1 : 0, req[:on]&.to_s,
                      req[:signed] ? 1 : 0, req[:note]])
    end
  end

  def insert_badges(key, scout)
    scout.merit_badges.each do |badge|
      handle.execute("INSERT INTO merit_badges VALUES (?, ?, ?, ?, ?, ?)",
                     [key, badge[:name], normalize(badge[:name]),
                      badge[:eagle_required] ? 1 : 0, badge[:marker], badge[:on]&.to_s])
    end
    scout.partials.each do |part|
      handle.execute("INSERT INTO partials VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     [key, part[:name], normalize(part[:name]),
                      part[:eagle_required] ? 1 : 0, part[:marker], part[:year], part[:percent],
                      part[:start]&.to_s, part[:last_progress]&.to_s,
                      part[:counselor], part[:counselor_bsa_id], part[:open_reqts]])
    end
  end

  def insert_awards(key, scout)
    scout.awards.each do |award|
      handle.execute("INSERT INTO special_awards VALUES (?, ?, ?)",
                     [key, award[:name], award[:on]&.to_s])
    end
    scout.leadership.each do |post|
      handle.execute("INSERT INTO leadership VALUES (?, ?, ?, ?, ?, ?)",
                     [key, post[:position], post[:from]&.to_s, post[:to]&.to_s,
                      post[:current] ? 1 : 0, post[:credited] ? 1 : 0])
    end
  end
end

# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
module Render
  LIST_ROW = "%<name>-26s %<rank>-14s %<patrol>-20s %<report>-14s %<age>s"

  module_function

  def day(text) = text.to_s.empty? ? "—" : Date.parse(text.to_s).strftime("%b %-d, %Y")

  def age_of(row)
    return "" if row["report_date"].to_s.empty?

    days = (Date.today - Date.parse(row["report_date"])).to_i
    days <= 0 ? "today" : "#{days}d ago"
  end

  def list
    rows = DB.query("SELECT * FROM scouts ORDER BY last_name, first_name")
    return puts "nothing imported yet" if rows.empty?

    puts format(LIST_ROW, name: "SCOUT", rank: "RANK", patrol: "PATROL",
                          report: "REPORT", age: "AGE")
    rows.each do |row|
      puts format(LIST_ROW, name: row["name"], rank: row["rank"], patrol: row["patrol"],
                            report: day(row["report_date"]), age: age_of(row))
    end
    puts "\n#{rows.size} Scouts. Data is as of each Scout's own report date; " \
         "`stale` flags the old ones."
  end

  def stale(days)
    rows = DB.query("SELECT * FROM scouts ORDER BY report_date")
             .select { |row| (Date.today - Date.parse(row["report_date"])).to_i > days }
    return puts "every Scout's data is #{days} days old or newer" if rows.empty?

    puts "Older than #{days} days — re-run the Individual History report before planning:"
    rows.each do |row|
      puts format("  %-26s %s (%s)", row["name"], day(row["report_date"]), age_of(row))
    end
  end
end

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
module Command
  module_function

  # With no path, the newest Individual History report in reports/.
  def report_path(given)
    return given if given

    found = Dir.glob(File.join(REPORTS_DIR, "IndividualHistory*.{pdf,PDF}")).max
    found || die("no report given and no IndividualHistory*.pdf in #{REPORTS_DIR}")
  end

  def verify(path)
    parser = Parser.new(path)
    fails, notes = Verify.run(parser)
    puts "#{File.basename(path)}: #{parser.scouts.size} Scouts, report dated #{parser.report_date}"
    notes.each { |n| puts "  note: #{n}" }
    return puts "  verify: OK" if fails.empty?

    fails.each { |failure| warn "  FAIL: #{failure}" }
    warn "  verify: #{fails.size} problem(s) — nothing should be imported from this parse"
    exit 1
  end

  def import(path, force:)
    parser = Parser.new(path)
    fails, notes = Verify.run(parser)
    unless fails.empty?
      fails.each { |f| warn "  FAIL: #{f}" }
      die "#{File.basename(path)} did not verify; refusing to import #{fails.size} problem(s)"
    end

    DB.init
    now = Time.now.utc.iso8601
    imported, skipped = apply(parser, now, force)
    report(parser, imported, skipped, notes)
  end

  # Freshness is per Scout: an older report leaves a Scout alone rather than
  # rewinding them, because reports are run for one patrol as often as for the
  # whole troop and the newest file is not the newest data for everyone.
  def apply(parser, now, force)
    imported = []
    skipped  = []
    parser.scouts.each do |scout|
      held = DB.stored_report_date(scout.key)
      if !force && held && held > parser.report_date
        skipped << [scout, held]
      else
        DB.replace_scout(scout, parser, now)
        imported << scout
      end
    end
    [imported, skipped]
  end

  def report(parser, imported, skipped, notes)
    puts "#{File.basename(parser.source)} — report dated #{parser.report_date}, " \
         "Troop #{parser.troop}"
    imported.each do |s|
      puts format("  imported %-26s %-13s %2d badges, %d partials",
                  s.name, s.rank, s.merit_badges.size, s.partials.size)
    end
    skipped.each do |s, held|
      puts "  skipped  #{s.name} — already holds newer data (#{held}); --force overrides"
    end
    notes.each { |n| puts "  note: #{n}" }
    where = DB_PATH.sub("#{REPO_ROOT}/", "")
    puts "\n#{imported.size} imported, #{skipped.size} skipped. Database: #{where}"
  end

  def badges(path)
    Parser.new(path).scouts.flat_map(&:badge_names).uniq.sort.each { |n| puts n }
  end

  def notes(path)
    _fails, notes = Verify.run(Parser.new(path))
    return puts "nothing worth flagging in #{File.basename(path)}" if notes.empty?

    notes.each { |n| puts "- #{n}" }
  end
end

USAGE = <<~TEXT.freeze
  usage: ruby scripts/individual_history.rb COMMAND [REPORT.pdf] [options]

    verify [REPORT.pdf]        cross-check the parse — run this first
    import [REPORT.pdf]        verify, then store; --force to overwrite newer data
    list                       who has been imported, and how old each one's data is
    stale  [--days N]          whose data is too old to plan from (default #{STALE_DAYS})
    badges [REPORT.pdf]        badge names, one per line, for req.rb check
    notes  [REPORT.pdf]        only the things worth knowing before planning

  This skill loads; it does not answer questions. To read what was stored --
  one Scout's record, what a rank still needs, Eagle-required coverage,
  position-of-responsibility tenure -- use the `individual-history` skill:
      ruby ../individual-history/scripts/history.rb show "Last, First"

  With no REPORT.pdf the newest IndividualHistory*.pdf in reports/ is used.

  `badges` is meant to be piped, and exit 3 there means stop and read the banner:
      ruby scripts/individual_history.rb badges | ruby ../scout-req/scripts/req.rb check

  The database holds names, emails, and dates of birth of minors. It lives in
  this skill's .cache/, which .gitignore covers. Keep it there.
TEXT

args    = ARGV.dup
command = args.shift
force   = !args.delete("--force").nil?
days    = if (i = args.index("--days"))
            args.delete_at(i + 1).to_i.tap do
              args.delete_at(i)
            end
          else
            STALE_DAYS
          end
target = args.shift

case command
when "verify" then Command.verify(Command.report_path(target))
when "import" then Command.import(Command.report_path(target), force: force)
when "badges" then Command.badges(Command.report_path(target))
when "notes"  then Command.notes(Command.report_path(target))
when "list"   then DB.ready? ? Render.list : die("nothing imported yet — run `import` first")
when "stale"  then DB.ready? ? Render.stale(days) : die("nothing imported yet — run `import` first")
when "show", "json"
  die "`#{command}` moved to the individual-history skill:\n  " \
      "ruby ../individual-history/scripts/history.rb #{command} #{target || '"Last, First"'}"
else abort USAGE
end
