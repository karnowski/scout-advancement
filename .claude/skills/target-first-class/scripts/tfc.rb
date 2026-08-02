#!/usr/bin/env ruby
# frozen_string_literal: true

#
# target-first-class — read a TroopMaster "Target First Class" report.
#
# The report is a 25-ish row by 121 column grid of rotated headers and one-glyph
# marks. Plain `pdftotext` scrambles it, so this rebuilds the grid from word
# bounding boxes and then checks itself against the report's own "Scouts
# Needing:" tally row before reporting anything.
#
#   ruby scripts/tfc.rb verify  REPORT.pdf
#   ruby scripts/tfc.rb summary REPORT.pdf
#   ruby scripts/tfc.rb gaps    REPORT.pdf [--scout NAME] [--all-ranks]
#   ruby scripts/tfc.rb batch   REPORT.pdf [--min N]
#   ruby scripts/tfc.rb json    REPORT.pdf
#
# Needs `pdftotext` (poppler): brew install poppler

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "json"
require "open3"
require "tempfile"

# --------------------------------------------------------------------------
# what the report's 121 columns are, in printed order
#
# The rotated headers lose their requirement code for single-part numbers
# ("Scout 5" comes out as bare "Scout"), so the codes are named here and the
# parser asserts that the column count and the rank run-lengths still match.
# Labels are the report's own legend, printed on pages 1-2.
# --------------------------------------------------------------------------
RANKS = [
  {
    name: "Scout", prefix: "Scout", board: false,
    closing: %w[1b 7 8],                      # Scout Spirit, SMC, Scout Complete
    reqs: {
      "1a" => "Scout Oath/Law",
      "1b" => "Scout Spirit",
      "1c" => "Scout Sign/Salute/Handshake",
      "1d" => "Describe First Class badge",
      "1e" => "Explain the Outdoor Code",
      "1f" => "Pledge of Allegiance",
      "2a" => "Scout Leadership",
      "2b" => "Scout Advancement",
      "2c" => "Scout Ranks",
      "2d" => "Merit Badges",
      "3a" => "Explain Patrol Method",
      "3b" => "Patrol Name/Emblem/Flag",
      "4a" => "Demo Square/Hitch Knots",
      "4b" => "Demo Whip/Fuse Rope",
      "5" => "Pocketknife Safety",
      "6a" => "Personal Safety Pamphlet",
      "6b" => "Personal Safety Videos",
      "7" => "Scoutmaster Conference",
      "8" => "Scout Complete"
    }
  },
  {
    name: "Tenderfoot", prefix: "Tfoot", board: true,
    closing: %w[9 10 11],                     # Scout Spirit, SMC, BoR
    reqs: {
      "1a" => "Prepare To Camp",
      "1b" => "Camp and Pitch Tent",
      "1c" => "Outdoor Code",
      "2a" => "Prepare/Cook Meal",
      "2b" => "Safe Cleaning/Food Prep",
      "2c" => "Eating Together as a Patrol",
      "3a" => "Use of the Square Knot",
      "3b" => "Use of two Half Hitches",
      "3c" => "Use of the Taut-Line Hitch",
      "3d" => "Use of Knife, Saw, and Ax",
      "4a" => "Demo First Aid",
      "4b" => "Identify Poison Plants",
      "4c" => "Tell How to Prevent Injury",
      "4d" => "Assemble First-Aid Kit",
      "5a" => "Explain/Use Buddy System",
      "5b" => "What To Do If Lost",
      "5c" => "Rules of Safe Hiking",
      "5d" => "Importance of Durable Surfaces",
      "6a" => "Physical Fitness Test",
      "6b" => "Plan For Improvement",
      "6c" => "Show Improvement",
      "7a" => "Proper Flag Handling/Care",
      "7b" => "Service Project",
      "8" => "Teach using EDGE",
      "9" => "Scout Spirit/Scout Law",
      "10" => "Scoutmaster Conference",
      "11" => "Board of Review"
    }
  },
  {
    name: "Second Class", prefix: "Second", board: true,
    closing: %w[10 11 12],
    reqs: {
      "1a" => "Troop/Patrol Activities",
      "1b" => "Leave No Trace",
      "1c" => "Location for Campsite",
      "2a" => "Fire for Cooking",
      "2b" => "Prepare Kindling/Fuel",
      "2c" => "Build/Extinguish a Fire",
      "2d" => "When To Use a Camp Stove",
      "2e" => "Plan and Cook Hot Meal",
      "2f" => "Demo Sheet Bend Knot",
      "2g" => "Demo Bowline Knot",
      "3a" => "Demo Map/Compass",
      "3b" => "Hike w/ Compass/Map",
      "3c" => "Describe Hazards/Injuries",
      "3d" => "Directions w/o Compass",
      "4" => "Identify Wild Animals",
      "5a" => "Precautions for Safe Swim",
      "5b" => "BSA Beginner Swimmer Test",
      "5c" => "Demo Water Rescue",
      "5d" => "Danger of Swimming Rescue",
      "6a" => "Demo First Aid",
      "6b" => "Handle 'hurry' Cases",
      "6c" => "How to Prevent Injuries",
      "6d" => "Emergency Response",
      "6e" => "Vehicular Accident",
      "7a" => "Be Physically Active",
      "7b" => "Challenges/Successes",
      "7c" => "Dangers of Drugs/Alcohol",
      "8a" => "Flag Ceremony",
      "8b" => "Respect for the Flag",
      "8c" => "Plan for Earning Money",
      "8d" => "Cost of Item",
      "8e" => "Service Project",
      "9a" => "Personal Safety/Protection",
      "9b" => "Describe Bullying",
      "10" => "Scout Spirit/Scout Law",
      "11" => "Scoutmaster Conference",
      "12" => "Board of Review"
    }
  },
  {
    name: "First Class", prefix: "First", board: true,
    closing: %w[11 12 13],
    reqs: {
      "1a" => "Troop/Patrol Activities",
      "1b" => "Outdoor Code",
      "2a" => "Plan/Discuss Camp Menu",
      "2b" => "List Food Amounts/Budget",
      "2c" => "Pans/Utensils Needed",
      "2d" => "Safe Food Handling",
      "2e" => "Serve as Camp Cook",
      "3a" => "Discuss Use of Lashings",
      "3b" => "Demo Timber/Clove Hitch",
      "3c" => "Demo Lashings",
      "3d" => "Make Camp Gadget",
      "4a" => "Orienteering Course",
      "4b" => "Demo How To Use GPS",
      "5a" => "Identify Plants",
      "5b" => "Obtain Weather Forecast",
      "5c" => "Hazardous Weather",
      "5d" => "Extreme Weather",
      "6a" => "BSA Swimmer Test",
      "6b" => "Safe Trip Afloat",
      "6c" => "Parts of a Canoe",
      "6d" => "Proper Body Position",
      "6e" => "Show a Line Rescue",
      "7a" => "Demonstrate Bandages",
      "7b" => "How To Transport Person",
      "7c" => "Signs of Heart Attack",
      "7d" => "Utility Services",
      "7e" => "Emergency Action Plan",
      "7f" => "How To Obtain Water",
      "8a" => "Be physically active",
      "8b" => "Challenges and Successes",
      "9a" => "Constitutional Rights",
      "9b" => "Environmental Issues",
      "9c" => "How To Reduce/Recycle",
      "9d" => "Service Project",
      "10" => "Invite a Friend",
      "11" => "Scout Spirit/Scout Law",
      "12" => "Scoutmaster Conference",
      "13" => "Board of Review"
    }
  }
].freeze

