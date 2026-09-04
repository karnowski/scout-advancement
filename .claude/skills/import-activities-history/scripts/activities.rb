#!/usr/bin/env ruby
# frozen_string_literal: true

#
# import-activities-history — read a TroopMaster "Individual Participation"
# report (Activities > Individual Participation) into the SQLite cache the
# advancement-plan skills answer from.
#
#   ruby scripts/activities.rb verify [REPORT.pdf]
#   ruby scripts/activities.rb import [REPORT.pdf] [--force]
#   ruby scripts/activities.rb list
#   ruby scripts/activities.rb show   "Last, First"
#   ruby scripts/activities.rb json   ["Last, First"]
#   ruby scripts/activities.rb hours  "Last, First" [--type T,T] [--since D] [--until D]
#   ruby scripts/activities.rb stale  [--days N]
#   ruby scripts/activities.rb notes  [REPORT.pdf]
#
# With no REPORT.pdf, the newest `Activities-IndividualParticipation-*.pdf` in
# `reports/` is used. This script owns exactly one thing: turning the report
# into rows. **It does not know what a requirement asks for.** It will tell you
# that a Scout logged 3 hours of Serv Proj and 2 of Conservation after a date
# you name; it will not tell you that Life wants six with three conservation.
# That reading belongs to `generate-advancement-plan`, which holds the rank
# dates.
#
# --------------------------------------------------------------------------
# Facts about the report this script depends on
# --------------------------------------------------------------------------
#
# * **`-bbox-layout`, not `-layout`, and the reason is measured.** An event
#   title runs into the Type beside it with a single space, so the troop's own
#   rows read `Soil & Water Conservation MB MB Program` and `AUMC Food Relief
#   Fundraiser Serv Proj`. Under `-layout` there is no way to know the type is
#   `MB Program` and not `Conservation`; a split on runs of spaces silently
#   reads the tail of the title as the type. A `-layout` parse of the troop's
#   current report gets 12 rows wrong across 38 Scouts, and each one is a
#   plausible-looking activity filed under the wrong heading. Only the words'
#   own x coordinates separate them.
#
# * **A cell is claimed by the column its *words* start in, not by the cell
#   poppler emitted.** Ordinarily every table cell is its own `<line>`, but
#   where a title nearly touches its type poppler merges the two into one line
#   whose words still carry their true x: `AUMC@156 Food@183 Relief@204
#   Fundraiser@228 Serv@276 Proj@299`, with the Type column at 276. So rows are
#   built by bucketing *words* against the column origins, never by reading a
#   line element as a cell.
#
# * **The column origins are read off the table's own header row.** `Date`,
#   `Level`, `Event Title`, `Type`, `Amount`, `Location`, `Remarks` head every
#   page that carries activity rows — 55 of the 91 pages of the current report,
#   the other 36 being summary-only continuations. Nothing here hard-codes an x.
#
# * **A row can admit a line whose band sits *inside* the band already open.**
#   A Location that poppler reports starting 2.1pt below its own row belongs to
#   it; clustering on `yMin` alone drops it into a row of its own where nothing
#   claims it. Containment, not proximity — the same rule, for the same reason,
#   as `individual_history.rb`.
#
# * **The page header is a date range, and it starts with a date.** Every page
#   opens with `01/03/25 - 08/30/26 ( #Cabin Camp +Pitch Tent *Prior to Date
#   Joined Unit )`. A row filter that takes "starts with a date" as the mark of
#   an activity swallows it on all 91 pages and files the legend as an activity
#   of type `to Date Joined Unit`. Activity rows are therefore also required to
#   sit *below* the table header on their page.
#
# * **That range is a report filter, not the Scout's history.** It is the single
#   most dangerous fact here. Hours before `window_start` are simply absent, so
#   a Scout whose rank predates the window looks as though they have done less
#   than they have — and the error runs the safe-looking way, toward telling a
#   Scout to do work they have already done. The window is stored, and
#   `hours --since` **refuses** a date before it rather than answering short.
#
# * **The Amount column's unit is per type, and the report declares it.**
#   `Camping # / Nights`, `Conservation # / Hours`, `Serv Proj # / Hours`,
#   `Hiking # / Miles`, `Riding # / Miles`, and `# / Amount` — a bare count —
#   for everything else. The units are read out of the summary header rather
#   than hard-coded, because they are a property of the troop's own activity-type
#   setup and another troop's report will not match this one's.
#
# * **`+` is a pitch-tent night and `#` is a cabin night.** The legend on the
#   page header says so, and the distinction is not cosmetic: Camping merit
#   badge req. 9a counts nights under tent or approved shelter, and cabin nights
#   do not qualify. The marker is stored beside the type, never folded into it.
#   The current report carries only `+`, which is why the `#` path has to be
#   kept honest by the legend rather than by an example.
#
# * **The report carries its own tally, twice over, and it is the real
#   cross-check.** After the rows, each Scout gets a `# / Amount` block — a
#   count and a summed amount for all 28 activity types — and then a `# / Total`
#   block. `verify` re-derives both from the parsed rows and compares every
#   type: 1086 rows and 2128 declared figures on the current report, all of
#   which must agree.
#
# * **The `# / Total` denominator is per Scout, not per troop.** It reads
#   `5 of 29`, and the 29 is the number of camping events offered *to that
#   Scout* — the March 2026 crossover cohort all show `7`, the March 2025 cohort
#   `26`, everyone older `29`. It is opportunities available since they joined,
#   clipped to the window, and an Individual-level event of a Scout's own adds
#   to their own denominator and nobody else's. That is what makes the
#   percentage an attendance *rate* and comparable between Scouts; treating the
#   denominator as a troop-wide event count makes every new Scout look absent.
#
# * **The `# / Percent` block cannot be read positionally, and does not need
#   to be.** Where the denominator is zero it prints `0 /` with nothing after
#   the slash, so a run of them is ambiguous about how many values it holds —
#   13 headings over 8 readable values. It is skipped deliberately, because it
#   is exactly `count / offered` (verified to the point of rounding against
#   every unambiguous cell). `verify` re-derives it as a guard on the pairing
#   rather than storing it.
#
# * **Only the `# / Amount` and `# / Total` blocks align by position**, and they
#   do so exactly: 13 + 13 + 2 headings over 13 + 13 + 2 values, three sub-blocks
#   each, on all 228 blocks of the current report. Alignment is by order and
#   asserted, not by x proximity, which is what makes a dropped value a failure
#   rather than a quiet shift of every column after it.
#
# * **Continuation pages carry no name.** Unlike the Individual History report,
#   a Scout's second page repeats the title and the `Types:` list but never the
#   `Name:` header, so a page is attributed to whichever Scout was last opened.
#   The guard against a section migrating between Scouts is the block count:
#   every Scout must end with all 28 types in both summary blocks, and `verify`
#   fails if one does not.
#
# * **...and they repeat the `Types:` list, which must not be appended twice.**
#   A second sighting is claimed and discarded. Concatenating it instead gives a
#   Scout 55 types instead of 28, and every summary block then reads as covering
#   half of them — which looks exactly like a block that was missed.
#
# * **The `Types:` list wraps mid-name.** It runs over three rows and the break
#   falls *inside* a name as readily as between two: the troop's own report
#   breaks `Frost Days` after `Frost` and `Rain Day Event` after `Rain Day`.
#   Splitting each row on its own commas therefore invents types that do not
#   exist and loses two that do. The rows are joined first and split once.
#
# * **An event title can overhang the Type column.** The troop has one titled
#   "Luke & Evan - Food Bank volunteering /", whose trailing slash sits 9pt left
#   of the Type origin and lands in the Type bucket, producing a type of
#   `/ Serv Proj` that the summary has never heard of. The Type column holds
#   exactly one of the declared types, so the bucket is trimmed against that
#   list and the spill goes back on the title. Anything that still matches
#   nothing is left alone for the tally to catch — repairing an unrecognised
#   type into a plausible one is the failure this guard exists to prevent.
#
# * **A header label can be several words, and its leading words look like a
#   value.** `Position:` and `Date Joined Unit:` sit side by side, so when
#   `Unit:` closes the second label the words `Date Joined` are already banked
#   as the first one's value. A Scout with no position then reads as holding one
#   called "Date Joined", and a rank date comes out as `08/16/25 Date of`, which
#   parses to nothing and silently blanks the field the service-hours clip
#   depends on. The label's own words are taken back out of the buffer.
#
# * **The report prints no date of its own.** There is no "as of" line anywhere
#   in the 91 pages, so the report date is taken from the PDF's `CreationDate`,
#   which TroopMaster's generator stamps. The filename's date is used only to
#   cross-check it, and a disagreement is a note.
#
# * **`Level` is not always `Unit`.** The current report also carries `Troop`,
#   `Crew`, and `Individual`, the last being a Scout's own activity that nobody
#   else attended. A level nobody has seen yet is a note rather than a failure,
#   because the level does not change what a row means.
#
# * **An amount of 0 is data, not a missing value.** Advancement Days, MB
#   Programs, and Outings are almost all logged at 0 — the Scout attended and
#   the event measures nothing. Dropping zero-amount rows loses the attendance
#   that the `# / Total` block is counting, and the tally catches it at once.
#
# --------------------------------------------------------------------------
# Privacy
# --------------------------------------------------------------------------
#
# This report is a roster of minors — names, emails, phone numbers, dates of
# birth, BSA IDs, and where each of them was on a given weekend. The database
# lives under the skill's `.cache/`, which `.gitignore` covers. Nothing this
# script writes belongs in a tracked file, a commit message, or a PR
# description.

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "fileutils"
require "json"
require "open3"
require "time"

