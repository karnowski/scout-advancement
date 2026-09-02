#!/usr/bin/env ruby
# frozen_string_literal: true

#
# individual-history — answer questions about what the troop's record says,
# from the database `import-individual-history` builds.
#
#   ruby scripts/history.rb show     NAME
#   ruby scripts/history.rb json     [NAME]
#   ruby scripts/history.rb needs    NAME [--rank RANK]
#   ruby scripts/history.rb eagle    [NAME]
#   ruby scripts/history.rb por      [NAME]
#   ruby scripts/history.rb partials [NAME] [--stalled DAYS]
#   ruby scripts/history.rb badge    BADGE
#   ruby scripts/history.rb who      LABEL
#   ruby scripts/history.rb roster
#
# This script READS. It never writes to the database and never opens a PDF —
# importing is `import-individual-history`, and it is the only writer. It also
# stops short of planning: it reports what the record says and what follows
# arithmetically from it, and never decides what a Scout should do next, in
# what order, or at which meeting. That is `generate-advancement-plan`.
#
# --------------------------------------------------------------------------
# Facts this script depends on
# --------------------------------------------------------------------------
#
# * **`eagle_required` cannot answer "which Eagle badges are left".** The flag
#   is set from the `*` TroopMaster prints beside a badge name, and the report
#   does not always print it: on the troop's current report Citizenship in
#   Society appears as `Citizenship in Society#` — the `#` marker, not `*` — so
#   it is stored `eagle_required = 0` for a badge that is squarely
#   Eagle-required. Eagle coverage is therefore computed against `EAGLE_SLOTS`
#   below, and the flag is only ever *displayed*, never counted.
#
# * **Three Eagle slots are OR-groups, so 14 slots are not 14 badges.**
#   Emergency Preparedness OR Lifesaving; Environmental Science OR
#   Sustainability; Swimming OR Hiking OR Cycling. Any one alternate fills its
#   slot, so counting earned Eagle-required badges overstates what is left.
#
# * **A position of responsibility counts only for the rank being worked on.**
#   The book reads "While a Star Scout, serve actively in your troop for six
#   months" — time served before the current rank was earned does not count
#   toward the next one. So tenure is clipped to start at the Scout's own
#   `rank_date`, which is why a Scout with years of leadership can still show
#   zero months toward Life.
#
# * **Positions overlap, so tenure is a union of intervals and not a sum.** The
#   troop's current report has a Scout holding Bugler and Patrol Leader over
#   the same six months. Adding the two terms would credit twelve months for
#   six months of calendar time. `Tenure.union_days` merges them first.
#
# * **`credited = 0` positions are excluded, and the book agrees.** The report
#   marks them with `#` ("Position not credited toward rank"); Scouts BSA
#   Requirements says in a footnote to Star, Life, and Eagle that assistant
#   patrol leader is not an approved position of responsibility. The troop's
#   report marks exactly that position. The two sources agree, so the stored
#   flag is trusted.
#
# * **TroopMaster and the book spell badges differently, and `normalize`
#   already reconciles them.** The report prints `Citizenship In Nation` where
#   the book prints `Citizenship in the Nation`; dropping "and"/"the" folds the
#   two together. This function must stay identical to the one in `req.rb`,
#   `mbc.rb`, `inventory.rb`, and `individual_history.rb`.
#
# * **`signed = 0` with a NULL `completed_on` means the report printed the
#   requirement as `__/__/__`** — the troop's record positively says it is not
#   done. A requirement absent from the table is a different thing: the report
#   never showed it. Nothing here may collapse the two.
#
# * **A rank with no requirement rows has been earned.** The report prints
#   blocks only for ranks not yet earned, so "no rows" is completion, never
#   "nothing done".
#
# --------------------------------------------------------------------------
# Privacy
# --------------------------------------------------------------------------
#
# Everything this script prints is about minors — names, and on `show` also
# email, phone, and date of birth. It is all fine to say in a session and to
# the Advancement Chair. None of it may reach a tracked file, a commit message,
# a branch name, or a PR description.

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "json"

require "sqlite3"

# The importing skill owns this file; this one only reads it.
IMPORT_SKILL = File.join(REPO_ROOT, ".claude", "skills", "import-individual-history")
DB_PATH      = File.join(IMPORT_SKILL, ".cache", "individual-history.db")

STALE_DAYS = 30

