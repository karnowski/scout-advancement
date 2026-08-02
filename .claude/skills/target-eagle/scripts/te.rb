#!/usr/bin/env ruby
# frozen_string_literal: true

#
# target-eagle — read a TroopMaster "Target Eagle" report plus the matching
# "Partial Merit Badges List".
#
# The Target Eagle report is a grid of rotated headers and one-glyph marks laid
# out in three rank blocks (Star, Life, Eagle). Plain `pdftotext` interleaves the
# blocks, so this rebuilds the grid from word bounding boxes and then checks
# itself against the rank printed after each Scout's name before reporting
# anything.
#
#   ruby scripts/te.rb verify   REPORT.pdf [--partials PARTIALS.pdf]
#   ruby scripts/te.rb summary  REPORT.pdf [--partials PARTIALS.pdf]
#   ruby scripts/te.rb gaps     REPORT.pdf [--scout NAME]
#   ruby scripts/te.rb partials REPORT.pdf --partials PARTIALS.pdf [--min-pct N]
#   ruby scripts/te.rb batch    REPORT.pdf --partials PARTIALS.pdf [--min N]
#   ruby scripts/te.rb clocks   REPORT.pdf --partials PARTIALS.pdf
#   ruby scripts/te.rb json     REPORT.pdf [--partials PARTIALS.pdf]
#
# Needs `pdftotext` (poppler): brew install poppler

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "json"
require "open3"
require "tempfile"

# --------------------------------------------------------------------------
# the three rank blocks, in printed order
#
# Column names come out of the rotated headers intact, but "Merit Badge" repeats
# and carries no number, so identity is positional. The parser asserts the whole
# 42-column sequence before it trusts a single mark.
#
# Slot counts trace to Scouts BSA Requirements 2025: Star req. 3 is six merit
# badges, Life req. 3 is five more (11 total), Eagle req. 3 is ten more (21).
# --------------------------------------------------------------------------
BLOCKS = [
  {
    name: "Star", from: "First Class", badges: 6, board: "Star BOR",
    columns: ["Participation", "Scout Spirit", *["Merit Badge"] * 6,
              "Serv Proj", "Lead Pos", "Child Protect", "SM Conf", "Star BOR"],
    active: "four months active as a First Class Scout",
    service: "six hours of service",
    position: "four months in a position of responsibility",
    training: "Child Protect",
    training_label: "Child Protection exercises + Personal Safety Awareness videos (req. 6a/6b)"
  },
  {
    name: "Life", from: "Star", badges: 5, board: "Life BOR",
    columns: ["Participation", "Scout Spirit", *["Merit Badge"] * 5,
              "Serv Proj", "Lead Pos", "Teach Edge", "SM Conf", "Life BOR"],
    active: "six months active as a Star Scout",
    service: "six hours of service, at least three conservation-related",
    position: "six months in a position of responsibility",
    training: "Teach Edge",
    training_label: "Teaching EDGE demonstration (req. 6)"
  },
  {
    name: "Eagle", from: "Life", badges: 10, board: "Eagle BOR",
    columns: ["Participation", "Scout Spirit", *["Merit Badge"] * 10,
              "Lead Pos", "Eagle Proj", "SM Conf", "Eagle BOR"],
    active: "six months active as a Life Scout",
    service: nil,
    position: "six months in a position of responsibility",
    training: nil,
    training_label: nil
  }
].freeze

TRAILING_COLUMN = "Months til 18"

# Participation, Serv Proj, and Lead Pos hold a number, not a mark. The report's
# own header says they "indicate amount remaining"; the unit is days for
# Participation and Lead Pos, hours for Serv Proj. A number in one of these
# cells therefore means *not done* — only an "X" means the clock has run out.
SERVICE_COLUMN = "Serv Proj"
AMOUNT_COLUMNS = ["Participation", SERVICE_COLUMN, "Lead Pos"].freeze

# Scout Spirit, the Scoutmaster conference, and the board of review are reported
# as one line — troop convention, because they happen together inside a meeting.
CLOSING_COLUMNS = ["Scout Spirit", "SM Conf"].freeze

