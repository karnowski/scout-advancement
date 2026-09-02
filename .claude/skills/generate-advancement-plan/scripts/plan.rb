#!/usr/bin/env ruby
# frozen_string_literal: true

#
# generate-advancement-plan — the dated arithmetic behind one Scout's
# advancement plan.
#
#   ruby scripts/plan.rb brief  NAME [--by DATE] [--start DATE] [--test-date DATE]
#   ruby scripts/plan.rb ladder NAME
#   ruby scripts/plan.rb clocks NAME [--by DATE] [--start DATE] [--test-date DATE]
#   ruby scripts/plan.rb badges NAME [--by DATE] [--start DATE]
#   ruby scripts/plan.rb names  NAME
#   ruby scripts/plan.rb json   NAME [options]
#   ruby scripts/plan.rb verify
#
# This script decides *when*. It does not decide what a requirement says, who
# counsels a badge, or what is on the calendar — those are `scout-req`, `mbc`,
# and `troop-calendar`, and the plan is written from all four.
#
# --------------------------------------------------------------------------
# Facts this script depends on
# --------------------------------------------------------------------------
#
# * **The record comes from `history.rb json`, never from the database.** The
#   importing skill owns the file and `individual-history` is its reader; going
#   round that reader would give the plan its own name matching, its own
#   freshness rule, and its own chance to describe a Scout the reporting skill
#   does not. Shelling out costs one process and makes the two provably the
#   same record.
#
# * **There are three kinds of clock and they are not interchangeable.**
#   Conflating them is how a plan gets a confident, specific, wrong date:
#
#     - *Elapsed* — active participation and position-of-responsibility tenure.
#       Calendar time passes whether or not the Scout is doing anything about
#       it, so these are computed from real dates already in the record
#       (`rank_date`, position start dates) and the date they come due is a
#       fact, not a projection.
#
#     - *Work-start* — Tenderfoot 6b/6c, Second Class 7a, First Class 8a,
#       Personal Management 2, Personal Fitness 7/8, Family Life 3, Gardening 5,
#       Multisport 5. "30 days" here means 30 days of *tracked work*, so the
#       clock starts when the Scout starts, which the record cannot know. These
#       run from `--start` (default today), never from a date in the record.
#
#     - *Opportunity* — Camping 9a's 20 nights, Citizenship in the Community
#       7's 8 volunteer hours, Personal Fitness 1's physical and dental exams.
#       These are not a span of calendar at all; they need events or an
#       appointment. `--by` deliberately prints no date for them, because the
#       one thing it must not do is invent one.
#
# * **A sign-off date on the previous link does not start the next one.** A
#   Scout whose Tenderfoot 6a was signed six months ago has not thereby banked
#   30 days of 6b tracking — 6b is a log the Scout keeps, and nobody kept it.
#   The record's dates say which links are *done*; `--start` says when the
#   remaining ones can begin.
#
# * **POR tenure is a union of intervals clipped to the Scout's own
#   `rank_date`**, and this is the second copy of that algorithm — the first is
#   `Tenure` in `history.rb`. It is duplicated rather than shared because the
#   skills are siblings with no library between them, and `verify` cross-checks
#   every Scout's months against `history.rb por` so the copy cannot drift
#   unnoticed.
#
# * **`EAGLE_SLOTS` is the third copy** — `mbc.rb` and `history.rb` carry the
#   other two, and all three must stay in step. It holds **13 slots, not the 14
#   printed at Eagle requirement 3**: the troop does not count Citizenship in
#   Society as filling a required slot, though it still counts toward the 21
#   badges Eagle asks for. That is a decision of the troop's rather than a
#   reading of the book; `individual-history` sets out the evidence. `verify`
#   compares this table against the slot labels `history.rb eagle` prints.
#
# * **Every table here is match keys, not requirement text.** `CLOCKS`,
#   `BADGE_PREREQS`, `FITNESS_CHAIN`, `ACTIVE_MONTHS`, and `POR_MONTHS` exist so
#   a span can be found and a Scout sorted onto it. The wording that decides
#   whether a span can actually be compressed comes from `scout-req`, and
#   `verify` resolves every badge name in them against `req.rb list --kind
#   badge` — a badge renamed in the book otherwise disables its rule in silence.
#
# * **Palms are ranks in the record but not on the ladder.** The report prints
#   `Bronze Palm`, `2nd Gold Palm` and so on as blocks of their own. They are
#   reported as remaining work and given no clock arithmetic; the ladder ends at
#   Eagle.
#
# * **The 18th birthday is the one deadline that cannot move.** Eagle
#   requirements 1-6, the project included, must be complete before it; only the
#   board of review may follow. `deadline` prints the date and the days left
#   from `dob`, and says so plainly when `dob` is missing — a blank there breaks
#   the Eagle application later, so it is a finding rather than a blank line.
#
# --------------------------------------------------------------------------
# Privacy
# --------------------------------------------------------------------------
#
# Everything this script prints is about a minor. It is fine in a session, in a
# plan under `plans/`, and in an answer to the Advancement Chair. It never
# belongs in a tracked file, a commit message, a branch name, or a PR
# description.

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "json"
require "open3"
require "rbconfig"

SKILLS         = File.join(REPO_ROOT, ".claude", "skills")
HISTORY_SCRIPT = File.join(SKILLS, "individual-history", "scripts", "history.rb")
REQ_SCRIPT     = File.join(SKILLS, "scout-req", "scripts", "req.rb")
SETTINGS       = File.join(REPO_ROOT, "TROOP-SETTINGS.md")