# "Scout 1a", "Tfoot 1a", ... in printed order.
COLUMNS = RANKS.flat_map { |r| r[:reqs].keys.map { |c| "#{r[:prefix]} #{c}" } }.freeze
LABELS  = RANKS.flat_map { |r| r[:reqs].map { |c, t| ["#{r[:prefix]} #{c}", t] } }.to_h.freeze
BY_PREFIX = RANKS.to_h { |r| [r[:prefix], r] }.freeze

# Geometry, measured from the report and re-derived per file where possible.
HEADER_MAX_W = 4.5      # a rotated header is narrow in x ...
HEADER_MIN_H = 3.4      # ... and tall in y
ROW_TOLERANCE = 3.0     # how far a mark may sit from its Scout's name baseline
COL_TOLERANCE = 2.0     # how far a mark may sit from its column's x
MARKS = ["X", "/"].freeze

# --------------------------------------------------------------------------
# extraction
# --------------------------------------------------------------------------
module Extract
  module_function

  Word = Struct.new(:x0, :y0, :x1, :y1, :text) do
    def width  = x1 - x0
    def height = y1 - y0
  end

  WORD_RE = %r{<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>}

  def words(pdf_path)
    abort "not found: #{pdf_path}" unless File.exist?(pdf_path)

    Tempfile.create(["tfc", ".xhtml"]) do |tmp|
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

  # Rotated column headers: one x position per column, left to right.
  def header_columns(words)
    heads = words.select { |w| w.width < HEADER_MAX_W && w.height > HEADER_MIN_H }
    groups = heads.group_by { |w| w.x0.round(1) }
    groups.keys.sort.map do |x|
      # Rotated text reads bottom-to-top, so the rank word has the greater y.
      { x: x, rank: groups[x].max_by(&:y0).text }
    end
  end

  # Scout rows: the left-hand name column. A name line always has a comma; the
  # awarded rank, when there is one, sits on the line just below it.
  def scout_rows(words, grid_left)
    left    = words.select { |w| w.x1 < grid_left }
    anchors = left.select { |w| w.text.end_with?(",") }
    rows    = anchors.map do |anchor|
      name = line_at(left, anchor.y0, anchor.y0 + 0.5)
      rank = line_at(left, anchor.y0 + 2, anchor.y0 + 6)
      { y: anchor.y0, name: name, rank: rank.empty? ? "(none)" : rank }
    end
    rows.sort_by { |r| r[:y] }
  end

  def line_at(words, from, to)
    words.select { |w| w.y0 >= from - 0.5 && w.y0 < to }.sort_by(&:x0).map(&:text).join(" ")
  end