RANK_LADDER = ["Scout", "Tenderfoot", "Second Class", "First Class",
               "Star", "Life", "Eagle"].freeze

# Months of position-of-responsibility service each rank asks for. A threshold,
# not the requirement: the text that governs comes from `scout-req`, and only
# Star, Life, and Eagle ask for a position at all.
POR_MONTHS = { "Star" => 4, "Life" => 6, "Eagle" => 6 }.freeze

# The 14 Eagle-required slots, each an OR-group of the badges that fill it.
# **Match keys, not a copy of the book** — the same list `mbc.rb` carries for
# counselor coverage; keep the two in step. Requirement text comes from
# `scout-req`.
EAGLE_SLOTS = [
  ["First Aid"],
  ["Citizenship in the Community"],
  ["Citizenship in the Nation"],
  ["Citizenship in Society"],
  ["Citizenship in the World"],
  ["Communication"],
  ["Cooking"],
  ["Personal Fitness"],
  ["Emergency Preparedness", "Lifesaving"],
  ["Environmental Science", "Sustainability"],
  ["Personal Management"],
  ["Swimming", "Hiking", "Cycling"],
  ["Camping"],
  ["Family Life"]
].freeze

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# Fold spelling differences between TroopMaster, the requirements book, and
# whatever the user typed. **Identical to `normalize` in `req.rb`, `mbc.rb`,
# `inventory.rb`, and `individual_history.rb`** — "and" and "the" go because the
# book's own Merit Badge Library abbreviates that way.
IGNORED_WORDS = %w[and the].freeze

def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

def date_of(text)
  text.to_s.empty? ? nil : Date.parse(text.to_s)
rescue Date::Error
  nil
end

# --------------------------------------------------------------------------
# reading the database
# --------------------------------------------------------------------------
module DB
  module_function

  def handle
    @handle ||= begin
      unless File.exist?(DB_PATH)
        die "nothing imported yet — run `import` in the import-individual-history skill:\n  " \
            "ruby ../import-individual-history/scripts/individual_history.rb import"
      end
      db = SQLite3::Database.new(DB_PATH, readonly: true)
      db.results_as_hash = true
      db
    end
  end

  def query(sql, params = []) = handle.execute(sql, params)

  def scouts = query("SELECT * FROM scouts ORDER BY last_name, first_name")

  def record(key)
    scout = query("SELECT * FROM scouts WHERE key = ?", [key]).first or return nil

    scout.merge(
      "completed_ranks" => query(
        "SELECT rank, earned_on FROM completed_ranks WHERE key = ? ORDER BY rank_order", [key]
      ),
      "requirements" => query("SELECT * FROM requirements WHERE key = ? ORDER BY seq", [key]),
      "merit_badges" => query("SELECT * FROM merit_badges WHERE key = ? ORDER BY name", [key]),
      "partials" => query("SELECT * FROM partials WHERE key = ? ORDER BY name", [key]),
      "special_awards" => query("SELECT * FROM special_awards WHERE key = ? ORDER BY earned_on",
                                [key]),
      "leadership" => query("SELECT * FROM leadership WHERE key = ? ORDER BY start_date DESC",
                            [key])
    )
  end

  def records = scouts.map { |row| record(row["key"]) }

  # Match on "Last, First", "First Last", a last name, or a first name. An
  # ambiguous match is an error rather than a guess — an answer given about the
  # wrong Scout is worse than no answer.
  def resolve(name)
    rows = scouts
    want = normalize(name)
    hits = exact_hits(rows, want)
    hits = rows.select { |r| normalize(r["name"]).include?(want) } if hits.empty?

    die "no Scout matching #{name.inspect}; `roster` shows who has been imported" if hits.empty?
    die "#{name.inspect} matches #{hits.map { |r| r['name'] }.join(', ')} — be more specific" if
      hits.size > 1

    hits.first["key"]
  end

  def exact_hits(rows, want)
    exact = rows.select do |r|
      [normalize(r["name"]), normalize("#{r['first_name']} #{r['last_name']}")].include?(want)
    end
    return exact unless exact.empty?

    rows.select { |r| normalize(r["last_name"]) == want || normalize(r["first_name"]) == want }
  end
end