require "pdf-reader"
require "rexml/document"
require "sqlite3"

CACHE_DIR   = File.join(SKILL_DIR, ".cache")
DB_PATH     = File.join(CACHE_DIR, "activities-history.db")
REPORTS_DIR = File.join(REPO_ROOT, "reports")

SCHEMA_VERSION = 1
STALE_DAYS     = 30    # a plan built on data older than this wants a fresh report

# The activity table's columns, left to right. Origins are read off the header
# row on each page; this list only says which words head a column.
COLUMNS = ["Date", "Level", "Event Title", "Type", "Amount", "Location", "Remarks"].freeze

# How far left of a column's origin a word may start and still belong to it.
# Values are right-aligned under their headings — the Date heading sits at x=55
# and its values at x=47 — so the tolerance is a real column property, not slack.
COLUMN_SLACK = 10.0

# The units the summary header uses for the Amount column. `Amount` is a bare
# count; the rest are quantities that matter to a requirement.
UNITS = %w[Amount Nights Hours Miles].freeze

DATE_SRC = '\d{1,2}/\d{1,2}/\d{2}'
DATE_RE  = /\A#{DATE_SRC}\z/o

WINDOW_RE = /\A(#{DATE_SRC})\s*-\s*(#{DATE_SRC})\s*\((.*)\)\z/o
UNITS_RE  = %r{\A(?:#\s*/\s*\w+\s*)+\z}
TITLE_RE  = /\ATroop\s+(\S+)\s+Individual Participation\z/
PAGE_RE   = /\APage\s+\d+\z/

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# TroopMaster prints two-digit years throughout; every date in the report is
# this century.
def parse_date(text)
  m = text.to_s.strip.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{2})\z}) or return nil
  Date.new(2000 + m[3].to_i, m[1].to_i, m[2].to_i)
rescue Date::Error
  nil
end

def iso_date(text)
  Date.iso8601(text.to_s)
rescue ArgumentError, TypeError
  nil
end

# --------------------------------------------------------------------------
# extraction
# --------------------------------------------------------------------------
Word = Struct.new(:x, :text)

Row = Struct.new(:page, :y, :words) do
  def text  = words.map(&:text).join(" ")
  def first = words.first&.text.to_s

  # Bucket words against column origins. A word belongs to the rightmost column
  # whose origin it reaches; this is the whole reason for `-bbox-layout`, since
  # a merged title/type cell is one line whose words still sit in two columns.
  def columns(origins)
    buckets = words.each_with_object(Hash.new { |h, k| h[k] = [] }) do |word, out|
      col = origins.select { |x, _| word.x >= x - COLUMN_SLACK }.max_by(&:first)
      out[(col || origins.first)[1]] << word.text
    end
    buckets.transform_values { |parts| parts.join(" ") }
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
      words = line.elements.to_a("word").filter_map do |w|
        text = w.text&.strip
        Word.new(w.attributes["xMin"].to_f, text) unless text.nil? || text.empty?
      end
      next if words.empty?

      [line.attributes["yMin"].to_f, line.attributes["yMax"].to_f, words]
    end
    cluster(lines).map { |y, _ymax, words| Row.new(number, y, words.sort_by(&:x)) }
  end

  # A shared `yMin` within a couple of points makes a row. The exception is a
  # cell poppler reports starting just below its own row — a Location set 2.1pt
  # low — so a line whose band sits *inside* the band already open joins it too.
  def cluster(lines)
    lines.sort_by(&:first).each_with_object([]) do |(y, ymax, words), out|
      if out.last && (joins?(y, out.last[0]) || inside?(y, ymax, out.last))
        out.last[2].concat(words)
        out.last[1] = [out.last[1], ymax].max
      else
        out << [y, ymax, words]
      end
    end
  end

  def joins?(ymin, row_ymin) = (ymin - row_ymin).abs <= Y_TOLERANCE

  def inside?(ymin, ymax, row) = ymin < row[1] && ymax <= row[1] + Y_TOLERANCE