# TroopMaster never marks the Star block's "SM Conf" cell, even for Life Scouts
# whose Star rank is plainly complete. The column carries no information at all,
# so it is excluded from every count rather than read as incomplete. The rank in
# parentheses after the name, plus "Scout Spirit" and "Star BOR", say whether the
# conference happened.
BROKEN_CELLS = [["Star", "SM Conf"]].freeze

MARK_RE       = /\A([X*+]|\d+)\z/
COL_TOLERANCE = 4.0     # points from a column's centre
ROW_TOLERANCE = 4.0     # points from a mark row's centre
HEADER_MAX_W  = 12.0    # rotated headers are tall and narrow
HEADER_MIN_H  = 14.0
HEADER_BAND   = 70.0    # how far above the header baseline a wrapped header may start

# --------------------------------------------------------------------------
# merit badge requirements that cannot be compressed
#
# Every entry verified against docs/Scouts-BSA-Requirements-2025.pdf. Keyed by
# the requirement's leading number, because TroopMaster prints open requirements
# in compressed form ("2cd", "9b1") and only the number is reliably parseable.
# --------------------------------------------------------------------------
CLOCKS = [
  { badge: "Personal Management", reqs: %w[2], span: "13 consecutive weeks",
    note: "req. 2a budget and 2c tracking must cover the same 13 weeks" },
  { badge: "Personal Fitness", reqs: %w[7 8], span: "12 weeks",
    note: "req. 7 outlines the program, req. 8 completes it with a retest every 4 weeks" },
  { badge: "Personal Fitness", reqs: %w[1], span: "gate",
    note: "req. 1 physical + dental exams must precede reqs. 2-9 — book them first" },
  { badge: "Family Life", reqs: %w[3], span: "90 days",
    note: "req. 3 keeps a record of home duties for 90 days" },
  { badge: "Multisport", reqs: %w[5], span: "4 weeks",
    note: "req. 5 is a four-week training plan with a tracked chart" },
  { badge: "Camping", reqs: %w[9], span: "20 nights",
    note: "req. 9a is 20 nights of camping; 9b needs two outdoor activities, 9c a project" },
  { badge: "Citizenship in the Community", reqs: %w[7], span: "8 volunteer hours",
    note: "req. 7c volunteers 8 hours for the chosen organization — troop service does not count" },
  { badge: "Gardening", reqs: %w[5], span: "90 days",
    note: "req. 5 maintains a bin or garden for 90 days" }
].freeze

# Badges whose requirement 1 is another badge. Finishing the prerequisite closes
# the dependent requirement outright.
BADGE_PREREQS = {
  "Emergency Preparedness" => { req: "1", needs: "First Aid" }
}.freeze

# TroopMaster prints "Citizenship In Community" where the requirements book says
# "Citizenship in the Community", so badge names are compared loosely: case and
# the articles/prepositions that differ between the two are dropped. Comparing
# the printed strings directly makes a table entry silently match nothing.
BADGE_NOISE = /\b(the|of|and)\b/

def badge_key(name) = name.downcase.gsub(BADGE_NOISE, "").gsub(/[^a-z0-9]+/, " ").strip