STALE_DAYS   = 30
EAGLE_AGE    = 18
DAYS_PER_MONTH = 30.44   # matches `history.rb`; months are measured, not counted

RANK_LADDER = ["Scout", "Tenderfoot", "Second Class", "First Class",
               "Star", "Life", "Eagle"].freeze

# Months of credited service each rank asks for, and months of active
# participation in the rank below. Thresholds, not the requirement.
POR_MONTHS    = { "Star" => 4, "Life" => 6, "Eagle" => 6 }.freeze
ACTIVE_MONTHS = { "Star" => 4, "Life" => 6, "Eagle" => 6 }.freeze
ACTIVE_FROM   = { "Star" => "First Class", "Life" => "Star", "Eagle" => "Life" }.freeze

# The 13 Eagle-required slots, each an OR-group. Third copy; see the header.
EAGLE_SLOTS = [
  ["First Aid"],
  ["Citizenship in the Community"],
  ["Citizenship in the Nation"],
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

# The sequential fitness chain, Tenderfoot through First Class. Each link needs
# the one before it finished, so a Scout advancing two ranks in a season cannot
# overlap them. 6a costs no days of its own — it is the test the later links
# measure against — but nothing downstream can start until someone runs it.
FITNESS_CHAIN = [
  { rank: "Tenderfoot",   req: "6a", short: "T6a",  days: 0,
    note: "the fitness test everything downstream is measured against" },
  { rank: "Tenderfoot",   req: "6b", short: "T6b",  days: 30,
    note: "30 days of tracked activity" },
  { rank: "Tenderfoot",   req: "6c", short: "T6c",  days: 30,
    note: "show improvement after 30 days of practice" },
  { rank: "Second Class", req: "7a", short: "2C7a", days: 28,
    note: "four weeks of activity, after Tenderfoot 6c" },
  { rank: "First Class",  req: "8a", short: "1C8a", days: 28,
    note: "four weeks of activity, after Second Class 7a" }
].freeze

# Merit badge requirements that cannot be compressed. `days` is a span of
# calendar; `nil` days is an opportunity — nights, hours, or an appointment —
# which no target date can schedule on its own.
CLOCKS = [
  { badge: "Personal Management", req: "2", span: "13 consecutive weeks", days: 91,
    note: "req. 2a's budget and 2c's tracking must cover the same 13 weeks" },
  { badge: "Personal Fitness", req: "1", span: "gate", days: nil,
    note: "physical and dental exams must precede reqs. 2-9 — book them first" },
  { badge: "Personal Fitness", req: "7", span: "12 weeks", days: 84,
    note: "req. 7 outlines the program, req. 8 completes it, retesting every 4 weeks" },
  { badge: "Personal Fitness", req: "8", span: "12 weeks", days: 84,
    note: "the second half of the same 12 weeks as req. 7" },
  { badge: "Family Life", req: "3", span: "90 days", days: 90,
    note: "req. 3 keeps a record of home duties for 90 days" },
  { badge: "Gardening", req: "5", span: "90 days", days: 90,
    note: "req. 5 maintains a bin or garden for 90 days" },
  { badge: "Multisport", req: "5", span: "4 weeks", days: 28,
    note: "req. 5 is a four-week training plan with a tracked chart" },
  { badge: "Camping", req: "9", span: "20 nights", days: nil,
    note: "req. 9a is 20 nights of camping; 9b needs two outdoor activities" },
  { badge: "Citizenship in the Community", req: "7", span: "8 volunteer hours", days: nil,
    note: "req. 7c volunteers 8 hours for the chosen organization" }
].freeze

# Badges whose requirement 1 is another badge. Finishing the prerequisite closes
# the dependent requirement outright.
BADGE_PREREQS = {
  "Emergency Preparedness" => { req: "1", needs: "First Aid" }
}.freeze

# Requirement labels the clock rules key off. TroopMaster's own wording, not the
# book's; `verify` asserts each still appears in the imported data.
LABELS = { active: "Participation", por: "Position of Responsibility",
           spirit: "Scout Spirit", smc: "Scoutmaster Conference",
           bor: "Board of Review", service: "Service Project",
           project: "Eagle Project" }.freeze

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# Identical to `normalize` in `history.rb`, `req.rb`, `mbc.rb`, `inventory.rb`,
# and `individual_history.rb`.
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
# the record, from `individual-history` rather than from the database
# --------------------------------------------------------------------------
module Record
  module_function

  def one(name)
    rows = fetch(["json", name])
    die "no record came back for #{name.inspect}" if rows.empty?
    die "#{name.inspect} matched #{rows.size} Scouts — be more specific" if rows.size > 1

    rows.first
  end

  def all = fetch(["json"])

  def fetch(args)
    out, err, status = Open3.capture3(RbConfig.ruby, HISTORY_SCRIPT, *args)
    die "individual-history could not read the record:\n  #{err.strip}" unless status.success?

    # `history.rb json` prints a bare object for one Scout and an array for
    # several, so a troop of one and a named Scout arrive the same shape.
    parsed = JSON.parse(out)
    parsed.is_a?(Array) ? parsed : [parsed]
  rescue JSON::ParserError => e
    die "individual-history returned something that is not JSON (#{e.message})"
  end

  # `history.rb`'s own rendering, used by `verify` to prove this script's copies
  # of the tenure and Eagle-slot logic still agree with the reporting skill's.
  def text(args)
    out, _err, status = Open3.capture3(RbConfig.ruby, HISTORY_SCRIPT, *args)
    status.success? ? out : nil
  end
end

# --------------------------------------------------------------------------
# what follows arithmetically from the record
# --------------------------------------------------------------------------
module Status
  module_function

  def earned_ranks(rec) = rec["completed_ranks"].map { |r| r["rank"] }

  # The next rank on the ladder; nil once Eagle is earned. Palms are blocks of
  # their own and are never "the next rank".
  def next_rank(rec) = (RANK_LADDER - earned_ranks(rec)).first

  def unearned_ranks(rec) = RANK_LADDER - earned_ranks(rec)

  def palm_blocks(rec) = rec["rank_blocks"].map { |b| b["rank"] } - RANK_LADDER

  def for_rank(rec, rank) = rec["requirements"].select { |r| r["rank"] == rank }

  # Program work only. A filled merit badge slot is a badge earned, not a rank
  # requirement signed, and counting the two together makes every Scout with
  # badges toward Eagle look as though they had banked rank work above them.
  def signed_reqs(rec, rank)
    for_rank(rec, rank).select { |r| r["kind"] != "badge_slot" && r["signed"].to_i == 1 }
  end

  def open_reqs(rec, rank)
    for_rank(rec, rank).select { |r| r["kind"] != "badge_slot" && r["signed"].to_i != 1 }
  end

  def open_slots(rec, rank)
    for_rank(rec, rank).select { |r| r["kind"] == "badge_slot" && r["badge"].to_s.empty? }
  end

  def signed?(rec, rank, label)
    row = for_rank(rec, rank).find { |r| r["label"] == label }
    row && row["signed"].to_i == 1
  end

  def requirement(rec, rank, req_id)
    for_rank(rec, rank).find { |r| r["req_id"] == req_id }
  end

  def report_age(rec)
    on = date_of(rec["report_date"]) or return nil
    (Date.today - on).to_i
  end

  def eighteenth(rec)
    on = date_of(rec["dob"]) or return nil
    on >> (EAGLE_AGE * 12)
  end

  # Eagle coverage, one entry per slot, computed from the badge names rather
  # than from `eagle_required` — see `individual-history` for why the flag
  # cannot answer this.
  def eagle_slots(rec)
    earned  = rec["merit_badges"].to_h { |b| [normalize(b["name"]), b] }
    partial = rec["partials"].to_h { |p| [normalize(p["name"]), p] }

    EAGLE_SLOTS.map do |alternates|
      keys = alternates.map { |name| normalize(name) }
      { alternates: alternates, label: alternates.join(" / "),
        earned: keys.filter_map { |k| earned[k] }.first,
        partial: keys.filter_map { |k| partial[k] }.first }
    end
  end
end

# --------------------------------------------------------------------------
# position-of-responsibility tenure — second copy; `verify` keeps it honest
# --------------------------------------------------------------------------
module Tenure
  module_function

  def toward(rec, rank)
    since   = date_of(rec["rank_date"])
    windows = since ? credited_windows(rec, since) : []
    days    = union_days(windows)
    anchor  = windows.map(&:first).min || Date.today

    { rank: rank, since: since, days: days, anchor: anchor,
      months: (days / DAYS_PER_MONTH).round(1), needed: POR_MONTHS[rank],
      needed_days: ((anchor >> POR_MONTHS[rank].to_i) - anchor).to_i,
      running: running(rec), positions: windows.map { |w| w[2] }.uniq }
  end

  def running(rec)
    rec["leadership"]
      .select { |p| p["credited"].to_i == 1 && p["current"].to_i == 1 }
      .map { |p| p["position"] }
  end

  def credited_windows(rec, since)
    rec["leadership"].select { |post| post["credited"].to_i == 1 }.filter_map do |post|
      start  = date_of(post["start_date"]) or next
      finish = post["current"].to_i == 1 ? Date.today : (date_of(post["end_date"]) || Date.today)
      low    = [start, since].max
      finish > low ? [low, finish, post["position"]] : nil
    end
  end

  # Overlapping terms are one stretch of calendar time, not two.
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
# the date the plan is written against
# --------------------------------------------------------------------------
#
# `--by` wins. Failing that the next court of honor is read out of
# TROOP-SETTINGS.md, because a plan aimed at no date makes no decisions — but
# the table is hand-kept, so what was found and why is always printed.
module Horizon
  HEADING = /^\#+\s*courts?\s+of\s+honou?r/i
  ROW     = /^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*([^|]*?)\s*\|/

  module_function

  def target(explicit)
    if explicit
      date = date_of(explicit) or die "--by #{explicit.inspect} is not a YYYY-MM-DD date"
      return { date: date, source: "--by", note: nil }
    end
    from_settings || { date: nil, source: "none",
                       note: "no court of honor after today in TROOP-SETTINGS.md — " \
                             "pass --by to date the plan" }
  end

  def from_settings
    row = rows.select { |coh, _| coh > Date.today }.min_by(&:first) or return nil
    coh, cutoff = row
    { date: cutoff || coh, source: "TROOP-SETTINGS.md",
      coh: coh, cutoff: cutoff,
      note: if cutoff
              nil
            else
              "no cut-off date recorded for that court of honor; " \
                "using the ceremony date itself"
            end }
  end

  def rows
    return [] unless File.file?(SETTINGS)

    after = File.read(SETTINGS).split(HEADING, 2)[1] or return []
    after.split(/^\#\#/, 2).first.to_s.lines.filter_map do |line|
      m = line.match(ROW) or next
      [Date.parse(m[1]), date_of(m[2])]
    end
  end
end

# --------------------------------------------------------------------------
# the clocks
# --------------------------------------------------------------------------
#
# Every row is `{kind:, label:, detail:, earliest:, reason:, days:}`. `kind` is
# what decides how a date may be used, and the three are not interchangeable —
# see the header. `earliest` is nil exactly when no date can honestly be given,
# and `reason` then says why.
module Clocks
  module_function

  def rows(rec, opts)
    rank = Status.next_rank(rec)
    return [] unless rank

    [*elapsed(rec, rank), *fitness(rec, opts), *badges(rec, opts)]
  end

  # --- elapsed: the record already knows the date -------------------------

  def elapsed(rec, rank)
    return [] unless ACTIVE_MONTHS.key?(rank)

    [active(rec, rank), position(rec, rank)].compact
  end

  def active(rec, rank)
    return nil if Status.signed?(rec, rank, LABELS[:active])

    months = ACTIVE_MONTHS[rank]
    held   = date_of(rec["rank_date"])
    detail = "#{months} months active as a #{ACTIVE_FROM[rank]} Scout"
    unless held
      return row(:elapsed, LABELS[:active], detail, nil,
                 reason: "no #{ACTIVE_FROM[rank]} rank date — TroopMaster cannot date it")
    end

    due = held >> months
    row(:elapsed, LABELS[:active], "#{detail}, from #{Render.day(held)}",
        [due, Date.today].max,
        reason: due <= Date.today ? "the time is served; it needs signing" : nil)
  end

  def position(rec, rank)
    return nil if Status.signed?(rec, rank, LABELS[:por])

    t = Tenure.toward(rec, rank)
    detail = format("%.1f of %d months credited since %s", t[:months], t[:needed],
                    t[:since] ? Render.day(t[:since]) : "an unknown rank date")
    if t[:days] >= t[:needed_days]
      return row(:elapsed, LABELS[:por], detail, Date.today,
                 reason: "the time is served; it needs signing")
    end

    position_open(t, detail)
  end

  # A Scout with no credited position running has no clock at all, which is a
  # different and much larger problem than a clock that has not finished.
  def position_open(tenure, detail)
    short = tenure[:needed_days] - tenure[:days]
    if tenure[:running].empty?
      row(:elapsed, LABELS[:por], detail, nil,
          reason: "no credited position running — nothing is accruing; " \
                  "#{short} days short, so the earliest finish is #{short} days after one starts")
    else
      row(:elapsed, LABELS[:por], "#{detail}, #{tenure[:running].join(', ')} running",
          Date.today + short)
    end
  end

  # --- work-start: the clock starts when the Scout starts ------------------

  # The links a Scout still has to run, in order. Troop 400 reads Tenderfoot 6b
  # and 6c as the same 30 days; `--tenderfoot-6bc sequential` runs them back to
  # back for a troop that reads it the other way. TROOP-SETTINGS.md settles it,
  # not the book.
  def fitness(rec, opts)
    open = FITNESS_CHAIN.reject { |link| chain_done?(rec, link) }
    return [] if open.empty?

    cursor = opts[:start]
    merge_6bc(open, opts[:shared_6bc]).map do |link|
      cursor = link[:days].zero? ? [opts[:test_date], cursor].max : cursor + link[:days]
      # The span carried forward is *cumulative*, not this link's own 30 or 28
      # days. Each link needs the one above it finished, so the date that has to
      # be met to make a target is when the whole remaining chain starts — a
      # per-link start-by would say First Class 8a can begin four weeks out when
      # in truth it is twelve.
      span = (cursor - opts[:start]).to_i
      row(:work, "#{link[:rank]} #{link[:req]}", link[:note], cursor,
          days: span.zero? ? nil : span).merge(chain: true)
    end
  end

  def chain_done?(rec, link)
    row = Status.requirement(rec, link[:rank], link[:req])
    row.nil? || row["signed"].to_i == 1
  end

  def merge_6bc(open, shared)
    return open unless shared

    b = open.index { |l| l[:req] == "6b" }
    c = open.index { |l| l[:req] == "6c" }
    return open unless b && c

    merged = { rank: "Tenderfoot", req: "6b/6c", days: 30,
               note: "one shared 30-day log (Troop 400's reading)" }
    open[0...b] + [merged] + open[(c + 1)..]
  end

  # --- merit badge spans ---------------------------------------------------

  # Merit badge spans are scheduled for a Scout working Star or above, and for
  # any badge already started at any rank. Below Star no badge is required at
  # all, so listing every unfilled Eagle slot's clock for a Tenderfoot Scout
  # buries the fitness chain that actually decides their next rank under work
  # nobody has asked them to do.
  def badges(rec, opts)
    slots = ACTIVE_MONTHS.key?(Status.next_rank(rec))
    in_play = Badges.in_play(rec, eagle_slots: slots)
    CLOCKS.filter_map do |clock|
      # `in_play` stores nil against a badge nobody has started, so this has to
      # ask whether the key is present rather than whether the value is truthy —
      # otherwise the badges whose whole clock is still ahead of them, which are
      # the ones a plan most needs to start, are the ones silently dropped.
      key = normalize(clock[:badge])
      next unless in_play.key?(key)

      partial = in_play[key]
      next unless open_req?(partial, clock[:req])

      badge_row(clock, partial, opts)
    end
  end

  def badge_row(clock, _partial, opts)
    label  = "#{clock[:badge]} req. #{clock[:req]}"
    detail = "#{clock[:span]} — #{clock[:note]}"
    unless clock[:days]
      return row(:opportunity, label, detail, nil,
                 reason: "scheduled against an opportunity, not a span of calendar")
    end

    row(:work, label, detail, opts[:start] + clock[:days], days: clock[:days])
  end

  # A badge nobody has started has every requirement open; a partial's open list
  # is matched on the leading number, the way the report writes it ("9b1").
  def open_req?(partial, want)
    return true if partial.nil? || partial["open_reqts"].to_s.empty?

    partial["open_reqts"].split(",").map(&:strip).any? { |code| code[/\A\d+/] == want }
  end

  def row(kind, label, detail, earliest, reason: nil, days: nil)
    { kind: kind, label: label, detail: detail, earliest: earliest, reason: reason, days: days }
  end

  # `--by` turns an earliest date into a verdict. A work-start clock also gets a
  # latest start date, which is the number the plan actually schedules against.
  # When no date can be given, the verdict *is* the reason. "Unschedulable"
  # alone would bury the finding — a Life Scout with no credited position
  # running has the largest problem in their record, and it is the reason
  # string that says so.
  def verdict(row, target)
    return { text: row[:reason] || "no target date to judge against", makes: nil } unless target
    return { text: row[:reason] || "no date can be given", makes: nil } unless row[:earliest]

    slack = (target - row[:earliest]).to_i
    { text: slack >= 0 ? "makes it, #{slack} days spare" : "MISSES by #{-slack} days",
      makes: slack >= 0, slack: slack, start_by: row[:days] ? target - row[:days] : nil }
  end
end

# --------------------------------------------------------------------------
# the ladder — what is blocked behind what
# --------------------------------------------------------------------------
#
# Scout through First Class "may be worked on simultaneously; however, these
# ranks must be earned in sequence" (Guide to Advancement 2025, 4.2.0.1), so a
# Scout can have a pile of First Class work signed and still be stuck behind
# Tenderfoot. That pile is the highest-yield thing in any record: a handful of
# cheap items at the working rank converts all of it into rank.
module Ladder
  module_function

  def rungs(rec)
    working = Status.next_rank(rec)
    Status.unearned_ranks(rec).map do |rank|
      open  = Status.open_reqs(rec, rank)
      slots = Status.open_slots(rec, rank)
      { rank: rank, working: rank == working,
        above: RANK_LADDER.index(rank) > RANK_LADDER.index(working),
        open: open, open_slots: slots.size,
        signed: Status.signed_reqs(rec, rank).size }
    end
  end

  # Program work already signed in ranks *above* the one being worked on.
  def banked(rec)
    rungs(rec).select { |r| r[:above] }.sum { |r| r[:signed] }
  end

  # A sign-off recorded out of order on the fitness chain. The chain is strictly
  # sequential, so this is a data question — not something to plan around.
  def out_of_order(rec)
    seen_open = nil
    FITNESS_CHAIN.filter_map do |link|
      row = Status.requirement(rec, link[:rank], link[:req]) or next
      done = row["signed"].to_i == 1
      seen_open ||= link[:short] unless done
      "#{link[:rank]} #{link[:req]} is signed but #{seen_open} above it is not" if
        done && seen_open
    end
  end
end

# --------------------------------------------------------------------------
# badges — what is open, and what each one costs to close
# --------------------------------------------------------------------------
module Badges
  module_function

  # The badges this Scout is plausibly going to work on: every partial already
  # started, plus every alternate of an unfilled Eagle slot. Keyed by normalized
  # name; the value is the partial row, or nil for a badge not yet started.
  def in_play(rec, eagle_slots: true)
    started = rec["partials"].to_h { |p| [normalize(p["name"]), p] }
    earned  = rec["merit_badges"].map { |b| normalize(b["name"]) }

    wanted = if eagle_slots
               Status.eagle_slots(rec).reject { |s| s[:earned] }
                                      .flat_map { |s| s[:alternates] }.map { |n| normalize(n) }
             else
               []
             end
    (started.keys + wanted).uniq.reject { |k| earned.include?(k) }
                                .to_h { |k| [k, started[k]] }
  end

  # Partials ordered by what it costs to close them: furthest along first, then
  # fewest open requirements. The cheapest advancement in any record is a badge
  # at 94% with one requirement left.
  def by_cost(rec)
    rec["partials"].map { |p| p.merge("open_count" => open_codes(p).size) }
                   .sort_by { |p| [-p["percent"].to_i, p["open_count"], p["name"]] }
  end

  def open_codes(partial) = partial["open_reqts"].to_s.split(",").map(&:strip).reject(&:empty?)

  def stalled(rec, days)
    aged = rec["partials"].filter_map do |p|
      on = date_of(p["last_progress"]) or next
      [p, (Date.today - on).to_i]
    end
    aged.select { |_, since| since >= days }.sort_by { |_, since| -since }
  end

  # A badge whose requirement 1 is another badge. Finishing the prerequisite
  # closes the dependent requirement outright, so the pair is cheaper together
  # than either looks alone.
  def prereqs(rec)
    started = rec["partials"].to_h { |p| [normalize(p["name"]), p] }
    earned  = rec["merit_badges"].map { |b| normalize(b["name"]) }

    BADGE_PREREQS.filter_map do |name, rule|
      key = normalize(name)
      next if earned.include?(key)

      partial = started[key]
      next if partial && !Clocks.open_req?(partial, rule[:req])

      prereq_line(name, rule, started[normalize(rule[:needs])],
                  earned.include?(normalize(rule[:needs])))
    end
  end

  def prereq_line(name, rule, other, held)
    return "#{name} req. #{rule[:req]} is the #{rule[:needs]} merit badge, already earned" if held
    unless other
      return "#{name} req. #{rule[:req]} is the #{rule[:needs]} merit badge, which is not " \
             "in progress — start it first"
    end

    "#{name} req. #{rule[:req]} is the #{rule[:needs]} merit badge, at " \
      "#{other['percent']}% (open #{other['open_reqts']}) — finish it first"
  end

  # Every badge name the plan may quote requirements for, for `req.rb check`.
  def names(rec)
    in_play(rec).keys.filter_map do |key|
      (rec["partials"] + rec["merit_badges"]).find do |b|
        normalize(b["name"]) == key
      end&.dig("name") ||
        EAGLE_SLOTS.flatten.find { |n| normalize(n) == key }
    end.uniq.sort
  end
end

# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
module Render
  KIND = { elapsed: "[elapsed]", work: "[work]", opportunity: "[opportunity]" }.freeze

  module_function

  def day(value)
    return "—" if value.nil?

    (value.is_a?(Date) ? value : Date.parse(value.to_s)).strftime("%b %-d, %Y")
  rescue Date::Error
    "—"
  end

  def freshness(rec)
    days = Status.report_age(rec) or return "no report date"
    return "report is today's" if days <= 0

    return "report #{days}d old" unless days > STALE_DAYS

    "report #{days}d old — STALE, re-import before planning"
  end

  def header(rec, target)
    working = Status.next_rank(rec)
    puts "#{rec['name']} — #{rec['rank'].to_s.empty? ? 'no rank yet' : rec['rank']}, " \
         "working on #{working || 'Palms'}   (#{freshness(rec)})"
    puts format("  Patrol %s   Age %s   %s", rec["patrol"].to_s.empty? ? "—" : rec["patrol"],
                rec["age"] || "—", eighteen(rec))
    puts "  Target: #{target_line(target)}"
    puts
  end

  def eighteen(rec)
    on = Status.eighteenth(rec) or
      return "date of birth missing — an Eagle application will need it"
    left = (on - Date.today).to_i
    "turns 18 #{day(on)} (#{left} days)"
  end

  def target_line(target)
    return "none — #{target[:note]}" unless target[:date]

    away = (target[:date] - Date.today).to_i
    parts = ["#{day(target[:date])} (#{away} days) via #{target[:source]}"]
    parts << "court of honor #{day(target[:coh])}" if target[:coh] && target[:coh] != target[:date]
    parts << target[:note] if target[:note]
    parts.join("; ")
  end

  # `[elapsed] Participation .... Nov 12, 2026   makes it, 33 days spare`
  def clock_line(row, target)
    v = Clocks.verdict(row, target)
    puts format("  %-13s %-38s %-14s %s", KIND[row[:kind]], row[:label],
                day(row[:earliest]), v[:text])
    puts format("  %13s %s", "", row[:detail]) if row[:detail]
    # A row that has both a date and a reason is one already satisfied on the
    # calendar and waiting on a signature — worth saying, since it is a
    # conversation rather than a clock.
    puts format("  %13s %s", "", row[:reason]) if row[:reason] && row[:earliest]
    return unless v[:start_by]

    puts format("  %13s %s %s to make the target", "",
                row[:chain] ? "the chain must start by" : "start by", day(v[:start_by]))
  end
end

# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------
module Plan
  module_function

  def ladder(rec)
    puts "LADDER — ranks must be earned in sequence (GTA 4.2.0.1)"
    Ladder.rungs(rec).each { |rung| rung_line(rung) }
    banked = Ladder.banked(rec)
    if banked.positive?
      puts "\n  #{banked} requirements are already signed above the working rank — " \
           "finishing it converts all of them."
    end
    palms = Status.palm_blocks(rec)
    puts "\n  Palm blocks in the record (no clock arithmetic here): #{palms.join(', ')}" unless
      palms.empty?
    Ladder.out_of_order(rec).each { |note| puts "  !! #{note}" }
  end

  def rung_line(rung)
    mark = rung[:working] ? "->" : "  "
    n = rung[:open_slots]
    slots = "#{n} merit badge slot#{'s' unless n == 1} open"
    puts format("%<mark>s %<rank>-13s %<open>2d open, %<signed>2d signed, %<slots>s",
                mark: mark, rank: rung[:rank], open: rung[:open].size,
                signed: rung[:signed], slots: slots)
    rung[:open].each { |r| puts format("       [ ] %-8s %s", r["req_id"] || "", r["label"]) } if
      rung[:working]
  end

  def clocks(rec, opts, target)
    rows = Clocks.rows(rec, opts)
    puts "CLOCKS — earliest each dated item can be met"
    return puts "  nothing on a clock." if rows.empty?

    rows.sort_by { |r| [r[:earliest] ? 0 : 1, r[:earliest] || Date.today] }
        .each { |row| Render.clock_line(row, target) }
    puts "\n  [work] clocks run from --start #{Render.day(opts[:start])}" \
         "; [elapsed] clocks run from the record's own dates."
    return if ACTIVE_MONTHS.key?(Status.next_rank(rec))

    puts "  No merit badge is required below Star, so the only badge clocks here are for\n  " \
         "this Scout has already started. `badges` lists the Eagle-required slots regardless."
  end

  def badges(rec)
    slots = Status.eagle_slots(rec)
    puts "EAGLE-REQUIRED SLOTS — #{slots.count { |s| s[:earned] }} of 13 filled " \
         "(the troop's 13; the 2025 book prints 14, see individual-history)"
    slots.reject { |s| s[:earned] }.each { |s| puts "  [ ] #{slot_text(s)}" }
    # Dependencies sit with the slots rather than with the partials: the badge
    # they are about is named in the list just above, and a pair that closes
    # together is a slot finding, not a partial one.
    Badges.prereqs(rec).each { |line| puts "  ** #{line}" }
    partials(rec)
  end

  def slot_text(slot)
    return "#{slot[:label]} — not started" unless slot[:partial]

    "#{slot[:label]} — #{slot[:partial]['name']} at #{slot[:partial]['percent']}% " \
      "(#{slot[:partial]['req_year']} requirements; open #{slot[:partial]['open_reqts']})"
  end

  def partials(rec)
    rows = Badges.by_cost(rec)
    return if rows.empty?

    puts "\nPARTIALS, cheapest to close first"
    rows.each do |p|
      idle = date_of(p["last_progress"])
      puts format("  %<name>-30s %<pct>3d%%  %<open>2d open  %<year>s  idle %<idle>s",
                  name: p["name"], pct: p["percent"], open: p["open_count"],
                  year: "(#{p['req_year']})",
                  idle: idle ? "#{(Date.today - idle).to_i}d" : "—")
      puts format("  %30s open: %s", "", p["open_reqts"]) unless p["open_reqts"].to_s.empty?
    end
  end
end

# --------------------------------------------------------------------------
# verify — the match keys, and the two copied algorithms
# --------------------------------------------------------------------------
#
# There is no PDF to check a parse against here: the record is already verified
# by the importing skill. What can go wrong instead is silent *disablement* — a
# badge renamed in the book, a label TroopMaster reworded, or one of the two
# duplicated algorithms edited in only one of its copies. Each of those leaves a
# plan that reads perfectly and has quietly stopped applying a rule.
module Verify
  LIST_LINE  = /\Amerit badge\s+p\.(\d+)\s+(.+?)\s*(?:\[pamphlet (\d+)\])?\z/
  SLOT_LINE  = /^\s*\[[x~ ]\]\s+(.+?)\s\s+/
  POR_LINE   = /^(.+?)\s{2,}(\S.*?)\s+([\d.]+) of (\d+) months/

  module_function

  def call
    recs = Record.all
    die "nothing imported yet — run the import-individual-history skill first" if recs.empty?

    problems = badge_names + labels(recs) + chain(recs) + slots(recs) + tenure(recs)
    report(problems, recs.size)
  end

  def report(problems, count)
    if problems.empty?
      puts "OK — every match key resolves, and both copied algorithms agree with " \
           "individual-history across all #{count} Scouts."
      return
    end
    warn "FAILED — #{problems.size} problem(s):"
    problems.each { |p| warn "  #{p}" }
    exit 1
  end

  # A badge renamed in the requirements book disables its clock or prereq rule
  # without any other symptom.
  def badge_names
    known = book_badges.map { |n| normalize(n) }
    wanted = CLOCKS.map { |c| c[:badge] } + EAGLE_SLOTS.flatten +
             BADGE_PREREQS.flat_map { |name, rule| [name, rule[:needs]] }
    wanted.uniq.reject { |name| known.include?(normalize(name)) }
               .map { |name| "#{name.inspect} is in a table here but not in the badge list" }
  end

  def book_badges
    out, err, status = Open3.capture3(RbConfig.ruby, REQ_SCRIPT, "list", "--kind", "badge")
    unless status.success?
      die "scout-req could not list the merit badges (#{err.strip.lines.first})"
    end

    out.lines.filter_map { |l| l.strip.match(LIST_LINE)&.[](2)&.strip }
  end

  # TroopMaster's own wording, which it is free to change.
  def labels(recs)
    seen = recs.flat_map { |rec| rec["requirements"].map { |r| r["label"] } }.uniq
    LABELS.values.uniq.reject { |label| seen.include?(label) }
                      .map { |label| "nothing imported is labelled #{label.inspect} any more" }
  end

  def chain(recs)
    seen = recs.flat_map { |rec| rec["requirements"].map { |r| [r["rank"], r["req_id"]] } }.uniq
    FITNESS_CHAIN.reject { |link| seen.include?([link[:rank], link[:req]]) }
                 .map { |link| "fitness chain link #{link[:rank]} #{link[:req]} is in no record" }
  end

  # The Eagle slot labels this script prints must be the ones individual-history
  # prints, or the two copies of EAGLE_SLOTS have drifted.
  def slots(recs)
    text = Record.text(["eagle", recs.first["name"]]) or
      return ["individual-history could not print Eagle slots to compare against"]

    theirs = text.scan(SLOT_LINE).flatten.map(&:strip)
    ours   = EAGLE_SLOTS.map { |alts| alts.join(" / ") }
    return [] if theirs == ours

    ["EAGLE_SLOTS has drifted from individual-history's copy: #{(ours - theirs).inspect} here, " \
     "#{(theirs - ours).inspect} there"]
  end

  # And the tenure numbers must match, Scout for Scout.
  def tenure(recs)
    text = Record.text(["por"]) or return ["individual-history could not print POR tenure"]

    theirs = text.lines.filter_map { |l| l.match(POR_LINE) }
                       .to_h { |m| [m[1].strip, [m[3].to_f, m[4].to_i]] }
    recs.filter_map { |rec| tenure_diff(rec, theirs[rec["name"]]) }
  end

  def tenure_diff(rec, want)
    rank = Status.next_rank(rec)
    return nil unless want && rank && POR_MONTHS.key?(rank)

    mine = Tenure.toward(rec, rank)
    return nil if [mine[:months], mine[:needed]] == want

    "tenure for #{rec['name']} is #{mine[:months]}/#{mine[:needed]} here but " \
      "#{want[0]}/#{want[1]} in individual-history"
  end
end

# --------------------------------------------------------------------------
# the whole brief, which is what a plan is written from
# --------------------------------------------------------------------------
module Brief
  module_function

  def call(rec, opts, target)
    Render.header(rec, target)
    Plan.ladder(rec)
    puts
    Plan.clocks(rec, opts, target[:date])
    puts
    Plan.badges(rec)
    puts
    notes(rec, target)
  end

  def notes(rec, target)
    lines = [*freshness_note(rec), *dob_note(rec), *target[:note], *stalled_note(rec)]
    return if lines.empty?

    puts "NOTES"
    lines.each { |line| puts "  - #{line}" }
  end

  def freshness_note(rec)
    days = Status.report_age(rec)
    return [] unless days && days > STALE_DAYS

    ["the report behind this record is #{days} days old — re-import before the plan is acted on"]
  end

  def dob_note(rec)
    return [] if Status.eighteenth(rec)

    ["no date of birth in the record; the 18th-birthday deadline cannot be computed, and " \
     "an Eagle application will need it"]
  end

  def stalled_note(rec)
    idle = Badges.stalled(rec, 365)
    return [] if idle.empty?

    ["#{idle.size} partial(s) with no recorded progress in over a year: " \
     "#{idle.map { |p, d| "#{p['name']} (#{d}d)" }.join(', ')}"]
  end
end

# --------------------------------------------------------------------------
# json — the same facts, for a plan that wants to do its own arithmetic
# --------------------------------------------------------------------------
def as_json(rec, opts, target)
  { scout: rec.slice("name", "first_name", "last_name", "rank", "rank_date", "patrol", "age",
                     "report_date"),
    working_rank: Status.next_rank(rec), eighteenth_birthday: Status.eighteenth(rec)&.to_s,
    report_age_days: Status.report_age(rec),
    target: target.transform_values { |v| v.is_a?(Date) ? v.to_s : v },
    ladder: Ladder.rungs(rec).map { |r| r.merge(open: r[:open].map { |o| o["label"] }) },
    banked: Ladder.banked(rec),
    clocks: Clocks.rows(rec, opts).map do |row|
      row.merge(earliest: row[:earliest]&.to_s, verdict: Clocks.verdict(row, target[:date]))
         .transform_values { |v| v.is_a?(Date) ? v.to_s : v }
    end,
    eagle_slots: Status.eagle_slots(rec).map do |s|
      { label: s[:label], earned: s[:earned]&.dig("name"), partial: s[:partial]&.dig("name"),
        percent: s[:partial]&.dig("percent") }
    end,
    partials: Badges.by_cost(rec), prereqs: Badges.prereqs(rec) }
end

USAGE = <<~TEXT
  usage: ruby scripts/plan.rb COMMAND NAME [options]

    brief  NAME     everything below, in the order a plan is written in
    ladder NAME     ranks in sequence, what is open, and work banked above them
    clocks NAME     every dated item, earliest date, and whether it makes the target
    badges NAME     Eagle slots open, partials by closing cost, prerequisites
    names  NAME     badge names in play, one per line, for `req.rb check`
    json   NAME     all of it, machine-readable
    verify          every match key resolves; both copied algorithms still agree

  options:
    --by DATE          the date to plan against; defaults to the next court of
                       honor's cut-off in TROOP-SETTINGS.md
    --start DATE       when the Scout begins work; work-start clocks run from
                       here, not from the record. Defaults to today.
    --test-date DATE   when Tenderfoot 6a is actually run. Defaults to --start.
    --tenderfoot-6bc sequential   read 6b and 6c as two consecutive 30-day
                       windows rather than Troop 400's one shared window.

  NAME is resolved by individual-history: "Last, First", "First Last", a last
  name, or a first name. An ambiguous name is an error, never a guess.

  This script decides *when*. Requirement text comes from `scout-req`, who
  counsels a badge from `mbc`, and real dates from `troop-calendar`.

  Everything it prints is about a minor: fine in a session and in `plans/`,
  never in a tracked file, a commit message, or a PR description.
TEXT

args = ARGV.dup
command = args.shift

def take(args, flag)
  i = args.index(flag) or return nil
  args.delete_at(i + 1).tap { args.delete_at(i) }
end

by        = take(args, "--by")
start_on  = date_of(take(args, "--start")) || Date.today
test_date = date_of(take(args, "--test-date")) || start_on
shared    = take(args, "--tenderfoot-6bc") != "sequential"
name      = args.shift

abort USAGE if command.nil?
if command == "verify"
  Verify.call
  exit 0
end

die USAGE unless name
opts   = { start: start_on, test_date: test_date, shared_6bc: shared }
target = Horizon.target(by)
rec    = Record.one(name)

case command
when "brief"  then Brief.call(rec, opts, target)
when "ladder" then Plan.ladder(rec)
when "clocks"
  Render.header(rec, target)
  Plan.clocks(rec, opts, target[:date])
when "badges" then Plan.badges(rec)
when "names"  then puts Badges.names(rec)
when "json"   then puts JSON.pretty_generate(as_json(rec, opts, target))
else abort USAGE
end