# --------------------------------------------------------------------------
# what follows arithmetically from the record
# --------------------------------------------------------------------------
module Status
  module_function

  def earned_ranks(rec) = rec["completed_ranks"].map { |r| r["rank"] }

  # The next rank on the ladder. Nil once Eagle is earned — Palms are tracked
  # in their own blocks and are not "the next rank".
  def next_rank(rec) = (RANK_LADDER - earned_ranks(rec)).first

  def remaining(rec, rank)
    rec["requirements"].select { |r| r["rank"] == rank && r["signed"].to_i != 1 }
  end

  def open_slots(reqs)
    reqs.select { |r| r["kind"] == "badge_slot" && r["badge"].to_s.empty? }
  end

  def report_age(rec)
    on = date_of(rec["report_date"]) or return nil
    (Date.today - on).to_i
  end

  # Eagle coverage, one entry per slot. Deliberately computed from the badge
  # names rather than from `eagle_required` — see the header.
  def eagle_slots(rec)
    earned  = rec["merit_badges"].to_h { |b| [normalize(b["name"]), b] }
    partial = rec["partials"].to_h { |p| [normalize(p["name"]), p] }

    EAGLE_SLOTS.map do |alternates|
      keys = alternates.map { |name| normalize(name) }
      { alternates: alternates,
        earned: keys.filter_map { |k| earned[k] }.first,
        partial: keys.filter_map { |k| partial[k] }.first }
    end
  end
end

# --------------------------------------------------------------------------
# position-of-responsibility tenure
# --------------------------------------------------------------------------
module Tenure
  DAYS_PER_MONTH = 30.44   # months are reported to one decimal, not counted

  module_function

  # Credited service toward `rank`, clipped to start when the Scout earned the
  # rank they hold now — time served earlier counts toward the rank it was
  # served under, not this one.
  def toward(rec, rank)
    since = date_of(rec["rank_date"])
    windows = since ? credited_windows(rec, since) : []
    days = union_days(windows)
    { rank: rank, since: since, days: days,
      months: (days / DAYS_PER_MONTH).round(1),
      needed: POR_MONTHS[rank], positions: windows.map { |w| w[2] }.uniq }
  end

  def credited_windows(rec, since)
    rec["leadership"].select { |post| post["credited"].to_i == 1 }.filter_map do |post|
      start = date_of(post["start_date"]) or next
      finish = post["current"].to_i == 1 ? Date.today : (date_of(post["end_date"]) || Date.today)
      low = [start, since].max
      finish > low ? [low, finish, post["position"]] : nil
    end
  end

  # Overlapping terms are one stretch of calendar time, not two. See the header.
  def union_days(windows)
    merged = []
    windows.sort_by(&:first).each do |low, high, _|
      if !merged.empty? && low <= merged.last[1]
        merged.last[1] = [merged.last[1], high].max
      else
        merged << [low, high]
      end
    end
    merged.sum { |low, high| (high - low).to_i }
  end
end

# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
module Render
  module_function

  def day(text) = text.to_s.empty? ? "—" : Date.parse(text.to_s).strftime("%b %-d, %Y")

  def age_note(rec)
    days = Status.report_age(rec) or return ""
    return " (report is today's)" if days <= 0

    stale = days > STALE_DAYS ? " — STALE, re-run the report" : ""
    " (report #{days}d old#{stale})"
  end

  # An OR-group slot names the alternate that actually filled it — "earned" on
  # a line reading "Swimming / Hiking / Cycling" otherwise leaves the reader to
  # guess which badge the Scout holds.
  def slot_line(slot)
    label = slot[:alternates].join(" / ")
    multi = slot[:alternates].size > 1
    if (got = slot[:earned])
      via = multi ? " #{got['name']}," : ""
      format("  [x] %-46s earned%s %s", label, via, day(got["earned_on"]))
    elsif (part = slot[:partial])
      via = multi ? "#{part['name']} " : ""
      open = part["open_reqts"].to_s.empty? ? "no open reqts recorded" : part["open_reqts"]
      format("  [~] %-46s %spartial %d%% (open %s)", label, via, part["percent"], open)
    else
      format("  [ ] %-46s not started", label)
    end
  end
end