# --------------------------------------------------------------------------
# pulling words out of the grid PDF
# --------------------------------------------------------------------------
module Extract
  module_function

  Word = Struct.new(:x0, :y0, :x1, :y1, :text) do
    def width  = x1 - x0
    def height = y1 - y0
    def xmid   = (x0 + x1) / 2.0
    def ymid   = (y0 + y1) / 2.0
  end

  WORD_RE = %r{<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>}

  def words(pdf_path)
    abort "not found: #{pdf_path}" unless File.exist?(pdf_path)

    Tempfile.create(["te", ".xhtml"]) do |tmp|
      _out, err, status = Open3.capture3("pdftotext", "-bbox", "-f", "1", "-l", "1",
                                         pdf_path, tmp.path)
      unless status.success?
        abort "pdftotext failed: #{err.strip}\n(install poppler: brew install poppler)"
      end

      File.read(tmp.path).scan(WORD_RE).map do |x0, y0, x1, y1, text|
        Word.new(x0.to_f, y0.to_f, x1.to_f, y1.to_f, text)
      end
    end
  end

  # Rotated column headers. Each column is one x position; the header may wrap
  # over several words, and rotated text reads bottom-to-top, so the first word
  # of the phrase has the greater y.
  #
  # A short word rotated 90 degrees is short in *y* — "til" and "18" in
  # "Months til 18" are only 7 and 11 points tall — so height alone cannot find
  # them. Long words seed the column x positions and the header's y band; the
  # rest of each phrase is then collected by position.
  def header_columns(words)
    seeds = words.select { |w| w.width < HEADER_MAX_W && w.height > HEADER_MIN_H }
    raise "no rotated column headers found — is this a Target Eagle report?" if seeds.empty?

    bottom = seeds.map(&:y1).max
    band   = (bottom - HEADER_BAND)..(bottom + 0.5)
    seeds.map { |w| w.x0.round(1) }.uniq.sort.map do |x|
      group = words.select do |w|
        (w.x0 - x).abs < 1.0 && w.width < HEADER_MAX_W && band.cover?(w.y0) && band.cover?(w.y1)
      end
      { x: x, xmid: group.first.xmid, name: group.sort_by { |w| -w.y0 }.map(&:text).join(" ") }
    end
  end

  def header_bottom(words)
    words.select { |w| w.width < HEADER_MAX_W && w.height > HEADER_MIN_H }.map(&:y1).max
  end

  # Scout rows. A name line always has a comma; the current rank is printed after
  # the name in parentheses and may wrap onto a second line.
  def scout_rows(words, grid_left)
    left    = words.select { |w| w.x1 < grid_left }
    anchors = left.select { |w| w.text.end_with?(",") }.sort_by(&:y0)
    anchors.each_with_index.map do |anchor, i|
      stop = anchors[i + 1]&.y0 || Float::INFINITY
      text = left.select { |w| w.y0 >= anchor.y0 - 0.5 && w.y0 < stop - 0.5 }
                 .sort_by { |w| [w.y0.round(1), w.x0] }.map(&:text).join(" ")
      { y: anchor.y0, text: text, name: text.sub(/\s*\(.*/, ""), rank: text[/\(([^)]*)\)/, 1] }
    end
  end

  def report_date(words)
    stamp = words.find { |w| w.text.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z}) }
    stamp && Date.strptime(stamp.text, "%m/%d/%Y")
  end
end