end

# --------------------------------------------------------------------------
# the parsed report
# --------------------------------------------------------------------------
Scout = Struct.new(
  :last_name, :first_name, :patrol, :email, :phone, :rank, :rank_date,
  :position, :dob, :age, :joined, :bsa_id, :types_text, :activities, :summary, :pages,
  keyword_init: true
) do
  def name = "#{last_name}, #{first_name}"

  # BSA ID is the real identity, and this is deliberately the same key
  # `individual_history.rb` builds, so the two caches join on it.
  def key = bsa_id.to_s.empty? ? name : bsa_id

  # The `Types:` list wraps across three rows and **wraps mid-name**: the
  # troop's own report breaks "Frost Days" after "Frost" and "Rain Day Event"
  # after "Rain Day". Splitting each row on its own commas therefore invents
  # types that do not exist and leaves the summary blocks one name long. The
  # rows are joined back into one string first, and only then split.
  def types = types_text.split(",").map(&:strip).reject(&:empty?)

  # Count and summed amount per type, re-derived from the rows the parser read.
  def tally
    activities.each_with_object(Hash.new { |h, k| h[k] = [0, 0.0] }) do |act, out|
      out[act[:type]][0] += 1
      out[act[:type]][1] += act[:amount]
    end
  end
end

# --------------------------------------------------------------------------
# One handler per shape of row. Kept as a mixin so the state machine — which
# row belongs to which section — stays separable from what each row means.
# --------------------------------------------------------------------------
module Sections
  HEADER_LABELS = ["Name:", "Patrol:", "Rank:", "Position:", "Email:", "Phone:",
                   "Date:", "Date of Birth:", "Age:", "Date Joined Unit:", "BSA ID:"].freeze

  KNOWN_LEVELS = %w[Unit Troop Crew Patrol District Council Individual].freeze

  private

  # Walk a row of `Label:` / value words. A label may carry its value inline
  # ("BSA ID: 141407367") or after it ("Date Joined Unit:", "12/01/24"), and a
  # value that is simply absent shifts nothing, because the words are assigned
  # to labels by which label they follow rather than by position.
  def labelled(row)
    out    = {}
    label  = nil
    buffer = []
    row.words.each do |word|
      found = starts_label(buffer + [word.text])
      next buffer << word.text if found.nil?

      # The label's own leading words are sitting in the buffer — "Date Joined"
      # is in there when "Unit:" closes "Date Joined Unit:" — and they are not
      # part of the value before it. Without this, a Scout with no Position
      # reads as holding one called "Date Joined", and a rank date comes out as
      # "08/16/25 Date of", which parses to nothing at all.
      keep = buffer.first([buffer.size - (found.split.size - 1), 0].max)
      out[label] = keep.join(" ") if label && !keep.empty?
      label  = found
      buffer = []
    end
    out[label] = buffer.join(" ") if label && !buffer.empty?
    out
  end

  # A label may be several words ("Date Joined Unit:"), so a word only closes
  # one when the tail of what has accumulated is exactly a known label.
  def starts_label(words)
    HEADER_LABELS.find { |label| words.last(label.split.size) == label.split }
  end

  def handle_header(row)
    fields = labelled(row)
    @unclaimed << row if fields.empty?
    identity(fields)
    standing(fields)
  end

  def identity(fields)
    if (printed = fields["Name:"])
      last, first = printed.split(",", 2).map(&:strip)
      @scout.last_name  ||= last
      @scout.first_name ||= first.to_s
    end
    @scout.patrol ||= fields["Patrol:"]
    @scout.email  ||= fields["Email:"]
    @scout.phone  ||= fields["Phone:"]
    @scout.bsa_id ||= fields["BSA ID:"]
  end

  def standing(fields)
    @scout.rank      ||= fields["Rank:"]
    @scout.rank_date ||= parse_date(fields["Date:"])
    @scout.position  ||= fields["Position:"]
    @scout.dob       ||= parse_date(fields["Date of Birth:"])
    @scout.age       ||= fields["Age:"]&.to_i
    @scout.joined    ||= parse_date(fields["Date Joined Unit:"])
  end

  # `Types:` wraps over three rows; the continuations have no label, so they are
  # appended to whatever the label opened. The text is accumulated whole and
  # split only once, because the wrap falls *inside* a name as often as between
  # two of them.
  def handle_types(row, labelled_row)
    text = labelled_row ? row.text.sub(/\ATypes:\s*/, "") : row.text
    @scout.types_text = [@scout.types_text, text].reject(&:empty?).join(" ")
  end

  def handle_activity(row)
    cells = row.columns(@origins)
    title, type, marker = split_type(cells["Event Title"].to_s, cells["Type"].to_s)
    amount = cells["Amount"].to_s
    @scout.activities << { on: parse_date(cells["Date"]), level: cells["Level"].to_s,
                           title: title, type: type, marker: marker,
                           amount: amount.to_f, amount_text: amount,
                           location: cells["Location"].to_s, remarks: cells["Remarks"].to_s,
                           page: row.page }
  end

  # The Type column holds exactly one of the types the report declared, so the
  # bucket is trimmed against that list rather than trusted whole. This matters
  # because an event title may end in a character that overhangs the column
  # boundary — the troop has one titled "Luke & Evan - Food Bank volunteering /",
  # whose trailing slash sits 9pt left of the Type origin and lands in the Type
  # bucket. Anything trimmed goes back on the title, where it came from; a type
  # that still matches nothing is left alone for the tally to catch, because a
  # type the summary never counts is a real misparse and must not be repaired
  # into looking fine.
  def split_type(title, bucket)
    marker = bucket[/[#+*]+\z/].to_s
    bare   = bucket.sub(/[#+*]+\z/, "").strip
    known  = @scout.types.select { |t| bare == t || bare.end_with?(" #{t}") }.max_by(&:size)
    return [title.strip, bare, marker] if known.nil?

    spill = bare[0...(bare.size - known.size)].strip
    [[title, spill].reject(&:empty?).join(" ").strip, known, marker]
  end

  # A summary block is three consecutive rows: the type names, the `# / Unit`
  # row, and the values. Alignment is by order and asserted, never by x, so a
  # dropped value fails rather than shifting every column after it.
  def handle_summary(names_row, units_row, values_row)
    units = units_row.text.scan(%r{#\s*/\s*(\w+)}).flatten
    kind  = summary_kind(units)
    return @unclaimed << units_row if kind.nil?
    # The Percent block is read for nothing: where the denominator is zero it
    # prints `0 /` and the row stops being positionally readable. It is exactly
    # count/offered, and `verify` re-derives it from those two.
    return if kind == :percent

    names  = split_types(names_row.text)
    values = scan_values(values_row&.text.to_s, kind)
    if names.size != units.size || names.size != values.size
      @broken << [@scout&.name, kind, names.size, units.size, values.size]
      return
    end

    names.each_with_index { |name, i| store_summary(name, kind, units[i], values[i]) }
  end

  def summary_kind(units)
    return :offered if units.all?("Total")
    return :percent if units.all?("Percent")
    return :amount  if units.all? { |u| UNITS.include?(u) }

    nil
  end

  def store_summary(name, kind, unit, value)
    entry = (@scout.summary[name] ||= {})
    case kind
    when :amount  then entry.merge!(unit: unit, count: value[0].to_i, amount: value[1].to_f)
    when :offered then entry[:offered] = value[1].to_f
    when :percent then entry[:percent] = value[1]
    end
  end

  # The names row is a run of type names with nothing but a space between them,
  # so it is split against the types the report itself declared.
  def split_types(text)
    out = []
    rest = text.strip
    until rest.empty?
      match = @scout.types.select { |t| rest == t || rest.start_with?("#{t} ") }.max_by(&:size)
      break if match.nil?

      out << match
      rest = rest[match.size..].to_s.strip
    end
    rest.empty? ? out : []
  end

  # Values read `5 / 8`, `0/0`, `1 / 2.5` in the Amount block and `5 of 29` in
  # the Total block. The Percent block prints `0 /` where the denominator is
  # zero, which is why it is never scanned positionally.
  def scan_values(text, kind)
    return [] if kind == :percent

    text.scan(%r{(\d+)\s*(?:/|of)\s*([\d.]+)})
  end
end

# The report prints no date of its own — there is no "as of" line anywhere in
# it — so the report date comes from the PDF's own generation stamp, and the
# filename is only ever a cross-check on that.
module Stamp
  module_function

  def pdf_date(path)
    stamp = PDF::Reader.new(path).info[:CreationDate].to_s
    m = stamp.match(/\AD:(\d{4})(\d{2})(\d{2})/) or return nil
    Date.new(m[1].to_i, m[2].to_i, m[3].to_i)
  rescue StandardError
    nil
  end

  def filename_date(path) = iso_date(File.basename(path)[/\d{4}-\d{2}-\d{2}/])
end

class Parser
  include Sections

  attr_reader :scouts, :source, :report_date, :troop, :window, :legend, :unclaimed,
              :broken, :filename_date

  def initialize(path)
    @source        = path
    @scouts        = []
    @unclaimed     = []
    @broken        = []
    @window        = nil
    @legend        = {}
    @troop         = nil
    @origins       = nil
    @report_date   = Stamp.pdf_date(path)
    @filename_date = Stamp.filename_date(path)
    Extract.pages(path).each { |rows| walk(rows) }
  end

  private

  # One page at a time, because every lookahead this parser makes — a summary
  # block's three rows — is within a page, and the page is also what carries the
  # column origins.
  def walk(rows)
    @origins = nil
    i = 0
    i += consume(rows, i) while i < rows.size
  end

  # Each handler returns the number of rows it consumed, or nil if the row was
  # not its shape. Only `summary` ever consumes more than one.
  def consume(rows, index)
    row = rows[index]
    chrome(row) || header(row) || types(row) || table_header(row) ||
      activity(row) || summary(rows, index) || keep_unclaimed(row)
  end

  # The page furniture: the window/legend line, the title, the page number.
  def chrome(row)
    text = row.text
    if (m = WINDOW_RE.match(text))
      @window ||= [parse_date(m[1]), parse_date(m[2])]
      @legend = m[3].scan(/([#+*])([^#+*]+)/).to_h { |mark, meaning| [mark, meaning.strip] }
      return 1
    end
    @troop ||= Regexp.last_match(1) if TITLE_RE.match(text)
    1 if TITLE_RE.match?(text) || PAGE_RE.match?(text)
  end

  # The whole label, not its first word: "Date of Birth:" and "Date Joined Unit:"
  # both begin with "Date", and so does the activity table's own header row.
  def header(row)
    return nil unless HEADER_LABELS.any? { |l| row.text.start_with?(l) }

    open_scout if row.first == "Name:"
    return nil if @scout.nil?

    @scout.pages << row.page
    handle_header(row)
    1
  end

  def open_scout
    @scout = Scout.new(types_text: "", activities: [], summary: {}, pages: [])
    @scouts << @scout
    @in_types = nil
  end

  # Every page of a Scout's section repeats the `Types:` list, continuation
  # pages included, so a second sighting is claimed and thrown away. Appending
  # it instead doubles the list, and the summary blocks then read as covering
  # half the types they do.
  def types(row)
    if row.first == "Types:"
      @in_types = @scout && @scout.types_text.empty? ? :open : :repeat
      handle_types(row, true) if @in_types == :open
      return 1
    end
    return nil unless @in_types && @scout && continues_types?(row)

    handle_types(row, false) if @in_types == :open
    1
  end

  # A `Types:` continuation is a bare run of comma-separated names. It is only
  # ever the two rows after the label, and it always ends in a name the report
  # declared, so anything else closes the section rather than being swallowed.
  def continues_types?(row)
    return false unless row.text.include?(",")

    row.text.split(",").map(&:strip).all? { |part| part.match?(/\A[\w &-]+\z/) }
  end

  def table_header(row)
    return nil unless row.text.start_with?("Date Level Event Title Type Amount")

    @in_types = nil
    @origins  = column_origins(row)
    @table_y  = row.y
    1
  end

  def column_origins(row)
    found = COLUMNS.filter_map do |column|
      word = row.words.find { |w| w.text == column.split.first }
      [word.x, column] if word
    end
    found.sort
  end

  # An activity row starts with a date *below the table header* — the page's own
  # window line starts with a date too, and sits above it.
  def activity(row)
    return nil if @origins.nil? || @table_y.nil? || row.y <= @table_y
    return nil unless DATE_RE.match?(row.first) && @scout

    handle_activity(row)
    1
  end

  def summary(rows, index)
    return nil unless UNITS_RE.match?(rows[index].text) && index.positive? && @scout

    values = rows[(index + 1)..(index + 2)].to_a
                                           .find { |r| r.text.match?(%r{\d\s*(?:/|of)}) }
    handle_summary(rows[index - 1], rows[index], values)
    reclaim(rows[index - 1])
    values ? (rows.index(values) - index + 1) : 1
  end

  # A summary block's names row is only recognisable from the row *after* it, by
  # which time the walk has already filed it as unread. Take it back.
  def reclaim(row)
    @unclaimed.reject! { |seen| seen.equal?(row) }
  end

  def keep_unclaimed(row)
    @unclaimed << row
    1
  end
end

# --------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------
module Verify
  module_function

  def run(parser)
    fails = []
    notes = []
    report(parser, fails, notes)
    parser.broken.each do |who, kind, names, units, values|
      fails << "#{who}: #{kind} summary block has #{names} names, #{units} units, " \
               "#{values} values — they must align by position"
    end
    parser.unclaimed.each do |row|
      fails << "p#{row.page}: unread text #{row.text.inspect}"
    end
    duplicates(parser, fails)
    parser.scouts.each { |scout| checks(scout, parser, fails, notes) }
    [fails, notes]
  end

  def report(parser, fails, notes)
    fails << "no Scout found in the report" if parser.scouts.empty?
    fails << "no date range on any page" if parser.window.nil? || parser.window.any?(&:nil?)
    if parser.report_date.nil?
      fails << "the PDF carries no CreationDate, and the report prints no date of its own"
    elsif parser.filename_date && (parser.filename_date - parser.report_date).abs > 1
      notes << "filename says #{parser.filename_date}, the PDF was generated " \
               "#{parser.report_date} — using the PDF's date"
    end
    legend(parser, notes)
  end

  def legend(parser, notes)
    missing = %w[# + *] - parser.legend.keys
    return if missing.empty?

    notes << "the page legend does not define #{missing.join(' ')} — " \
             "marker meanings may have changed"
  end

  def duplicates(parser, fails)
    parser.scouts.group_by(&:key).each do |key, group|
      next unless group.size > 1

      fails << "#{group.first.name}: appears #{group.size} times under the same id (#{key})"
    end
  end

  def checks(scout, parser, fails, notes)
    fails << "#{scout.name}: no BSA ID" if scout.bsa_id.to_s.empty?
    tally(scout, fails)
    coverage(scout, fails)
    percent(scout, fails)
    dates(scout, parser, fails)
    amounts(scout, fails, notes)
    levels(scout, notes)
    markers(scout, parser, notes)
  end

  # The cross-check the whole parse rests on: the report's own per-type count
  # and summed amount, re-derived from the rows that were read.
  def tally(scout, fails)
    parsed = scout.tally
    scout.summary.each do |type, entry|
      next if entry[:count].nil?

      count, amount = parsed.fetch(type, [0, 0.0])
      next if count == entry[:count] && (amount - entry[:amount]).abs < 0.005

      fails << "#{scout.name}: #{type} — report declares #{entry[:count]}/#{entry[:amount]}, " \
               "parsed #{count}/#{amount}"
    end
    stray = parsed.keys - scout.summary.keys
    return if stray.empty?

    fails << "#{scout.name}: rows of type #{stray.join(', ')}, which the summary never counts"
  end

  # Continuation pages carry no name, so a section migrating between Scouts is
  # only visible as a Scout whose summary blocks came out short.
  def coverage(scout, fails)
    if scout.types.empty?
      return fails << "#{scout.name}: no \"Types:\" line, so nothing says what the " \
                      "summary columns are"
    end

    %i[count offered].each do |field|
      got = scout.summary.count { |_, entry| entry.key?(field) }
      next if got == scout.types.size

      fails << "#{scout.name}: #{got} of #{scout.types.size} types carry a #{field} — " \
               "a summary block was missed or read onto the wrong Scout"
    end
  end

  # The skipped Percent block, re-derived. This is a guard on the count/offered
  # pairing rather than a value anyone stores: if the two blocks were read onto
  # different types, the percentages stop reproducing.
  def percent(scout, fails)
    scout.summary.each do |type, entry|
      offered = entry[:offered].to_f
      next if entry[:count].nil? || offered.zero?
      next if entry[:count] <= offered

      fails << "#{scout.name}: #{type} — attended #{entry[:count]} of #{offered.to_i} offered"
    end
  end

  def dates(scout, parser, fails)
    from, to = parser.window
    return if from.nil? || to.nil?

    scout.activities.each do |act|
      if act[:on].nil?
        fails << "#{scout.name}: an activity on p#{act[:page]} has no readable date"
      elsif act[:on] < from || act[:on] > to
        fails << "#{scout.name}: #{act[:title].inspect} on #{act[:on]} is outside the " \
                 "report's own #{from}..#{to} window"
      end
    end
  end

  def amounts(scout, fails, notes)
    scout.activities.each do |act|
      unless act[:amount_text].match?(/\A-?\d+(\.\d+)?\z/)
        fails << "#{scout.name}: #{act[:title].inspect} has an unreadable amount " \
                 "#{act[:amount_text].inspect}"
      end
      next unless act[:amount].negative?

      notes << "#{scout.name}: #{act[:title].inspect} carries a negative amount"
    end
  end

  def levels(scout, notes)
    unknown = scout.activities.map { |a| a[:level] }.uniq - Sections::KNOWN_LEVELS
    return if unknown.empty?

    notes << "#{scout.name}: activity level #{unknown.join(', ')} is new to this parser"
  end

  def markers(scout, parser, notes)
    seen = scout.activities.map { |a| a[:marker] }.uniq.reject(&:empty?)
    unknown = seen.flat_map(&:chars).uniq - parser.legend.keys
    return if unknown.empty?

    notes << "#{scout.name}: marker #{unknown.join(' ')} is not in the page legend"
  end
end

# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------
module DB
  CHILD_TABLES = %w[activities totals].freeze

  SCHEMA = <<~SQL
    CREATE TABLE IF NOT EXISTS scouts (
      key           TEXT PRIMARY KEY,       -- BSA ID, or "Last, First" when absent;
      name          TEXT NOT NULL,          -- the same key individual-history builds
      last_name     TEXT NOT NULL,
      first_name    TEXT NOT NULL,
      bsa_id        TEXT NOT NULL DEFAULT '',
      patrol        TEXT NOT NULL DEFAULT '',
      email         TEXT NOT NULL DEFAULT '',
      phone         TEXT NOT NULL DEFAULT '',
      rank          TEXT NOT NULL DEFAULT '',
      rank_date     TEXT,
      position      TEXT NOT NULL DEFAULT '',
      dob           TEXT,
      age           INTEGER,
      joined        TEXT,
      window_start  TEXT NOT NULL,          -- the report's own filter, not the Scout's
      window_end    TEXT NOT NULL,          -- history: hours outside it are absent
      troop         TEXT NOT NULL DEFAULT '',
      report_date   TEXT NOT NULL,
      source_file   TEXT NOT NULL,
      imported_at   TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS activities (
      key      TEXT NOT NULL, seq INTEGER NOT NULL,
      on_date  TEXT NOT NULL,
      level    TEXT NOT NULL DEFAULT '',
      title    TEXT NOT NULL DEFAULT '',
      type     TEXT NOT NULL,
      marker   TEXT NOT NULL DEFAULT '',    -- '+' pitch tent, '#' cabin; see the legend
      amount   REAL NOT NULL DEFAULT 0,     -- nights, hours, or miles per `totals.unit`
      location TEXT NOT NULL DEFAULT '',
      remarks  TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS totals (
      key     TEXT NOT NULL, type TEXT NOT NULL,
      unit    TEXT NOT NULL,                -- Amount | Nights | Hours | Miles
      count   INTEGER NOT NULL DEFAULT 0,
      amount  REAL NOT NULL DEFAULT 0,
      offered REAL NOT NULL DEFAULT 0       -- opportunities this Scout had, not the troop
    );
    CREATE INDEX IF NOT EXISTS idx_act_key   ON activities (key, type, on_date);
    CREATE INDEX IF NOT EXISTS idx_total_key ON totals (key);
  SQL

  module_function

  def handle
    @handle ||= begin
      FileUtils.mkdir_p(CACHE_DIR)
      SQLite3::Database.new(DB_PATH).tap { |db| db.results_as_hash = true }
    end
  end

  def init
    handle.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")

    # Like the Individual History cache this one is not re-downloadable — it is
    # the only copy of an imported report — so a schema change drops the tables
    # and the reports have to be imported again, deliberately.
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

  def query(sql, args = [])
    handle.execute(sql, args)
  rescue SQLite3::SQLException => e
    die "the cache is not readable (#{e.message}). Run `import` first."
  end

  # Dates come back out of SQLite in ISO form, not the report's M/D/YY, so this
  # is `Date.iso8601` and not `parse_date`.
  def stored_report_date(key)
    stored = handle.get_first_value("SELECT report_date FROM scouts WHERE key = ?", key)
    iso_date(stored)
  end

  def resolve(target)
    rows = query("SELECT * FROM scouts")
    die "nothing imported yet — run `import` first" if rows.empty?

    matches = Match.find(rows, target)
    die "no Scout in the cache matches #{target.inspect}" if matches.empty?
    if matches.size > 1
      die "#{target.inspect} matches #{matches.map { |r| r['name'] }.join(', ')} — be specific"
    end

    matches.first
  end

  def replace_scout(scout, parser, now)
    key = scout.key
    handle.transaction do
      CHILD_TABLES.each { |t| handle.execute("DELETE FROM #{t} WHERE key = ?", [key]) }
      handle.execute("DELETE FROM scouts WHERE key = ?", [key])
      insert_scout(key, scout, parser, now)
      insert_activities(key, scout)
      insert_totals(key, scout)
    end
  end

  SCOUT_COLUMNS = %w[key name last_name first_name bsa_id patrol email phone
                     rank rank_date position dob age joined
                     window_start window_end troop report_date source_file
                     imported_at].freeze

  def insert_scout(key, scout, parser, now)
    placeholders = (["?"] * SCOUT_COLUMNS.size).join(", ")
    handle.execute("INSERT INTO scouts (#{SCOUT_COLUMNS.join(', ')}) VALUES (#{placeholders})",
                   [key, *scout_values(scout), *source_values(parser, now)])
  end

  def scout_values(scout)
    [scout.name, scout.last_name, scout.first_name, scout.bsa_id.to_s,
     scout.patrol.to_s, scout.email.to_s, scout.phone.to_s,
     scout.rank.to_s, scout.rank_date&.to_s, scout.position.to_s,
     scout.dob&.to_s, scout.age, scout.joined&.to_s]
  end

  def source_values(parser, now)
    [parser.window[0].to_s, parser.window[1].to_s, parser.troop.to_s,
     parser.report_date.to_s, File.basename(parser.source), now]
  end

  def insert_activities(key, scout)
    scout.activities.each_with_index do |act, i|
      handle.execute("INSERT INTO activities VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     [key, i, act[:on].to_s, act[:level], act[:title], act[:type],
                      act[:marker], act[:amount], act[:location], act[:remarks]])
    end
  end

  def insert_totals(key, scout)
    scout.summary.each do |type, entry|
      handle.execute("INSERT INTO totals VALUES (?, ?, ?, ?, ?, ?)",
                     [key, type, entry[:unit].to_s, entry[:count].to_i,
                      entry[:amount].to_f, entry[:offered].to_f])
    end
  end
end

# Name matching, identical in spirit to `history.rb`: "Last, First", "First
# Last", a last name, or a first name, and an ambiguous name is an error.
module Match
  module_function

  def find(rows, target)
    wanted = squash(target)
    exact  = rows.select { |r| squash(r["name"]) == wanted }
    return exact unless exact.empty?

    rows.select do |r|
      [squash("#{r['first_name']} #{r['last_name']}"),
       squash(r["last_name"]), squash(r["first_name"])].include?(wanted)
    end
  end

  def squash(text) = text.to_s.downcase.gsub(/[^a-z]+/, " ").strip
end

# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
module Render
  LIST_ROW = "%<name>-24s %<rank>-13s %<patrol>-20s %<acts>5s %<report>-14s %<age>s"

  module_function

  def day(text)
    date = iso_date(text)
    date ? date.strftime("%b %-d, %Y") : "—"
  end

  def age_of(row)
    date = iso_date(row["report_date"]) or return ""
    days = (Date.today - date).to_i
    days <= 0 ? "today" : "#{days}d ago"
  end

  def number(value)
    value == value.to_i ? value.to_i.to_s : format("%.1f", value)
  end

  # `Amount` is the report's word for a bare count, so it names no unit at all.
  def unit(name, amount)
    return "" if name.to_s.empty? || name == "Amount"

    amount == 1 ? name.downcase.sub(/s\z/, "") : name.downcase
  end

  def list
    rows = DB.query(<<~SQL)
      SELECT s.*, COUNT(a.key) AS acts FROM scouts s
      LEFT JOIN activities a ON a.key = s.key
      GROUP BY s.key ORDER BY s.last_name, s.first_name
    SQL
    return puts "nothing imported yet" if rows.empty?

    puts format(LIST_ROW, name: "SCOUT", rank: "RANK", patrol: "PATROL",
                          acts: "ACTS", report: "REPORT", age: "AGE")
    rows.each do |row|
      puts format(LIST_ROW, name: row["name"], rank: row["rank"], patrol: row["patrol"],
                            acts: row["acts"], report: day(row["report_date"]),
                            age: age_of(row))
    end
    window = rows.first
    puts "\n#{rows.size} Scouts, activity logged #{day(window['window_start'])} to " \
         "#{day(window['window_end'])}."
    puts "That range is the report's filter, not each Scout's whole history."
  end

  def show(row)
    key = row["key"]
    puts "#{row['name']} — #{row['rank']}#{rank_on(row)}"
    puts format("  Patrol %s   Age %s   Joined %s   %s",
                blank(row["patrol"]), row["age"] || "—", day(row["joined"]),
                blank(row["position"]))
    puts format("  Report %s (%s)   window %s .. %s", day(row["report_date"]), age_of(row),
                day(row["window_start"]), day(row["window_end"]))
    puts
    totals(key)
    puts
    activities(key)
  end

  def rank_on(row)
    row["rank_date"].to_s.empty? ? "" : ", earned #{day(row['rank_date'])}"
  end

  def blank(text) = text.to_s.empty? ? "—" : text

  def totals(key)
    rows = DB.query("SELECT * FROM totals WHERE key = ? AND (count > 0 OR offered > 0) " \
                    "ORDER BY type", [key])
    return puts "  no activity types carry a count" if rows.empty?

    puts "  PARTICIPATION — attended of offered, and the amount logged"
    rows.each do |row|
      rate = if row["offered"].positive?
               format("%3d%%",
                      row["count"] * 100 / row["offered"])
             else
               "  —"
             end
      unit = row["unit"] == "Amount" ? "" : " #{row['unit'].downcase}"
      puts format("    %<type>-18s %<went>2d of %<offered>-3d %<rate>s   %<amount>s%<unit>s",
                  type: row["type"], went: row["count"], offered: row["offered"],
                  rate: rate, amount: number(row["amount"]), unit: unit)
    end
  end

  def activities(key)
    rows = DB.query("SELECT * FROM activities WHERE key = ? ORDER BY on_date, seq", [key])
    return puts "  no activities logged in the report's window" if rows.empty?

    puts "  ACTIVITIES — #{rows.size} in the window"
    rows.each do |row|
      puts format("    %<on>s  %<level>-11s %<title>-30s %<type>-16s %<amount>6s  %<where>s",
                  on: day(row["on_date"]), level: row["level"], title: row["title"][0, 30],
                  type: "#{row['type']}#{row['marker']}", amount: number(row["amount"]),
                  where: row["location"][0, 28])
    end
  end

  def stale(days)
    rows = DB.query("SELECT * FROM scouts ORDER BY report_date").select do |row|
      date = iso_date(row["report_date"])
      date && (Date.today - date).to_i > days
    end
    return puts "every Scout's data is #{days} days old or newer" if rows.empty?

    puts "Older than #{days} days — re-run the Individual Participation report before planning:"
    rows.each do |row|
      puts format("  %-24s %s (%s)", row["name"], day(row["report_date"]), age_of(row))
    end
  end
end

# --------------------------------------------------------------------------
# neutral arithmetic over what was stored
#
# This is where the line sits. `hours` sums rows between two dates for the types
# it is given. It does not know that Life wants six hours with three of them
# conservation, and it must not learn: the rank dates live in
# `individual-history`, and the requirement text lives in `scout-req`.
# --------------------------------------------------------------------------
module Sum
  module_function

  def hours(row, types, since, upto)
    key = row["key"]
    window = [iso_date(row["window_start"]), iso_date(row["window_end"])]
    guard(row, since, window)
    from = [since, window[0]].compact.max
    to   = [upto, window[1]].compact.min
    rows = DB.query("SELECT * FROM activities WHERE key = ? AND on_date >= ? AND on_date <= ? " \
                    "ORDER BY on_date, seq", [key, from.to_s, to.to_s])
    rows = rows.select { |r| types.include?(r["type"]) } unless types.empty?
    { from: from, to: to, rows: rows }
  end

  # The window is a report filter, so a question asked about a date before it
  # cannot be answered short without lying. Refuse instead.
  def guard(row, since, window)
    return if since.nil? || window[0].nil? || since >= window[0]

    die "#{row['name']}'s activity was only reported from #{window[0]}, and you asked " \
        "from #{since}. Anything earlier is missing from this report, so the answer " \
        "would be too low. Re-run Individual Participation with a wider date range."
  end

  def print(row, result, types)
    scope = types.empty? ? "all types" : types.join(", ")
    puts "#{row['name']} — #{scope}, #{result[:from]} to #{result[:to]}"
    by_type(result[:rows]).each do |type, (count, amount, unit)|
      puts format("  %-18s %2d  %6s %s", type, count, Render.number(amount),
                  Render.unit(unit, amount))
    end
    puts "  nothing logged" if result[:rows].empty?
    result[:rows].each do |r|
      puts format("    %s  %-32s %-16s %s", Render.day(r["on_date"]), r["title"][0, 32],
                  "#{r['type']}#{r['marker']}", Render.number(r["amount"]))
    end
  end

  def by_type(rows)
    units = DB.query("SELECT type, unit FROM totals").to_h { |r| [r["type"], r["unit"]] }
    rows.each_with_object({}) do |row, out|
      entry = (out[row["type"]] ||= [0, 0.0, units.fetch(row["type"], "Amount")])
      entry[0] += 1
      entry[1] += row["amount"]
    end
  end

  def json(row, result)
    { scout: row.slice("name", "last_name", "first_name", "bsa_id", "rank", "rank_date",
                       "patrol", "joined", "report_date", "window_start", "window_end"),
      from: result[:from].to_s, to: result[:to].to_s,
      totals: by_type(result[:rows]).transform_values do |count, amount, unit|
        { count: count, amount: amount, unit: unit }
      end,
      activities: result[:rows].map do |r|
        r.slice("on_date", "level", "title", "type",
                "marker", "amount", "location", "remarks")
      end }
  end
end

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
module Command
  module_function

  # With no path, the newest Individual Participation report in reports/.
  def report_path(given)
    return given if given

    found = Dir.glob(File.join(REPORTS_DIR, "Activities-IndividualParticipation*.{pdf,PDF}")).max
    found || die("no report given and no Activities-IndividualParticipation*.pdf " \
                 "in #{REPORTS_DIR}")
  end

  def verify(path)
    parser = Parser.new(path)
    fails, notes = Verify.run(parser)
    puts "#{File.basename(path)}: #{parser.scouts.size} Scouts, " \
         "#{parser.scouts.sum { |s| s.activities.size }} activities, " \
         "generated #{parser.report_date}, window #{window(parser)}"
    notes.each { |n| puts "  note: #{n}" }
    return puts "  verify: OK" if fails.empty?

    fails.first(40).each { |failure| warn "  FAIL: #{failure}" }
    warn "  ... and #{fails.size - 40} more" if fails.size > 40
    warn "  verify: #{fails.size} problem(s) — nothing should be imported from this parse"
    exit 1
  end

  def window(parser)
    parser.window ? parser.window.join("..") : "unknown"
  end

  def import(path, force:)
    parser = Parser.new(path)
    fails, notes = Verify.run(parser)
    unless fails.empty?
      fails.first(20).each { |f| warn "  FAIL: #{f}" }
      die "#{File.basename(path)} did not verify; refusing to import #{fails.size} problem(s)"
    end

    DB.init
    imported, skipped = apply(parser, Time.now.utc.iso8601, force)
    report(parser, imported, skipped, notes)
  end

  # Freshness is per Scout, the same rule as the Individual History import: an
  # older report leaves a Scout alone rather than rewinding them, because a
  # report run for one patrol is not the newest data for everyone.
  def apply(parser, now, force)
    imported = []
    skipped  = []
    parser.scouts.each do |scout|
      held = DB.stored_report_date(scout.key)
      if !force && held && parser.report_date && held > parser.report_date
        skipped << [scout, held]
      else
        DB.replace_scout(scout, parser, now)
        imported << scout
      end
    end
    [imported, skipped]
  end

  def report(parser, imported, skipped, notes)
    puts "#{File.basename(parser.source)} — generated #{parser.report_date}, " \
         "Troop #{parser.troop}, window #{window(parser)}"
    imported.each do |s|
      puts format("  imported %-24s %-13s %3d activities", s.name, s.rank, s.activities.size)
    end
    skipped.each do |s, held|
      puts "  skipped  #{s.name} — already holds newer data (#{held}); --force overrides"
    end
    notes.each { |n| puts "  note: #{n}" }
    puts "\n#{imported.size} imported, #{skipped.size} skipped. " \
         "Database: #{DB_PATH.sub("#{REPO_ROOT}/", '')}"
    puts "Activity outside #{window(parser)} is not in this report and cannot be counted."
  end

  def notes(path)
    _fails, notes = Verify.run(Parser.new(path))
    return puts "nothing worth flagging in #{File.basename(path)}" if notes.empty?

    notes.each { |n| puts "- #{n}" }
  end

  def json(target)
    rows = target ? [DB.resolve(target)] : DB.query("SELECT * FROM scouts ORDER BY last_name")
    out = rows.map do |row|
      Sum.json(row, Sum.hours(row, [], nil, nil))
    end
    puts JSON.pretty_generate(target ? out.first : out)
  end

  def hours(target, types, since, upto)
    row = DB.resolve(target)
    Sum.print(row, Sum.hours(row, types, since, upto), types)
  end
end

USAGE = <<~TEXT.freeze
  usage: ruby scripts/activities.rb COMMAND [REPORT.pdf | NAME] [options]

    verify [REPORT.pdf]        cross-check the parse against the report's own
                               per-type tallies — run this first
    import [REPORT.pdf]        verify, then store; --force to overwrite newer data
    list                       who has been imported, and how old each one's data is
    show   NAME                one Scout's participation totals and activity log
    json   [NAME]              the same, machine-readable; everyone if no name
    hours  NAME [options]      sum the stored rows between two dates
    stale  [--days N]          whose data is too old to plan from (default #{STALE_DAYS})
    notes  [REPORT.pdf]        only the things worth knowing before planning

  `hours` options:
    --type "Serv Proj,Conservation"   only these activity types (default: all)
    --since YYYY-MM-DD                from this date (default: the report's window)
    --until YYYY-MM-DD                to this date (default: the report's window)

  This skill loads and sums; it decides nothing. It will tell you a Scout logged
  3 hours of Serv Proj and 2 of Conservation since a date you name. It does not
  know that Star wants six hours, or that Life wants three of them conservation,
  or when the Scout earned the rank those hours must follow -- that reading
  belongs to `generate-advancement-plan`, and the rank dates to
  `individual-history`.

  With no REPORT.pdf the newest Activities-IndividualParticipation*.pdf in
  reports/ is used.

  The report's date range is a filter, not a Scout's whole history. `hours`
  refuses a --since before it rather than answering short.

  The database holds names, emails, dates of birth, and where minors were on
  given weekends. It lives in this skill's .cache/, which .gitignore covers.
  Keep it there.
TEXT

args    = ARGV.dup
command = args.shift
force   = !args.delete("--force").nil?

def take(args, flag)
  i = args.index(flag) or return nil
  args.delete_at(i + 1).tap { args.delete_at(i) }
end

days   = (take(args, "--days") || STALE_DAYS).to_i
types  = take(args, "--type").to_s.split(",").map(&:strip).reject(&:empty?)
since  = take(args, "--since")
upto   = take(args, "--until")
target = args.shift

[["--since", since], ["--until", upto]].each do |flag, value|
  next if value.nil? || iso_date(value)

  die "#{flag} #{value.inspect} is not a YYYY-MM-DD date"
end

case command
when "verify" then Command.verify(Command.report_path(target))
when "import" then Command.import(Command.report_path(target), force: force)
when "notes"  then Command.notes(Command.report_path(target))
when "list"   then Render.list
when "stale"  then Render.stale(days)
when "show"   then Render.show(DB.resolve(target || die("show needs a Scout's name")))
when "json"   then Command.json(target)
when "hours"
  Command.hours(target || die("hours needs a Scout's name"), types,
                iso_date(since), iso_date(upto))
else
  puts USAGE
  exit(command.nil? ? 0 : 1)
end