# --------------------------------------------------------------------------
# the full record
# --------------------------------------------------------------------------
module ShowRecord
  module_function

  def call(rec)
    header(rec)
    ranks(rec)
    badges(rec)
    puts
    other(rec)
  end

  def header(rec)
    puts "#{rec['name']}   —   Troop #{rec['troop']}"
    puts format("  Rank %s (%s)   Patrol %s", rec["rank"], Render.day(rec["rank_date"]),
                rec["patrol"])
    puts format("  Age %s   Joined %s   Position %s", rec["age"] || "—",
                Render.day(rec["joined"]), rec["position"].to_s.empty? ? "—" : rec["position"])
    puts format("  Camping %s nights   Hiking %s miles   Service %s hours",
                rec["nights_camping"], rec["miles_hiking"], rec["service_hours"])
    puts format("  From %s, report dated %s%s", rec["source_file"],
                Render.day(rec["report_date"]), Render.age_note(rec))
    puts
  end

  def ranks(rec)
    puts "Completed ranks"
    rec["completed_ranks"].each do |rank|
      puts format("  %-14s %s", rank["rank"], Render.day(rank["earned_on"]))
    end
    rec["requirements"].group_by { |req| req["rank"] }.each { |rank, reqs| block(rank, reqs) }
  end

  def block(rank, reqs)
    puts "\n#{rank} — #{reqs.count { |req| req['signed'].to_i == 1 }} of #{reqs.size} signed off"
    open = reqs.reject { |req| req["signed"].to_i == 1 }
    slots, rest = open.partition { |req| req["kind"] == "badge_slot" && req["badge"].to_s.empty? }
    rest.each do |req|
      puts format("  [ ] %-6s %s%s", req["req_id"] || "", req["label"],
                  req["note"] ? " #{req['note']}" : "")
    end
    return if slots.empty?

    puts format("  [ ] %-6s %d more merit badge%s", "", slots.size, slots.size == 1 ? "" : "s")
  end

  def badges(rec)
    puts "\nMerit badges (#{rec['merit_badges'].size})"
    rec["merit_badges"].each do |badge|
      eagle = badge["eagle_required"].to_i == 1 ? "  (Eagle-required)" : ""
      puts format("  %-32s %s%s", badge["name"], Render.day(badge["earned_on"]), eagle)
    end
    return if rec["partials"].empty?

    puts "\nPartial merit badges (#{rec['partials'].size})"
    rec["partials"].each { |part| partial(part) }
  end

  def partial(part)
    counselor = if part["counselor"].to_s.empty?
                  "no counselor recorded"
                else
                  "counselor " \
                    "#{part['counselor']}"
                end
    puts format("  %-32s %3d%%  %s", "#{part['name']} (#{part['req_year']})",
                part["percent"], counselor)
    puts "        open: #{part['open_reqts']}"
  end

  def other(rec)
    unless rec["special_awards"].empty?
      puts "Special awards"
      rec["special_awards"].each do |award|
        puts format("  %-32s %s", award["name"], Render.day(award["earned_on"]))
      end
      puts
    end
    puts "Leadership"
    return puts "  (none recorded)" if rec["leadership"].empty?

    rec["leadership"].each { |post| position(post) }
  end

  def position(post)
    finish = post["current"].to_i == 1 ? "present" : Render.day(post["end_date"])
    credit = post["credited"].to_i == 1 ? "" : "  (not credited toward rank)"
    puts format("  %-26s %s – %s%s", post["position"], Render.day(post["start_date"]),
                finish, credit)
  end
end

# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------
module Query
  POR_ROW = "%<name>-26s %<rank>-6s %<months>4.1f of %<needed>d months  " \
            "(%<short>s)  %<positions>s"

  module_function

  def show(key) = ShowRecord.call(DB.record(key))

  def json(keys)
    records = keys.map { |key| DB.record(key) }
    puts JSON.pretty_generate(records.size == 1 ? records.first : records)
  end

  # What the record says is unsigned for a rank. Facts only — the ordering of
  # the work, and what is realistic by when, is `generate-advancement-plan`.
  def needs(key, rank)
    rec = DB.record(key)
    rank ||= Status.next_rank(rec) or return puts "#{rec['name']} has earned every rank."
    reqs = Status.remaining(rec, rank)
    puts "#{rec['name']} — #{rank}#{Render.age_note(rec)}"
    return puts "  nothing outstanding; the report prints no open #{rank} requirement." if
      reqs.empty?

    needs_lines(reqs)
    needs_por(rec, rank)
  end

  def needs_lines(reqs)
    slots = Status.open_slots(reqs)
    rest = reqs - Status.open_slots(reqs)
    rest.each do |req|
      puts format("  [ ] %-6s %s%s", req["req_id"] || "", req["label"],
                  req["note"] ? " #{req['note']}" : "")
    end
    return if slots.empty?

    puts format("  [ ] %-6s %d more merit badge%s", "", slots.size, slots.size == 1 ? "" : "s")
  end

  def needs_por(rec, rank)
    return unless POR_MONTHS.key?(rank)

    t = Tenure.toward(rec, rank)
    puts "\n  Position of responsibility — #{t[:months]} of #{t[:needed]} months " \
         "since #{rec['rank']} on #{Render.day(rec['rank_date'])}"
    puts "  counting #{if t[:positions].empty?
                         '(no credited position in that window)'
                       else
                         t[:positions].join(', ')
                       end}"
  end

  def eagle(keys)
    keys.each do |key|
      rec = DB.record(key)
      slots = Status.eagle_slots(rec)
      done = slots.count { |s| s[:earned] }
      puts "#{rec['name']} — #{done} of 14 Eagle-required slots filled#{Render.age_note(rec)}"
      slots.each { |slot| puts Render.slot_line(slot) }
      puts
    end
  end

  def por(keys)
    keys.each do |key|
      rec  = DB.record(key)
      rank = Status.next_rank(rec)
      unless rank && POR_MONTHS.key?(rank)
        puts format("%-26s %s asks for no position of responsibility", rec["name"], rank || "—")
        next
      end
      t = Tenure.toward(rec, rank)
      short = t[:months] >= t[:needed] ? "met" : "#{(t[:needed] - t[:months]).round(1)} short"
      puts format(POR_ROW, name: rec["name"], rank: rank, months: t[:months],
                           needed: t[:needed], short: short,
                           positions: t[:positions].join(", "))
    end
  end
end

# --------------------------------------------------------------------------
# troop-wide questions, over the same rows
# --------------------------------------------------------------------------
module Troop
  ROSTER_ROW = "%<name>-22s %<rank>-12s %<next_rank>-12s %<open>5s  %<por>-14s %<report>s"

  module_function

  def partials(keys, stalled)
    rows = keys.flat_map { |key| partial_rows(DB.record(key)) }
    rows = rows.select { |r| r[:idle] && r[:idle] > stalled } if stalled
    return puts(stalled ? "no partial has been idle that long" : "no partials recorded") if
      rows.empty?

    rows.sort_by { |r| [-(r[:idle] || 0), r[:name]] }
        .each do |r|
      puts format("%-22s %-31s %3d%%  %s", r[:scout], r[:label], r[:percent],
                  r[:idle] ? "idle #{r[:idle]}d" : "no progress date")
    end
  end

  def partial_rows(rec)
    rec["partials"].map do |part|
      on = date_of(part["last_progress"])
      { scout: rec["name"], name: part["name"],
        label: "#{part['name']} (#{part['req_year']})",
        percent: part["percent"].to_i, idle: on && (Date.today - on).to_i }
    end
  end

  # Who has this badge, who has it started, and who has not touched it. The
  # three are different answers and the caller usually wants all three.
  def badge(query)
    want = normalize(query)
    earned = []
    started = []
    none = []
    DB.records.each do |rec|
      if (got = rec["merit_badges"].find { |b| normalize(b["name"]) == want })
        earned << format("%-22s earned %s", rec["name"], Render.day(got["earned_on"]))
      elsif (part = rec["partials"].find { |p| normalize(p["name"]) == want })
        started << format("%-22s %d%%  open %s", rec["name"], part["percent"],
                          part["open_reqts"])
      else
        none << rec["name"]
      end
    end
    badge_report(query, earned, started, none)
  end

  def badge_report(query, earned, started, none)
    if earned.empty? && started.empty?
      puts "no Scout in the database has started #{query}."
      puts "That is a fact about the imported Scouts, not about the badge — " \
           "`req.rb show` says whether it is one."
      return
    end
    section("Earned", earned)
    section("Partial", started)
    section("Not started", none.map { |n| "  #{n}" }.tap { |l| l.each { |x| x } })
  end

  def section(title, lines)
    return if lines.empty?

    puts "#{title} (#{lines.size})"
    lines.each { |line| puts line.start_with?("  ") ? line : "  #{line}" }
    puts
  end

  # Who has a given requirement label still unsigned, across everyone imported.
  # The report prints a requirement block for EVERY rank a Scout has not
  # earned, so a Scout-rank Scout matches "Position of Responsibility" three
  # times over — at Star, Life, and Eagle. `--rank` narrows it; without it the
  # rank column is what keeps the answer honest.
  def who(label, rank)
    want = normalize(label)
    hits = DB.records.flat_map { |rec| who_hits(rec, want, rank) }
    scope = rank ? " at #{rank}" : ""
    return puts "no Scout has an unsigned requirement matching #{label.inspect}#{scope}" if
      hits.empty?

    puts "Unsigned and matching #{label.inspect}#{scope} (#{hits.size}):"
    hits.each { |line| puts "  #{line}" }
  end

  def who_hits(rec, want, rank)
    rec["requirements"]
      .select { |r| r["signed"].to_i != 1 && normalize(r["label"]).include?(want) }
      .select { |r| rank.nil? || normalize(r["rank"]) == normalize(rank) }
      .map { |r| format("%-22s %-12s %s", rec["name"], r["rank"], r["label"]) }
  end

  def roster
    puts format(ROSTER_ROW, name: "SCOUT", rank: "RANK", next_rank: "WORKING ON",
                            open: "OPEN", por: "POR", report: "REPORT")
    DB.records.each { |rec| puts roster_line(rec) }
    puts "\n\"OPEN\" counts unsigned requirements for the next rank; \"POR\" is credited " \
         "months\nserved since that Scout earned the rank they hold. Neither is a plan."
  end

  def roster_line(rec)
    rank = Status.next_rank(rec)
    open = rank ? Status.remaining(rec, rank).size : 0
    days = Status.report_age(rec)
    format(ROSTER_ROW, name: rec["name"], rank: rec["rank"], next_rank: rank || "—",
                       open: rank ? open : "—", por: roster_por(rec, rank),
                       report: days && days > STALE_DAYS ? "#{days}d STALE" : "#{days}d")
  end

  def roster_por(rec, rank)
    return "n/a" unless rank && POR_MONTHS.key?(rank)

    t = Tenure.toward(rec, rank)
    format("%.1f/%d mo", t[:months], t[:needed])
  end