end

# --------------------------------------------------------------------------
# the grid
# --------------------------------------------------------------------------
class Report
  attr_reader :scouts, :tally, :placed, :dropped

  def initialize(pdf_path)
    words  = Extract.words(pdf_path)
    @cols  = Extract.header_columns(words)
    check_shape!

    xs         = @cols.map { |c| c[:x] }
    grid_left  = xs.first - 1
    rows       = Extract.scout_rows(words, grid_left)
    raise "no Scout rows found — is this a Target First Class report?" if rows.empty?

    marks = words.select { |w| MARKS.include?(w.text) && w.x0 > grid_left }
    grid  = place_marks(marks, rows, xs)

    @scouts = rows.map { |r| Scout.new(r[:name], r[:rank], grid[r[:name]]) }
    assign_short_names!
    @tally = read_tally(words, xs, rows.last[:y])
  end

  # The report prints, under each column, how many Scouts still need it. If our
  # grid disagrees anywhere, the grid is wrong — say so instead of reporting it.
  def verify
    COLUMNS.each_with_index.filter_map do |col, i|
      computed = @scouts.count { |s| !s.done?(col) }
      printed  = @tally[i]
      next if printed.nil? || printed == computed

      { column: col, computed: computed, printed: printed }
    end
  end

  private

  # Drop each mark into the cell whose Scout row and column x it is nearest.
  # A mark sits a little below its Scout's name baseline; measure that offset
  # from the data rather than assuming it.
  def place_marks(marks, rows, col_xs)
    offset   = median(marks.map { |m| rows.map { |r| m.y0 - r[:y] }.min_by(&:abs) })
    @placed  = 0
    @dropped = 0
    grid     = Hash.new { |h, k| h[k] = {} }
    marks.each do |mark|
      y   = mark.y0 - offset
      row = rows.min_by { |r| (y - r[:y]).abs }
      col = nearest_column(col_xs, mark.x0)
      if col.nil? || (y - row[:y]).abs > ROW_TOLERANCE
        @dropped += 1
        next
      end
      grid[row[:name]][COLUMNS[col]] = mark.text
      @placed += 1
    end
    grid
  end

  # Troop 400 has two Browns and two Sessions brothers, so a bare surname is
  # ambiguous. Escalate only as far as needed: "Thorpe", then "B. Jones", then
  # "Beren Sessions" — Beren and Bodhi share an initial, so theirs goes to the
  # full given name.
  def assign_short_names!
    @scouts.group_by { |s| s.name.split(",").first.strip }.each do |surname, group|
      givens = group.map { |s| s.name.split(",")[1].to_s.strip }
      style  = if group.size == 1 then :surname
               elsif givens.map { |g| g[0] }.uniq.size == givens.size then :initial
               else :given
               end
      group.zip(givens).each do |scout, given|
        scout.short = case style
                      when :surname then surname
                      when :initial then "#{given[0]}. #{surname}"
                      else "#{given} #{surname}"
                      end
      end
    end
  end

  def check_shape!
    expected = RANKS.flat_map { |r| [r[:prefix]] * r[:reqs].size }
    return if @cols.size == COLUMNS.size && @cols.map { |c| c[:rank] } == expected

    raise <<~MSG
      This report's columns do not match the 2025 requirement set this skill knows.
        expected #{COLUMNS.size} columns: #{RANKS.map { |r| "#{r[:prefix]}=#{r[:reqs].size}" }.join(' ')}
        found    #{@cols.size} columns: #{@cols.map { |c| c[:rank] }.tally.map { |k, v| "#{k}=#{v}" }.join(' ')}
      If the requirements changed year-over-year, update RANKS in this script.
    MSG
  end

  def nearest_column(col_xs, pos)
    i = (0...col_xs.size).min_by { |j| (col_xs[j] - pos).abs }
    (col_xs[i] - pos).abs <= COL_TOLERANCE ? i : nil
  end

  # Tally digits are stacked vertically under each column: "1" over "0" is 10.
  def read_tally(words, col_xs, last_row_y)
    digits = words.select do |w|
      w.text.match?(/\A\d\z/) && w.x0 > col_xs.first - 1 && w.y0 > last_row_y
    end
    by_col = Hash.new { |h, k| h[k] = [] }
    digits.each do |w|
      col = nearest_column(col_xs, w.x0)
      by_col[col] << w if col
    end
    Array.new(COLUMNS.size) do |i|
      ws = by_col[i]
      ws.empty? ? 0 : ws.sort_by(&:y0).map(&:text).join.to_i
    end
  end

  def median(values)
    return 0.0 if values.empty?

    sorted = values.sort
    sorted[sorted.size / 2]
  end