# --------------------------------------------------------------------------
# the grid
# --------------------------------------------------------------------------
class Report
  # Cell keys are [block, column name, which occurrence of that name]. "Merit
  # Badge" repeats six/five/ten times per block, so the occurrence index — not
  # the position in the block — is what makes a key unique.
  COLUMNS = BLOCKS.flat_map do |b|
    b[:columns].each_with_index.map { |c, i| [b[:name], c, b[:columns][0...i].count(c)] }
  end.push([nil, TRAILING_COLUMN, 0]).freeze

  attr_reader :scouts, :date, :placed

  def initialize(pdf_path)
    words = Extract.words(pdf_path)
    @cols = Extract.header_columns(words)
    check_shape!

    @date      = Extract.report_date(words)
    grid_left  = @cols.first[:x] - 1
    grid_top   = Extract.header_bottom(words)
    rows       = Extract.scout_rows(words, grid_left)
    raise "no Scout rows found — is this a Target Eagle report?" if rows.empty?

    marks   = words.select { |w| w.text.match?(MARK_RE) && w.x0 > grid_left && w.y0 > grid_top }
    cells   = place_marks(marks, rows)
    @scouts = rows.map { |r| Scout.new(r[:name], r[:rank], cells.fetch(r[:y], {})) }
  end

  # No tally row is printed on this report, so the cross-check is the rank in
  # parentheses: every block below a Scout's current rank must be complete. A
  # misaligned grid breaks that immediately.
  def verify
    @scouts.flat_map do |scout|
      BLOCKS.take_while { |b| b[:name] != scout.working_block&.fetch(:name) }.flat_map do |block|
        scout.blanks(block).map do |column, index|
          { scout: scout.name, rank: scout.rank, block: block[:name],
            column: column, index: index }
        end
      end
    end
  end

  private

  # Drop each mark into the cell whose row band and column centre it is nearest.
  # Marks cluster tightly in y — a row's glyphs land within a point of each other
  # and rows are 16 points apart — so cluster first, then match clusters to name
  # anchors in order. Anything that does not land cleanly raises.
  def place_marks(marks, rows)
    clusters = cluster_rows(marks)
    unless clusters.size == rows.size
      raise "found #{clusters.size} rows of marks for #{rows.size} Scouts — grid did not align"
    end

    @placed = 0
    clusters.zip(rows).each_with_object({}) do |(cluster, row), cells|
      cells[row[:y]] = cluster.each_with_object({}) do |mark, out|
        key = nearest_column(mark)
        raise "mark #{mark.text.inspect} at x=#{mark.x0.round(1)} matches no column" if key.nil?

        out[key] = mark.text
        @placed += 1
      end
    end
  end

  def cluster_rows(marks)
    marks.sort_by(&:ymid).chunk_while { |a, b| (b.ymid - a.ymid).abs <= ROW_TOLERANCE }.to_a
  end

  def nearest_column(mark)
    i = (0...@cols.size).min_by { |j| (@cols[j][:xmid] - mark.xmid).abs }
    return nil if (@cols[i][:xmid] - mark.xmid).abs > COL_TOLERANCE

    COLUMNS[i]
  end

  def check_shape!
    found = @cols.map { |c| c[:name] }
    want  = COLUMNS.map { |_, name, _| name }
    return if found == want

    raise <<~MSG
      This report's columns do not match the 2025 requirement set this skill knows.
        expected #{want.size} columns: #{BLOCKS.map { |b| "#{b[:name]}=#{b[:columns].size}" }.join(' ')} + #{TRAILING_COLUMN}
        found    #{found.size} columns: #{found.join(' | ')}
      If the requirements changed year-over-year, update BLOCKS in this script.
    MSG
  end
end

# --------------------------------------------------------------------------
# one Scout
# --------------------------------------------------------------------------
class Scout
  attr_reader :name, :rank, :cells

  def initialize(name, rank, cells)
    @name  = name
    @rank  = rank
    @cells = cells
  end

  def short = @name.split(",").first

  def at(block, column, index = 0) = @cells[[block[:name], column, index]]

  # The rank printed in parentheses is authoritative — TroopMaster's grid can
  # spill surplus elective merit badges into later blocks, so the marks alone do
  # not identify what a Scout is working on.
  def working_block = BLOCKS.find { |b| b[:from] == @rank }

  # An empty cell is unmet; so is an amount column still counting down.
  def done?(block, column, index = 0)
    value = at(block, column, index)
    return false if value.nil?

    !(AMOUNT_COLUMNS.include?(column) && value.match?(/\A\d+\z/))
  end

  def blanks(block)
    block[:columns].each_with_index.filter_map do |column, i|
      index = block[:columns][0...i].count(column)
      next if BROKEN_CELLS.include?([block[:name], column])

      [column, index] unless done?(block, column, index)
    end
  end

  def badges_left(block) = blanks(block).count { |column, _| column == "Merit Badge" }

  # A number in a time or service column is the amount still remaining.
  def remaining(block, column)
    value = at(block, column)
    value&.match?(/\A\d+\z/) ? value.to_i : nil
  end

  # The report's "Months til 18" column — how long before this Scout ages out.
  def months_to_age_out = @cells[[nil, TRAILING_COLUMN, 0]]&.to_i

  def needs_meeting?(block)
    keys = CLOSING_COLUMNS + [block[:board]]
    blanks(block).any? { |column, _| keys.include?(column) }
  end

  # Program work left, as column names, with Scout Spirit / SMC / BoR and the
  # merit badge slots taken out — those are reported separately.
  def program_gaps(block)
    keys = CLOSING_COLUMNS + [block[:board], "Merit Badge"]
    blanks(block).map(&:first).reject { |column| keys.include?(column) }
  end