end

USAGE = <<~TEXT
  usage: ruby scripts/history.rb COMMAND [NAME] [options]

  One Scout:
    show     NAME               everything the record holds
    json     [NAME]             the same, machine-readable; everyone if no name
    needs    NAME [--rank R]    what is unsigned for the next rank, or rank R
    eagle    [NAME]             the 14 Eagle-required slots; everyone if no name
    por      [NAME]             credited months toward the next rank's position

  The whole troop:
    roster                      rank, what each is working on, open count, POR
    who      LABEL [--rank R]   who still has this requirement unsigned
    badge    BADGE              who earned it, who started it, who has not
    partials [NAME] [--stalled DAYS]   open partials, most idle first

  NAME matches "Last, First", "First Last", a last name, or a first name; an
  ambiguous name is an error rather than a guess.

  This skill reads the database `import-individual-history` writes. If nothing
  has been imported yet, or the data is stale, run that skill first. It reports
  what the record says; it does not decide what a Scout should work on next.

  Everything printed here is about minors. It never belongs in a tracked file,
  a commit message, or a PR description.
TEXT

args    = ARGV.dup
command = args.shift
rank    = if (i = args.index("--rank"))
            args.delete_at(i + 1).tap { args.delete_at(i) }
          end
stalled = if (i = args.index("--stalled"))
            args.delete_at(i + 1).to_i.tap { args.delete_at(i) }
          end
target = args.shift

all_or_one = -> { target ? [DB.resolve(target)] : DB.scouts.map { |r| r["key"] } }

case command
when "show"     then Query.show(DB.resolve(target || die(USAGE)))
when "json"     then Query.json(all_or_one.call)
when "needs"    then Query.needs(DB.resolve(target || die(USAGE)), rank)
when "eagle"    then Query.eagle(all_or_one.call)
when "por"      then Query.por(all_or_one.call)
when "partials" then Troop.partials(all_or_one.call, stalled)
when "badge"    then Troop.badge(target || die(USAGE))
when "who"      then Troop.who(target || die(USAGE), rank)
when "roster"   then Troop.roster
else abort USAGE
end