end

# --------------------------------------------------------------------------
# one Scout
# --------------------------------------------------------------------------
class Scout
  attr_reader :name, :awarded, :marks
  attr_accessor :short

  def initialize(name, awarded, marks)
    @name    = name
    @awarded = awarded
    @marks   = marks
    @short   = name.split(",").first
  end

  # Both "X" and "/" mean complete. "/" is credit that came with a rank award
  # rather than an individually dated sign-off.
  def done?(column) = !@marks[column].nil?

  def gaps(rank)
    rank[:reqs].keys.reject { |c| done?("#{rank[:prefix]} #{c}") }
  end

  # The lowest rank not yet finished — what this Scout is actually working on.
  def working_rank = RANKS.find { |r| !gaps(r).empty? }

  # Program work left, with Scout Spirit / SMC / BoR taken out. Those three are
  # reported together as "needs an SMC/BoR meeting".
  def skill_gaps(rank) = gaps(rank) - rank[:closing]

  def needs_meeting?(rank) = gaps(rank).intersect?(rank[:closing])
end

# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------
module Render
  module_function

  def meeting_phrase(rank) = rank[:board] ? "needs an SMC/BoR meeting" : "needs an SMC meeting"

  def verify!(report, quiet: false)
    bad = report.verify
    if bad.empty?
      unless quiet
        puts "OK — all #{COLUMNS.size} columns match the report's own 'Scouts Needing' tally."
        puts format("     %d Scouts, %d marks placed, %d dropped.",
                    report.scouts.size, report.placed, report.dropped)
      end
      return
    end
    warn "MISMATCH against the report's own tally — do not trust this parse:"
    bad.each do |b|
      warn format("  %-11s computed=%-3d printed=%d", b[:column], b[:computed], b[:printed])
    end
    exit 1
  end

  def summary(report)
    verify!(report, quiet: true)
    RANKS.each do |rank|
      cohort = report.scouts.select { |s| s.working_rank == rank }
      next if cohort.empty?

      puts "\n== Working on #{rank[:name]} (#{cohort.size}) =="
      cohort.sort_by { |s| s.skill_gaps(rank).size }.each do |s|
        puts format("  %-20s awarded:%-13s %2d items left  %s",
                    s.name, s.awarded, s.skill_gaps(rank).size,
                    s.needs_meeting?(rank) ? "+ #{meeting_phrase(rank)}" : "")
      end
    end
    smc = report.scouts.count(&:working_rank)
    bor = report.scouts.count { |s| s.working_rank&.fetch(:board) }
    puts "\nConference / board load: #{smc} SMCs, #{bor} BoRs, #{smc + bor} encounters total."
  end

  def gaps(report, only: nil, all_ranks: false)
    verify!(report, quiet: true)
    report.scouts.each do |s|
      next if only && !s.name.downcase.include?(only.downcase)

      ranks = all_ranks ? RANKS : [s.working_rank].compact
      puts "\n#{s.name} (awarded: #{s.awarded})"
      ranks.each do |rank|
        left = s.skill_gaps(rank)
        next if left.empty? && !s.needs_meeting?(rank)

        puts "  #{rank[:name]} — #{left.size} items"
        left.each { |c| puts format("    %-4s %s", c, LABELS["#{rank[:prefix]} #{c}"]) }
        puts "    -> #{meeting_phrase(rank)}" if s.needs_meeting?(rank)
      end
    end
  end

  def batch(report, min: 2)
    verify!(report, quiet: true)
    RANKS.each do |rank|
      cohort = report.scouts.select { |s| s.working_rank == rank }
      next if cohort.empty?

      freq = Hash.new { |h, k| h[k] = [] }
      cohort.each { |s| s.skill_gaps(rank).each { |c| freq[c] << s.short } }
      rows = freq.select { |_, who| who.size >= min }
                 .sort_by { |c, who| [-who.size, rank[:reqs].keys.index(c)] }
      next if rows.empty?

      puts "\n== #{rank[:name]} cohort (#{cohort.size}) — shared gaps =="
      rows.each do |c, who|
        puts format("  %-4s %-32s %2d  %s", c, rank[:reqs][c], who.size, who.join(", "))
      end
    end
  end

  def json(report)
    puts JSON.pretty_generate(
      report.scouts.map do |s|
        rank = s.working_rank
        {
          name: s.name, awarded: s.awarded,
          working_rank: rank&.fetch(:name),
          skill_gaps: rank ? s.skill_gaps(rank) : [],
          needs_meeting: rank ? s.needs_meeting?(rank) : false,
          board_required: rank ? rank[:board] : false,
          marks: s.marks
        }
      end
    )
  end
end

# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------
USAGE = <<~TEXT
  usage: ruby scripts/tfc.rb COMMAND REPORT.pdf [options]

    verify   REPORT.pdf                 cross-check the parse against the report's tally row
    summary  REPORT.pdf                 cohorts, items left per Scout, total SMC/BoR load
    gaps     REPORT.pdf [--scout NAME]  what each Scout still needs [--all-ranks]
    batch    REPORT.pdf [--min N]       requirements several Scouts need at once (default 2)
    json     REPORT.pdf                 the whole parse, for further analysis
TEXT

command = ARGV.shift
path    = ARGV.shift
abort USAGE if command.nil? || path.nil?

def flag(name, default = nil)
  i = ARGV.index(name)
  i ? ARGV[i + 1] : default
end

begin
  report = Report.new(path)
rescue RuntimeError => e
  abort "error: #{e.message}"
end

case command
when "verify"  then Render.verify!(report)
when "summary" then Render.summary(report)
when "gaps"
  Render.gaps(report, only: flag("--scout"), all_ranks: ARGV.include?("--all-ranks"))
when "batch"   then Render.batch(report, min: flag("--min", "2").to_i)
when "json"    then Render.json(report)
else abort USAGE
end