end

# --------------------------------------------------------------------------
# the partial merit badge list
# --------------------------------------------------------------------------
Partial = Struct.new(:scout, :badge, :year, :pct, :eagle_required, :open_reqts, :remarks,
                     keyword_init: true) do
  def numbers = open_reqts.filter_map { |code| code[/\A\d+/] }.uniq
  def label   = eagle_required ? "#{badge}*" : badge
end

module Partials
  module_function

  NAME_RE   = /\A([A-Z][\w.'-]*(?: [\w.'-]+)*, .+)\z/
  BADGE_RE  = /\A\s+(.+?)([*#]?)\s+\((\d{4})\)\s*:\s*(\d+)%/
  OPEN_RE   = /\A\s+Open Reqts:\s*(.*)\z/
  REMARK_RE = /\A\s+Remarks:\s*(.*)\z/
  SKIP_RE   = %r{Page \d+\z|Partial Merit Badges List|Counselor:|BSA ID:|\d+/\d+/\d{4}}

  def read(pdf_path)
    abort "not found: #{pdf_path}" unless File.exist?(pdf_path)

    out, err, status = Open3.capture3("pdftotext", "-layout", pdf_path, "-")
    abort "pdftotext failed: #{err.strip}" unless status.success?

    parse(out.lines.map(&:chomp))
  end

  def parse(lines)
    state = { scout: nil, current: nil, mode: nil, list: [] }
    lines.each { |line| step(state, line) }
    state[:list]
  end

  def step(state, line)
    if scout_name(line)
      start_scout(state, line)
    elsif BADGE_RE.match?(line)
      start_badge(state, line)
    elsif (m = OPEN_RE.match(line))
      state[:current]&.open_reqts&.concat(split_reqts(m[1]))
      state[:mode] = :open
    elsif (m = REMARK_RE.match(line))
      state[:current]&.remarks = m[1].strip
      state[:mode] = nil
    elsif continuation?(state, line)
      state[:current]&.open_reqts&.concat(split_reqts(line))
    else
      state[:mode] = nil
    end
  end

  # A Scout's name is the only thing printed hard against the left margin.
  def scout_name(line)
    return nil if line.start_with?(" ")

    NAME_RE.match(line.rstrip)&.captures&.first
  end

  def start_scout(state, line)
    state[:scout] = scout_name(line)
    state[:mode]  = nil
  end

  def start_badge(state, line)
    name, eagle, year, pct = BADGE_RE.match(line).captures
    state[:current] = Partial.new(scout: state[:scout], badge: name.strip, year: year.to_i,
                                  pct: pct.to_i, eagle_required: !eagle.empty?,
                                  open_reqts: [], remarks: nil)
    state[:list] << state[:current]
    state[:mode] = nil
  end

  # "Open Reqts:" wraps onto indented continuation lines when the list is long.
  def continuation?(state, line)
    state[:mode] == :open && line.match?(/\A\s+\S/) && !line.match?(SKIP_RE)
  end

  def split_reqts(text) = text.split(",").map(&:strip).reject(&:empty?)
end

# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------
module Render
  module_function

  def verify!(report, quiet: false)
    bad = report.verify
    if bad.empty?
      unless quiet
        puts "OK — #{report.scouts.size} Scouts, #{report.placed} marks placed, " \
             "#{Report::COLUMNS.size} columns matched."
        puts "     Every rank block below each Scout's printed rank is complete."
        puts "     Report date: #{report.date}."
        puts "     Star 'SM Conf' ignored — TroopMaster never marks it."
      end
      return
    end
    warn "MISMATCH — a completed rank block has holes in it. Do not trust this parse:"
    bad.each do |b|
      warn format("  %-22s (%s) %s / %s", b[:scout], b[:rank], b[:block], b[:column])
    end
    exit 1
  end

  def summary(report, partials)
    verify!(report, quiet: true)
    BLOCKS.each do |block|
      cohort = report.scouts.select { |s| s.working_block == block }
      next if cohort.empty?

      puts "\n== Working on #{block[:name]} (#{cohort.size}) =="
      cohort.sort_by { |s| s.months_to_age_out || 999 }.each { |s| puts summary_line(s, block) }
    end
    puts "\n#{load_line(report)}"
    puts pipeline_line(report, partials) if partials
  end

  def summary_line(scout, block)
    bits = []
    bits << "#{scout.badges_left(block)} MB" if scout.badges_left(block).positive?
    scout.program_gaps(block).each { |column| bits << gap_phrase(scout, block, column) }
    bits << meeting_phrase(block) if scout.needs_meeting?(block)
    format("  %-22s %-6s %3s mo  %s", scout.name, "(#{scout.rank})",
           scout.months_to_age_out || "?", bits.join("; "))
  end

  def gap_phrase(scout, block, column)
    left = scout.remaining(block, column)
    case column
    when "Participation" then left ? "#{left}d active" : "active time"
    when "Lead Pos"      then left ? "#{left}d POR" : "position of responsibility"
    when SERVICE_COLUMN  then left ? "#{left}h service" : "service hours"
    when "Eagle Proj"    then "Eagle project"
    else column
    end
  end

  def meeting_phrase(block)
    block[:name] == "Eagle" ? "SMC + Eagle BoR" : "needs an SMC/BoR meeting"
  end

  def plural(count, noun) = "#{count} #{noun}#{'s' if count != 1}"

  # Two different numbers, and conflating them overstates the near-term load.
  # "Ready now" is the one that has to fit in the next few meeting nights.
  def load_line(report)
    working = report.scouts.filter_map(&:working_block)
    troop   = working.count { |b| b[:name] != "Eagle" }
    ready   = report.scouts.select { |s| s.working_block && ready_now?(s) }
    [
      "Eventual load, if every Scout finished: #{working.size} SMCs, #{troop} troop BoRs, " \
      "#{working.size - troop} Eagle BoRs (council/district).",
      if ready.empty?
        "Ready now: none."
      else
        "Ready now — nothing left but the meeting: " \
          "#{ready.map(&:short).join(', ')}."
      end
    ].join("\n")
  end

  def ready_now?(scout)
    block = scout.working_block
    scout.badges_left(block).zero? && scout.program_gaps(block).empty? &&
      scout.needs_meeting?(block)
  end

  def pipeline_line(report, partials)
    by_scout = partials.group_by(&:scout)
    thin = report.scouts.select do |s|
      block = s.working_block
      block && s.badges_left(block) > by_scout.fetch(s.name, []).size
    end
    return "Merit badge pipeline: every Scout has more partials than open slots." if thin.empty?

    "Thin merit badge pipeline (open slots exceed badges in progress): " \
      "#{thin.map(&:short).join(', ')}."
  end

  def gaps(report, only: nil)
    verify!(report, quiet: true)
    scouts(report, only).each do |scout|
      block = scout.working_block
      puts "\n#{scout.name} — #{scout.rank}, #{scout.months_to_age_out || '?'} months to 18"
      next puts "  Eagle Scout. Nothing left in this report." if block.nil?

      puts "  Working on #{block[:name]}"
      badges = scout.badges_left(block)
      puts "    #{badges} merit badge#{'s' if badges != 1} (#{block[:badges]} for this rank)" if
        badges.positive?
      scout.program_gaps(block).each do |column|
        puts "    #{detail(scout, block, column, report.date)}"
      end
      puts "    -> #{meeting_phrase(block)}" if scout.needs_meeting?(block)
      if block[:name] != "Eagle"
        puts "    NOTE: #{block[:name]} requirements count only while a #{block[:from]} " \
             "Scout — none of this can be banked early."
      end
    end
  end

  def detail(scout, block, column, date)
    left = scout.remaining(block, column)
    on   = left && date ? " — completes #{date + left}" : ""
    case column
    when "Participation"  then "#{plural(left, 'day')} of #{block[:active]} left#{on}"
    when "Lead Pos"       then "#{plural(left, 'day')} of #{block[:position]} left#{on}"
    when SERVICE_COLUMN   then "#{plural(left, 'hour')} remaining — #{block[:service]}"
    when "Eagle Proj"     then "Eagle Scout service project — the proposal needs four approvals"
    when block[:training] then block[:training_label]
    else column
    end
  end

  def partials_report(report, partials, only: nil, min_pct: 0)
    verify!(report, quiet: true)
    by_scout = partials.group_by(&:scout)
    scouts(report, only).each do |scout|
      rows = by_scout.fetch(scout.name, []).select { |p| p.pct >= min_pct }
                                           .sort_by { |p| -p.pct }
      next if rows.empty?

      block = scout.working_block
      open = block ? "#{scout.badges_left(block)} slots open for #{block[:name]}" : "Eagle Scout"
      puts "\n#{scout.name} — #{open}"
      rows.each do |p|
        puts format("  %3d%%  %-32s %s%s", p.pct, p.label, p.open_reqts.join(", "),
                    p.remarks ? "   [#{p.remarks}]" : "")
      end
      prereq_notes(rows).each { |note| puts "  ** #{note}" }
    end
  end

  # Emergency Preparedness req. 1 is "Earn the First Aid merit badge" — one
  # sign-off can close two Eagle-required badges, or block one behind the other.
  def prereq_notes(rows)
    rows.filter_map do |p|
      rule = BADGE_PREREQS.find { |name, _| badge_key(name) == badge_key(p.badge) }&.last
      next unless rule && p.open_reqts.any? { |c| c[/\A\d+/] == rule[:req] }

      other = rows.find { |q| badge_key(q.badge) == badge_key(rule[:needs]) }
      if other
        "#{p.badge} req. #{rule[:req]} is the #{rule[:needs]} merit badge — " \
          "#{rule[:needs]} is at #{other.pct}% (#{other.open_reqts.join(', ')}). Finish it first."
      else
        "#{p.badge} req. #{rule[:req]} is the #{rule[:needs]} merit badge, " \
          "which is not in progress. Start it."
      end
    end
  end

  def batch(_report, partials, min: 2, min_pct: 0)
    freq = Hash.new { |h, k| h[k] = [] }
    partials.select { |p| p.pct >= min_pct }.each do |p|
      p.numbers.each { |n| freq[[p.badge, n, p.eagle_required]] << p.scout.split(",").first }
    end
    rows = freq.select { |_, who| who.size >= min }.sort_by do |(badge, n, _), who|
      [-who.size, badge, n.to_i]
    end
    puts "\n== Open merit badge requirements #{min}+ Scouts share =="
    rows.each do |(badge, number, eagle), who|
      puts format("  %2d  %-32s req. %-3s %s", who.size, eagle ? "#{badge}*" : badge,
                  number, who.sort.uniq.join(", "))
    end
    puts "\n  * = Eagle-required." if rows.any? { |(_, _, eagle), _| eagle }
  end

  def clocks(_report, partials)
    puts "\n== Requirements with a calendar clock =="
    quiet = CLOCKS.reject { |clock| report_clock?(clock, partials) }
    # Naming a clock that matched nothing is the point: it is how a renamed badge
    # or a year-over-year requirement change shows up instead of vanishing.
    unless quiet.empty?
      puts "\n  No Scout is currently open on: " \
           "#{quiet.map { |c| "#{c[:badge]} (reqs. #{c[:reqs].join('/')})" }.join('; ')}."
    end
    puts "  Re-read the requirement text before planning around any of these; " \
         "requirements are year-versioned."
  end

  # Returns false when no Scout has this clock open, so the caller can say so.
  def report_clock?(clock, partials)
    key  = badge_key(clock[:badge])
    hits = partials.select { |p| badge_key(p.badge) == key && p.numbers.intersect?(clock[:reqs]) }
    return false if hits.empty?

    puts "\n  #{clock[:badge]} — reqs. #{clock[:reqs].join('/')} — #{clock[:span]}"
    puts "    #{clock[:note]}"
    hits.sort_by { |p| -p.pct }.each do |p|
      open = p.open_reqts.select { |c| clock[:reqs].include?(c[/\A\d+/]) }
      puts format("    %-24s %3d%%  still open here: %s", p.scout.split(",").first, p.pct,
                  open.join(", "))
    end
    true
  end

  def scouts(report, only)
    return report.scouts unless only

    report.scouts.select { |s| s.name.downcase.include?(only.downcase) }
  end

  def json(report, partials)
    by_scout = (partials || []).group_by(&:scout)
    puts JSON.pretty_generate(
      report_date: report.date,
      scouts: report.scouts.map { |s| scout_json(s, by_scout.fetch(s.name, [])) }
    )
  end

  def cell_key((block, column, index))
    "#{block || '-'}/#{column}#{"##{index + 1}" if index.positive?}"
  end

  def scout_json(scout, partials)
    block = scout.working_block
    {
      name: scout.name, rank: scout.rank, months_to_age_out: scout.months_to_age_out,
      working_rank: block&.fetch(:name),
      merit_badges_left: block ? scout.badges_left(block) : 0,
      program_gaps: if block
                      scout.program_gaps(block).map do |c, _|
                        gap_phrase(scout, block, c)
                      end
                    else
                      []
                    end,
      needs_meeting: block ? scout.needs_meeting?(block) : false,
      partials: partials.map do |p|
        { badge: p.badge, eagle_required: p.eagle_required,
          pct: p.pct, open: p.open_reqts }
      end,
      cells: scout.cells.to_h { |key, value| [cell_key(key), value] }
    }
  end
end

# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------
USAGE = <<~TEXT
  usage: ruby scripts/te.rb COMMAND REPORT.pdf [options]

    verify   REPORT.pdf                     cross-check the parse against each Scout's printed rank
    summary  REPORT.pdf                     cohorts, what is left per Scout, SMC/BoR load
    gaps     REPORT.pdf [--scout NAME]      what each Scout still needs for their next rank
    partials REPORT.pdf --partials P.pdf    merit badges in progress, closest first
    batch    REPORT.pdf --partials P.pdf    open requirements several Scouts share [--min N]
    clocks   REPORT.pdf --partials P.pdf    requirements with a multi-week clock attached
    json     REPORT.pdf [--partials P.pdf]  the whole parse, for further analysis

  --partials takes the matching TroopMaster "Partial Merit Badges List" PDF.
  --min-pct N limits `partials` and `batch` to badges at or above N percent complete.
  A Scout at 0% on a badge contributes every one of its requirements to `batch`;
  --min-pct 1 drops the not-yet-started ones.
TEXT

def flag(name, default = nil)
  i = ARGV.index(name)
  i ? ARGV[i + 1] : default
end

command = ARGV.shift
path    = ARGV.shift
abort USAGE if command.nil? || path.nil? || path.start_with?("--")

partials_path = flag("--partials")
abort "#{command}: --partials PARTIALS.pdf is required" if
  %w[partials batch clocks].include?(command) && partials_path.nil?

begin
  report   = Report.new(path)
  partials = partials_path && Partials.read(partials_path)
rescue RuntimeError => e
  abort "error: #{e.message}"
end

case command
when "verify"   then Render.verify!(report)
when "summary"  then Render.summary(report, partials)
when "gaps"     then Render.gaps(report, only: flag("--scout"))
when "partials"
  Render.partials_report(report, partials, only: flag("--scout"),
                                           min_pct: flag("--min-pct", "0").to_i)
when "batch"
  Render.batch(report, partials, min: flag("--min", "2").to_i,
                                 min_pct: flag("--min-pct", "0").to_i)
when "clocks"   then Render.clocks(report, partials)
when "json"     then Render.json(report, partials)
else abort USAGE
end
