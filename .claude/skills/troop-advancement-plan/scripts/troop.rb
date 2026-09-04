#!/usr/bin/env ruby
# frozen_string_literal: true

#
# troop-advancement-plan — the cohort arithmetic behind the troop's next few
# meetings and activities.
#
#   ruby scripts/troop.rb brief     [options]
#   ruby scripts/troop.rb cohorts   [options]
#   ruby scripts/troop.rb themes    [--min N] [options]
#   ruby scripts/troop.rb clocks    [--soon DAYS] [options]
#   ruby scripts/troop.rb load      [--per-meeting N] [options]
#   ruby scripts/troop.rb badges    [--min N] [--stalled DAYS] [options]
#   ruby scripts/troop.rb attention [--quiet DAYS] [options]
#   ruby scripts/troop.rb json      [options]
#   ruby scripts/troop.rb verify
#
# This script decides *what the troop does next*. It does not decide what a
# requirement says, who counsels a badge, or what is on the calendar — those are
# `scout-req`, `mbc`, and `troop-calendar`, and the plan is written from all
# four.
#
# --------------------------------------------------------------------------
# Facts this script depends on
# --------------------------------------------------------------------------
#
# * **Every per-Scout number comes from `plan.rb json`, not from arithmetic of
#   its own.** Ladder, banked work, clocks, verdicts, target date, Eagle slots
#   and partials are read back from `generate-advancement-plan`, which reads its
#   record from `individual-history`, which reads the database
#   `import-individual-history` wrote. So the troop plan and the individual
#   plans cannot disagree, which is the whole point: a troop plan that sends a
#   Scout somewhere their own plan does not is worse than no troop plan.
#
#   The one derivation this script does make for itself is **which requirements
#   are open at a given rank** — it needs the `req_id` to sort a requirement
#   into a program theme, and `plan.rb json` prints labels. `verify` compares
#   that count against `plan.rb`'s own, Scout by Scout, so the duplication
#   cannot drift unnoticed.
#
# * **A theme spans every unearned rank, not just the working one.** One
#   cooking campout signs Tenderfoot 2a, Second Class 2e and First Class 2b for
#   three different Scouts at once, and for a new Scout it can sign all three.
#   Counting only the working rank makes every activity look half as valuable as
#   it is. But **only the working rank converts to a rank now** — work signed
#   above it is banked until the ranks below are earned — so both figures are
#   printed and they answer different questions: `signs` is what the evening is
#   worth, `at-rank` is what it advances.
#
# * **The closing three are not a batch opportunity.** Scout Spirit, the
#   Scoutmaster conference and the board of review are open for nearly every
#   Scout, so a plain frequency count of open requirements returns them at the
#   top and says nothing. They are the *load*, counted separately in `load`
#   against the troop's per-meeting capacity, and `CLOSING` exists to keep them
#   out of `themes`.
#
# * **Neither are the elapsed and project requirements.** Participation,
#   position of responsibility, the service project's hours and the Eagle
#   project are not things a meeting can teach — they are clocks and projects.
#   `INDIVIDUAL_LABELS` holds them, and `verify` asserts that every requirement
#   in the imported data is claimed by exactly one of `THEMES`, `CLOSING`, or
#   `INDIVIDUAL_LABELS`. A requirement claimed by none is invisible to the whole
#   analysis and produces a plan that reads perfectly with a gap in it.
#
# * **`THEMES` is a table of match keys, not a syllabus.** It sorts a
#   requirement onto an evening; it does not say what the requirement asks for.
#   The wording comes from `scout-req`, and `verify` checks in both directions —
#   every requirement themed, and every table entry still present in the data —
#   because a requirement TroopMaster renumbers otherwise drops out of its theme
#   in silence.
#
# * **A troop-wide clock roll-up is a cohort finding, not sixty per-Scout
#   lines.** Nineteen Scouts share one start-by date for Personal Management's
#   13 weeks, because a work-start clock runs from `--start` and not from
#   anything in the record. Grouping by clock is what turns that into "start it
#   as a group at the September 8 meeting"; listing it per Scout buries it.
#
# * **Palms are in the record but not on the ladder.** `plan.rb` gives them no
#   clock arithmetic and this script gives them no theme, so `verify`'s coverage
#   check is scoped to `RANK_LADDER`. A palm block otherwise reads as an
#   unclaimed requirement on every Life and Eagle Scout.
#
# * **A Scout who has left the troop inflates every count here.** One departure
#   is a rounding error in an individual plan and a wrong cohort size, a wrong
#   conference load and a wrong meeting count in this one. `--exclude` drops
#   them before anything is counted, and the names to pass come from "Scout
#   Updates" in `TROOP-SETTINGS.md`.
#
# --------------------------------------------------------------------------
# Privacy
# --------------------------------------------------------------------------
#
# Everything this script prints is about minors. It is fine in a session, in a
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
PLAN_SCRIPT    = File.join(SKILLS, "generate-advancement-plan", "scripts", "plan.rb")

RANK_LADDER = ["Scout", "Tenderfoot", "Second Class", "First Class",
               "Star", "Life", "Eagle"].freeze

STALE_DAYS   = 30    # a record older than this is reported as stale
QUIET_DAYS   = 150   # nothing signed, earned, or progressed in this long
STALLED_DAYS = 365   # a partial nobody has touched in this long
SOON_DAYS    = 21    # a clock whose start-by falls inside this is "this month"
PER_MEETING  = 3     # conferences, or boards, per meeting night — TROOP-SETTINGS.md
NEAR_ITEMS   = 3     # program items left and still callable "close to the rank"
WORKERS      = 4     # parallel `plan.rb json` processes

# --------------------------------------------------------------------------
# the tables
# --------------------------------------------------------------------------

# Program themes: what one evening, campout, or outing can sign off, across
# every rank at once. Keys are `req_id` where TroopMaster prints one (Scout
# through First Class) and the label where it does not (Star and Life).
#
# These are match keys, not requirement text. `venue` says what it takes to run:
#
#   :meeting  — a normal troop meeting
#   :campout  — nights out with patrol cooking and camp setup
#   :outing   — a specific place or event: a pool, an orienteering course
#   :service  — a service project
THEMES = [
  { key: "newscout", venue: :meeting,
    title: "Scout basics — the Oath and Law, the patrol method, the badge",
    items: [["Scout", %w[1a 1c 1d 1e 1f 2a 2b 2c 2d 3a 3b]]] },
  { key: "knots", venue: :meeting,
    title: "Rope work — knots, lashings, and a camp gadget",
    items: [["Scout", %w[4a 4b]], ["Tenderfoot", %w[3a 3b 3c]],
            ["Second Class", %w[2f 2g]], ["First Class", %w[3a 3b 3c 3d]]] },
  { key: "tools", venue: :meeting,
    title: "Knife, saw, and ax — Totin' Chip",
    items: [["Scout", %w[5]], ["Tenderfoot", %w[3d]]] },
  { key: "firstaid", venue: :meeting,
    title: "First aid",
    items: [["Tenderfoot", %w[4a 4b 4c 4d]], ["Second Class", %w[6a 6b 6c 6d 6e]],
            ["First Class", %w[7a 7b 7c 7d 7e 7f]]] },
  { key: "fitness", venue: :meeting,
    title: "The fitness test and the 30-day logs",
    items: [["Tenderfoot", %w[6a 6b 6c]], ["Second Class", %w[7a 7b 7c]],
            ["First Class", %w[8a 8b]]] },
  { key: "safety", venue: :meeting,
    title: "Personal safety awareness — the pamphlet and the videos",
    items: [["Scout", %w[6a 6b]], ["Second Class", %w[9a 9b]],
            ["Star", ["Personal Safety Pamphlet", "Personal Safety Videos"]]] },
  { key: "hiking", venue: :meeting,
    title: "Hiking safely — the buddy system, being lost, durable surfaces",
    items: [["Tenderfoot", %w[5a 5b 5c 5d]]] },
  { key: "weather", venue: :meeting,
    title: "Weather — forecasts, hazardous and extreme",
    items: [["First Class", %w[5b 5c 5d]]] },
  { key: "flags", venue: :meeting,
    title: "Flag ceremony and flag care",
    items: [["Tenderfoot", %w[7a]], ["Second Class", %w[8a 8b]]] },
  { key: "money", venue: :meeting,
    title: "Earning and spending money",
    items: [["Second Class", %w[8c 8d]]] },
  { key: "citizenship", venue: :meeting,
    title: "Citizenship and constitutional rights",
    items: [["First Class", %w[9a]]] },
  { key: "environment", venue: :meeting,
    title: "Environmental issues, reducing and recycling",
    items: [["First Class", %w[9b 9c]]] },
  { key: "teaching", venue: :meeting,
    title: "Teach a younger Scout a skill, using EDGE",
    items: [["Tenderfoot", %w[8]], ["Life", ["Teach using EDGE Method"]]] },
  { key: "recruiting", venue: :meeting,
    title: "Invite a friend to a troop activity",
    items: [["First Class", %w[10]]] },
  { key: "campcraft", venue: :campout,
    title: "Camping — nights out, pitching a tent, Leave No Trace, the Outdoor Code",
    items: [["Tenderfoot", %w[1a 1b 1c]], ["Second Class", %w[1a 1b 1c]],
            ["First Class", %w[1a 1b]]] },
  { key: "cooking", venue: :campout,
    title: "Patrol cooking — menus, fire, stoves, cooking, and cleanup",
    items: [["Tenderfoot", %w[2a 2b 2c]], ["Second Class", %w[2a 2b 2c 2d 2e]],
            ["First Class", %w[2a 2b 2c 2d 2e]]] },
  { key: "navigation", venue: :outing,
    title: "Map, compass, and GPS — needs a hike or an orienteering course",
    items: [["Second Class", %w[3a 3b 3c 3d]], ["First Class", %w[4a 4b]]] },
  { key: "aquatics", venue: :outing,
    title: "Swimming and water rescue — needs a pool or a waterfront",
    items: [["Second Class", %w[5a 5b 5c 5d]], ["First Class", %w[6a 6b 6c 6d 6e]]] },
  { key: "nature", venue: :outing,
    title: "Plants and wildlife — needs somewhere with both",
    items: [["Second Class", %w[4]], ["First Class", %w[5a]]] },
  { key: "service", venue: :service,
    title: "A troop service project",
    items: [["Tenderfoot", %w[7b]], ["Second Class", %w[8e]], ["First Class", %w[9d]],
            ["Star", ["Service Project"]], ["Life", ["Service Project"]]] }
].freeze

# The closing requirements, by `req_id` where there is one. These are open for
# nearly every Scout, so they are the conference and board load rather than
# anything a meeting can teach. Scout rank has no board of review — "After
# completing all the requirements for a rank, *except Scout rank*, a Scout meets
# with a board of review" (GTA 4.2.1.3) — and closes on "Scout Complete"
# instead.
CLOSING = {
  %w[Scout 1b] => :spirit,
  %w[Scout 7] => :smc,
  %w[Scout 8] => :complete,
  %w[Tenderfoot 9] => :spirit,
  %w[Tenderfoot 10] => :smc,
  %w[Tenderfoot 11] => :bor,
  ["Second Class", "10"] => :spirit,
  ["Second Class", "11"] => :smc,
  ["Second Class", "12"] => :bor,
  ["First Class", "11"] => :spirit,
  ["First Class", "12"] => :smc,
  ["First Class", "13"] => :bor
}.freeze

# Star, Life, and Eagle number nothing, so the same three are matched by label.
CLOSING_LABELS = { "Scout Spirit" => :spirit, "Scoutmaster Conference" => :smc,
                   "Board of Review" => :bor }.freeze

# Open, but not teachable in a meeting and not a conference either: two elapsed
# clocks and two projects. Named so `verify` can insist everything else is
# themed.
INDIVIDUAL_LABELS = ["Participation", "Position of Responsibility", "Eagle Project"].freeze

VENUES = { meeting: "meeting night", campout: "campout",
           outing: "outing or special event", service: "service project" }.freeze

def die(msg)
  warn msg
  exit 1
end

def date_of(text)
  return nil if text.nil? || text.to_s.strip.empty?

  Date.parse(text.to_s)
rescue Date::Error
  nil
end

def plural(count, singular, plural_form = nil)
  "#{count} #{count == 1 ? singular : plural_form || "#{singular}s"}"
end

# --------------------------------------------------------------------------
# the record, and the per-Scout plans read back from generate-advancement-plan
# --------------------------------------------------------------------------
module Record
  module_function

  def all
    out = run(RbConfig.ruby, HISTORY_SCRIPT, "json")
    recs = JSON.parse(out)
    recs.is_a?(Array) ? recs : [recs]
  rescue JSON::ParserError
    die "individual-history did not return JSON — run its own commands to see why"
  end

  # One `plan.rb json` per Scout, four at a time. Shelling out costs a process
  # each and makes the troop plan provably the same analysis as the individual
  # ones; recomputing it here would not.
  def plans(names, opts)
    queue = Queue.new
    names.each_with_index { |name, i| queue << [i, name] }
    workers = [WORKERS, names.size].min
    workers.times { queue << nil }
    out = Array.new(names.size)

    Array.new(workers) do
      Thread.new do
        while (job = queue.pop)
          out[job[0]] = plan(job[1], opts)
        end
      end
    end.each(&:join)

    out
  end

  def plan(name, opts)
    JSON.parse(run(RbConfig.ruby, PLAN_SCRIPT, "json", name, *opts))
  rescue JSON::ParserError
    die "generate-advancement-plan did not return JSON for #{name} — run " \
        "`plan.rb json #{name.inspect}` to see why"
  end

  def run(*cmd)
    out, err, status = Open3.capture3(*cmd)
    die "#{File.basename(cmd[1])} failed: #{err.strip.lines.first}" unless status.success?
    out
  end

  # `plan.rb verify`, run as-is. Everything here rests on its match keys.
  def verify_plan
    out, err, status = Open3.capture3(RbConfig.ruby, PLAN_SCRIPT, "verify")
    [status.success?, status.success? ? out : err]
  end
end

# --------------------------------------------------------------------------
# who is in scope — `--exclude` is applied before anything is counted
# --------------------------------------------------------------------------
module Roster
  module_function

  def select(recs, patterns)
    return [recs, []] if patterns.empty?

    kept = recs.reject { |rec| patterns.any? { |p| matches?(rec, p) } }
    unused = patterns.reject { |p| recs.any? { |rec| matches?(rec, p) } }
    [kept, unused]
  end

  def matches?(rec, pattern)
    want = pattern.downcase
    %w[name last_name first_name].any? { |f| rec[f].to_s.downcase.include?(want) }
  end

  def report(recs, kept, unused)
    dropped = recs.size - kept.size
    return if dropped.zero? && unused.empty?

    warn "excluded #{plural(dropped, 'Scout')}; #{plural(kept.size, 'Scout')} in scope"
    unused.each { |p| warn "note: --exclude #{p.inspect} matched nobody" }
  end
end

# --------------------------------------------------------------------------
# open requirements — the one derivation this script makes for itself, because
# themes key off `req_id` and `plan.rb json` prints labels. `verify` compares
# the count against `plan.rb`'s own, Scout by Scout.
# --------------------------------------------------------------------------
module Open
  module_function

  def at(rec, rank)
    rec["requirements"].select do |req|
      req["rank"] == rank && req["kind"] != "badge_slot" && req["signed"].to_i != 1
    end
  end

  def slots_at(rec, rank)
    rec["requirements"].count do |req|
      req["rank"] == rank && req["kind"] == "badge_slot" && req["badge"].to_s.empty?
    end
  end

  # Everything still open at or above the rank the Scout is working on. Work
  # above the working rank is real and signable; it just banks until the ranks
  # below it are earned.
  def from(rec, working)
    floor = RANK_LADDER.index(working) or return []
    RANK_LADDER[floor..].flat_map { |rank| at(rec, rank).map { |req| [rank, req] } }
  end

  def closing(rank, req) = CLOSING[[rank, req["req_id"]]] || CLOSING_LABELS[req["label"]]

  def individual?(req) = INDIVIDUAL_LABELS.include?(req["label"])

  # Everything still open at this rank once the closing three are set aside.
  # This is the number that says how close a Scout is, and the closing three are
  # excluded because they are the thing being scheduled rather than a reason not
  # to schedule it. The elapsed clocks and the projects stay in: a Scout whose
  # position of responsibility is still running is not ready for a board, and
  # calling them ready is the one mistake this number must not make.
  def program(rec, rank)
    at(rec, rank).reject { |req| closing(rank, req) }
  end

  # Of those, the ones no meeting can teach — two elapsed clocks and two
  # projects. A Scout whose only remaining work is here is waiting, not working.
  def waiting(rec, rank)
    program(rec, rank).select { |req| individual?(req) }.map { |req| req["label"] }
  end
end

# --------------------------------------------------------------------------
# themes — what one evening or outing is worth, across every rank at once
# --------------------------------------------------------------------------
module Themes
  INDEX = THEMES.each_with_object({}) do |theme, idx|
    theme[:items].each { |rank, keys| keys.each { |key| idx[[rank, key]] = theme[:key] } }
  end.freeze

  BY_KEY = THEMES.to_h { |theme| [theme[:key], theme] }.freeze

  module_function

  def of(rank, req) = INDEX[[rank, req["req_id"]]] || INDEX[[rank, req["label"]]]

  def tally(pairs)
    counts = THEMES.to_h { |t| [t[:key], { signs: 0, at_rank: 0, scouts: {}, at_rank_who: {} }] }

    pairs.each do |rec, working|
      Open.from(rec, working).each do |rank, req|
        key = of(rank, req) or next
        row = counts[key]
        row[:signs] += 1
        row[:scouts][rec["name"]] = true
        next unless rank == working

        row[:at_rank] += 1
        row[:at_rank_who][rec["name"]] = true
      end
    end

    counts.filter_map { |key, row| row[:signs].zero? ? nil : theme_row(key, row) }
          .sort_by { |row| [-row[:at_rank], -row[:signs]] }
  end

  def theme_row(key, row)
    BY_KEY[key].slice(:key, :title, :venue)
               .merge(signs: row[:signs], at_rank: row[:at_rank],
                      scouts: row[:scouts].keys.size, at_rank_scouts: row[:at_rank_who].keys.size,
                      who: row[:scouts].keys.sort, at_rank_who: row[:at_rank_who].keys.sort)
  end
end

# --------------------------------------------------------------------------
# service hours — the one theme whose size is knowable
# --------------------------------------------------------------------------
#
# `themes` says a service project would produce N sign-offs. For Star and Life
# it can say more than that, because service is a quantity: **how many hours the
# cohort still owes between them**, which is what decides whether one Saturday
# morning closes it or three do.
#
# Every figure is read straight out of `plan.rb json`, never recomputed here.
# The rank date each Scout's hours are clipped to, the six-hour threshold, and
# Life's conservation condition all live there, so the troop plan and the
# individual plans cannot disagree about a Scout down to the hour.
module ServiceWork
  module_function

  def rows(plans)
    plans.filter_map do |plan|
      service = plan["service"] or next

      service.transform_keys(&:to_sym).merge(name: plan["scout"]["name"])
    end
  end

  def summary(rows)
    counted, blocked = rows.partition { |row| row[:unusable].nil? }
    owing = counted.reject { |row| row[:met] }.sort_by { |row| -row[:short].to_f }
    { scouts: rows.size, blocked: blocked, met: counted.size - owing.size, owing: owing,
      hours: owing.sum { |row| row[:short].to_f },
      # Not a subtotal of `hours`: Life's conservation hours are part of the six,
      # so this is how much of the same shortfall has to be conservation work
      # specifically. A troop that books a park cleanup closes both; one that
      # books a food drive closes only the first.
      conservation: owing.sum { |row| row[:conservation_short].to_f },
      needing_conservation: owing.count { |row| row[:conservation_short].to_f.positive? } }
  end
end

# --------------------------------------------------------------------------
# cohorts — who is working on what, and how close they are
# --------------------------------------------------------------------------
module Cohorts
  module_function

  def rows(pairs, plans)
    by_name = plans.to_h { |p| [p["scout"]["name"], p] }

    built = pairs.map { |rec, working| row(rec, working, by_name[rec["name"]]) }
    built.sort_by { |row| [RANK_LADDER.index(row[:working]), row[:left], row[:name]] }
  end

  def row(rec, working, plan)
    left = Open.program(rec, working).size + Open.slots_at(rec, working)
    { name: rec["name"], patrol: rec["patrol"], rank: rec["rank"].to_s, working: working,
      left: left, stage: stage(left), banked: plan["banked"],
      waiting: Open.waiting(rec, working), slots: Open.slots_at(rec, working),
      ahead: ahead(rec, working) }
  end

  def stage(left)
    return :ready if left.zero?

    left <= NEAR_ITEMS ? :close : :later
  end

  # What is waiting one rung up, for a Scout about to clear the one they are on.
  def ahead(rec, working)
    nxt = RANK_LADDER[RANK_LADDER.index(working) + 1] or return nil
    { rank: nxt, left: Open.program(rec, nxt).size + Open.slots_at(rec, nxt) }
  end

  def by_rank(rows) = rows.group_by { |row| row[:working] }
end

# --------------------------------------------------------------------------
# the conference and board load
# --------------------------------------------------------------------------
module Load
  module_function

  def rows(cohorts)
    within = cohorts.reject { |row| row[:stage] == :later }
    { ready: cohorts.count { |row| row[:stage] == :ready },
      close: cohorts.count { |row| row[:stage] == :close },
      later: cohorts.count { |row| row[:stage] == :later },
      smc: within.size,
      bor: within.count { |row| row[:working] != "Scout" },
      eagle_bor: within.count { |row| row[:working] == "Eagle" },
      # Nothing left but a clock or a project: no amount of program time helps,
      # and the date comes from `clocks` rather than from the meeting schedule.
      waiting_only: within.count { |row| row[:waiting].size == row[:left] && row[:left].positive? },
      who: within.sort_by { |row| [row[:left], row[:name]] } }
  end

  # Conferences and boards run concurrently, so a night's capacity is not the
  # sum of the two — it is whichever is larger. TROOP-SETTINGS.md is where the
  # troop records the per-meeting figure.
  def meetings(load, per_meeting)
    [(load[:smc] / per_meeting.to_f).ceil, (load[:bor] / per_meeting.to_f).ceil].max
  end
end

# --------------------------------------------------------------------------
# clocks, rolled up across the troop rather than listed per Scout
# --------------------------------------------------------------------------
module Clocks
  module_function

  def rows(plans)
    groups = Hash.new { |hash, key| hash[key] = [] }
    plans.each do |plan|
      plan["clocks"].each { |clock| groups[[clock["kind"], clock["label"]]] << [plan, clock] }
    end

    groups.map { |(kind, label), entries| row(kind, label, entries) }
          .sort_by { |row| [ORDER.fetch(row[:kind], 9), row[:start_by] || "9999", -row[:scouts]] }
  end

  ORDER = { "work" => 0, "elapsed" => 1, "opportunity" => 2 }.freeze

  def row(kind, label, entries)
    starts  = entries.filter_map { |(_, clock)| clock.dig("verdict", "start_by") }.uniq.sort
    # An elapsed clock's detail is that Scout's own dates, so it is only worth
    # printing when the whole group shares it. Printing the first Scout's dates
    # over a group of eleven is the kind of specific, confident, wrong line this
    # roll-up exists to avoid.
    details = entries.map { |(_, clock)| clock["detail"] }.uniq
    { kind: kind, label: label, scouts: entries.size,
      detail: details.size == 1 ? details.first : nil,
      **banked(entries),
      start_by: starts.first, start_by_varies: starts.size > 1,
      makes: entries.count { |(_, c)| c.dig("verdict", "makes") == true },
      misses: entries.count { |(_, c)| c.dig("verdict", "makes") == false },
      undated: entries.count { |(_, c)| c.dig("verdict", "makes").nil? },
      who: entries.map { |(plan, _)| plan["scout"]["name"] }.sort }
  end

  # An opportunity clock the participation report can count — at present only
  # Camping's twenty nights. The roll-up that matters is the *sum* of what the
  # cohort is short, because that is what gets compared against the number of
  # nights the calendar actually offers before the target date. It stays out of
  # `detail`, which is per Scout and deliberately suppressed for a group.
  def banked(entries)
    counted = entries.filter_map { |(_, clock)| clock["counted"] }
    return {} if counted.empty?

    behind = counted.select { |c| c["short"].to_f.positive? }
    { unit: counted.first["unit"], short: behind.sum { |c| c["short"].to_f },
      behind: behind.size, banked_met: counted.size - behind.size }
  end

  def soon(rows, days)
    edge = Date.today + days
    rows.select do |row|
      by = date_of(row[:start_by])
      by && by <= edge
    end
  end
end

# --------------------------------------------------------------------------
# merit badge work several Scouts share
# --------------------------------------------------------------------------
module BadgeWork
  module_function

  # Eagle slots still open, counted only for the Scouts a slot can matter to.
  # Below Star no merit badge is required at all.
  def slots(plans)
    eligible = plans.select { |p| %w[Star Life Eagle].include?(p["working_rank"]) }
    tally = Hash.new { |hash, key| hash[key] = [] }
    eligible.each do |plan|
      plan["eagle_slots"].each do |slot|
        tally[slot["label"]] << plan["scout"]["name"] if slot["earned"].nil?
      end
    end

    tally.map { |label, who| { label: label, scouts: who.size, who: who.sort } }
         .sort_by { |row| [-row[:scouts], row[:label]] }
  end

  def partials(plans)
    tally = Hash.new { |hash, key| hash[key] = [] }
    plans.each do |plan|
      plan["partials"].each { |partial| tally[partial["name"]] << [plan, partial] }
    end

    tally.map { |name, entries| partial_row(name, entries) }
         .sort_by { |row| [-row[:scouts], -row[:near], row[:name]] }
  end

  def partial_row(name, entries)
    percents = entries.map { |(_, p)| p["percent"].to_i }
    { name: name, scouts: entries.size, near: percents.count { |pct| pct >= 80 },
      best: percents.max, years: entries.filter_map { |(_, p)| p["req_year"] }.uniq.sort,
      eagle: entries.any? { |(_, p)| p["eagle_required"].to_i == 1 },
      who: entries.map { |(plan, _)| plan["scout"]["name"] }.sort }
  end

  # Rolled up by badge rather than by Scout. A partial does not expire — it is
  # good until the Scout turns 18 — so one idle badge is a conversation, not a
  # finding. The same badge idle for the same eighteen months across eight
  # Scouts is a group that started together and stopped, and that is a troop
  # decision: finish it, or write it off and stop counting it as in progress.
  def stalled(plans, days)
    tally = Hash.new { |hash, key| hash[key] = [] }
    plans.each do |plan|
      plan["partials"].each do |partial|
        idle = idle_days(partial)
        tally[partial["name"]] << [plan["scout"]["name"], idle, partial] if idle && idle >= days
      end
    end

    tally.map { |name, entries| stalled_row(name, entries) }
         .sort_by { |row| [-row[:scouts], -row[:idle]] }
  end

  def stalled_row(name, entries)
    { name: name, scouts: entries.size, idle: entries.map { |(_, days, _)| days }.max,
      least_idle: entries.map { |(_, days, _)| days }.min,
      best: entries.map { |(_, _, partial)| partial["percent"].to_i }.max,
      eagle: entries.any? { |(_, _, partial)| partial["eagle_required"].to_i == 1 },
      who: entries.map { |(scout, _, _)| scout }.sort }
  end

  def idle_days(partial)
    on = date_of(partial["last_progress"]) || date_of(partial["start_date"]) or return nil
    (Date.today - on).to_i
  end
end

# --------------------------------------------------------------------------
# who needs an adult
# --------------------------------------------------------------------------
module Attention
  module_function

  def rows(pairs, plans, opts)
    by_name = pairs.to_h { |rec, _| [rec["name"], rec] }

    flagged = plans.filter_map do |plan|
      flags = flags_for(by_name[plan["scout"]["name"]], plan, opts)
      next if flags.empty?

      { name: plan["scout"]["name"], working: plan["working_rank"],
        weight: flags.sum { |flag| flag[:weight] }, flags: flags }
    end
    flagged.sort_by { |row| [-row[:weight], row[:name]] }
  end

  # Idle partials are deliberately not here. Nearly every Scout has one, so a
  # per-Scout flag for them buries the four or five Scouts who actually need
  # someone — and the pattern is a troop one anyway: the same badge idle for the
  # same eighteen months across eight Scouts is a group that started together
  # and stopped. `badges` rolls them up by badge, which is where the finding is.
  def flags_for(rec, plan, opts)
    [quiet(rec, opts), stale(plan), dob(plan), eighteen(plan), position(plan),
     missed(plan), overdue(plan)].flatten.compact
  end

  # The single most useful troop-level signal: nothing signed, earned, or
  # progressed in months. It is the one thing here the record answers and no
  # per-Scout plan asks.
  def quiet(rec, opts)
    on = last_activity(rec)
    return { weight: 4, text: "no recorded advancement of any kind" } unless on

    days = (Date.today - on).to_i
    return nil if days < opts[:quiet]

    { weight: 4, text: "nothing signed, earned, or progressed since #{on} (#{days} days)" }
  end

  def last_activity(rec)
    (rec["requirements"].filter_map { |r| date_of(r["completed_on"]) } +
     rec["merit_badges"].filter_map { |b| date_of(b["earned_on"]) } +
     rec["partials"].filter_map { |p| date_of(p["last_progress"]) } +
     rec["special_awards"].filter_map { |a| date_of(a["earned_on"]) }).max
  end

  def stale(plan)
    age = plan["report_age_days"].to_i
    return nil if age <= STALE_DAYS

    { weight: 3, text: "record is #{age} days old — re-import before acting on it" }
  end

  def dob(plan)
    return nil if plan["eighteenth_birthday"]

    { weight: 3, text: "no date of birth in the record — the Eagle deadline cannot be computed" }
  end

  def eighteen(plan)
    on = date_of(plan["eighteenth_birthday"]) or return nil
    months = ((on - Date.today) / 30.44).round(1)
    return nil if months > 18 || plan["working_rank"].nil?

    open_slots = plan["eagle_slots"].count { |slot| slot["earned"].nil? }
    { weight: months <= 12 ? 5 : 3,
      text: "turns 18 on #{on} (#{months} months), working #{plan['working_rank']}, " \
            "#{plural(open_slots, 'Eagle slot')} still open" }
  end

  # No credited position running is the largest single problem in a record:
  # nothing is accruing, so the earliest finish is a full term after one starts.
  def position(plan)
    row = plan["clocks"].find do |clock|
      clock["kind"] == "elapsed" && clock["label"] == "Position of Responsibility"
    end
    return nil unless row && row["earliest"].nil?

    { weight: 4, text: "position of responsibility: #{row['reason'] || row['detail']}" }
  end

  # An elapsed clock that misses cannot be helped by working harder — say so,
  # and give the date they can make.
  def missed(plan)
    plan["clocks"].select { |c| c["kind"] == "elapsed" && c.dig("verdict", "makes") == false }
                  .map do |clock|
      { weight: 2,
        text: "#{clock['label']} #{clock.dig('verdict', 'text')} — " \
              "elapsed time, so it cannot be compressed (earliest #{clock['earliest']})" }
    end
  end

  def overdue(plan)
    plan["clocks"].filter_map do |clock|
      by = date_of(clock.dig("verdict", "start_by")) or next
      next if by >= Date.today

      { weight: 2, text: "#{clock['label']} had to start by #{by} to make the target" }
    end
  end
end

# --------------------------------------------------------------------------
# printing
# --------------------------------------------------------------------------
module Render
  module_function

  def header(plans, scope, target)
    puts "TROOP ADVANCEMENT — #{plural(scope, 'Scout')} in scope"
    puts "report:  #{plans.first['scout']['report_date']} " \
         "(#{plural(plans.first['report_age_days'].to_i, 'day')} old)#{stale_flag(plans)}"
    puts "target:  #{target['date']} — #{target_note(target)}"
    puts
  end

  def stale_flag(plans)
    worst = plans.map { |p| p["report_age_days"].to_i }.max
    worst > STALE_DAYS ? "  ** STALE — oldest record is #{worst} days" : ""
  end

  def target_note(target)
    parts = ["from #{target['source']}"]
    parts << "court of honor #{target['coh']}" if target["coh"]
    parts << target["note"] if target["note"]
    parts.join("; ")
  end

  def section(title)
    puts title
    puts "-" * title.length
  end

  def names(list, limit = 6)
    shown = list.first(limit).map { |n| short(n) }
    shown << "+#{list.size - limit} more" if list.size > limit
    shown.join(", ")
  end

  def short(name)
    last, first = name.split(", ", 2)
    first ? "#{first} #{last[0]}." : name
  end

  # Hours and nights arrive as floats and are mostly whole; "3" reads better
  # than "3.0", and "2.5" has to survive.
  def qty(value)
    value = value.to_f
    value == value.to_i ? value.to_i.to_s : format("%.1f", value)
  end
end

# --------------------------------------------------------------------------
# the subcommands
# --------------------------------------------------------------------------
module Show
  module_function

  def cohorts(rows)
    Render.section("COHORTS — who is working on what")
    Cohorts.by_rank(rows).sort_by { |rank, _| RANK_LADDER.index(rank) }.each do |rank, group|
      puts format("%-13s %2d Scouts   %s", rank, group.size, stages(group))
      group.each { |row| puts cohort_line(row) }
      puts
    end
  end

  STAGE_WORDS = { ready: "ready", close: "close", later: "further off" }.freeze

  def stages(group)
    STAGE_WORDS.map { |stage, word| "#{word} #{group.count { |row| row[:stage] == stage }}" }
               .join(", ")
  end

  def cohort_line(row)
    tail = []
    tail << "waiting on #{row[:waiting].join(', ')}" unless row[:waiting].empty?
    tail << "#{plural(row[:slots], 'MB slot')} open" if row[:slots].positive?
    tail << "#{row[:banked]} signed above" if row[:banked].positive?
    if row[:ahead] && row[:ahead][:left] <= NEAR_ITEMS
      tail << "then #{row[:ahead][:left]} to #{row[:ahead][:rank]}"
    end
    format("    %-22s %-20s %2d left%s", row[:name], row[:patrol].to_s, row[:left],
           tail.empty? ? "" : "   #{tail.join('; ')}")
  end

  def banked(rows, min)
    hits = rows.select { |row| row[:banked] >= min }.sort_by { |row| -row[:banked] }
    return if hits.empty?

    Render.section("BANKED WORK — signed above the rank being worked on")
    puts "Clearing the working rank converts all of it. These are the highest-yield"
    puts "Scouts in the troop, and the shortest path to a court of honor."
    puts
    hits.each do |row|
      puts format("    %-22s %-13s %3d signed above   %s", row[:name], row[:working],
                  row[:banked], "#{row[:left]} left at #{row[:working]}")
    end
    puts
  end

  def themes(rows, min, service = nil)
    Render.section("PROGRAM THEMES — what one session is worth")
    puts "signs = sign-offs available across every unearned rank, which is what the"
    puts "session is worth; at-rank = the subset that counts toward the rank its Scout"
    puts "is working on now, which is what it advances. The names are the at-rank ones."
    puts
    VENUES.each do |venue, title|
      group = rows.select { |row| row[:venue] == venue && row[:scouts] >= min }
      next if group.empty?

      puts title.upcase
      group.each { |row| puts theme_lines(row) }
      service_lines(service) if venue == :service
      puts
    end
  end

  # The service theme is the only one whose size is knowable, so it gets the
  # hours as well as the sign-off count. A sign-off count says how many Scouts a
  # project serves; the hours say how many mornings it takes.
  def service_lines(service)
    return if service.nil? || service[:scouts].zero?

    if service[:owing].empty?
      puts "#{' ' * 17}every Star and Life Scout has their hours; the rest is signatures"
    else
      puts format("    %-12s %s still owed between %s at Star or Life%s", "",
                  "#{Render.qty(service[:hours])} hours",
                  plural(service[:owing].size, "Scout"), conservation_note(service))
      puts format("    %-12s %s", "", Render.names(service[:owing].map { |r| r[:name] }, 8))
    end
    blocked(service[:blocked])
  end

  # Usually every blocked Scout is blocked for the same reason — nobody has
  # imported a participation report — so it is said once with a count. A mixed
  # list is the interesting case and stays per Scout.
  def blocked(rows)
    rows.group_by { |row| row[:unusable] }.each do |reason, group|
      puts format("    %-12s %s: %s", "", Render.names(group.map { |r| r[:name] }, 4), reason)
    end
  end

  # Life asks for three of its six hours to be conservation-related, so a troop
  # that books the wrong kind of project closes fewer hours than it thinks.
  def conservation_note(service)
    return "" unless service[:needing_conservation].positive?

    ", of which #{Render.qty(service[:conservation])} must be conservation work " \
      "(#{service[:needing_conservation]} of them)"
  end

  def theme_lines(row)
    worth = format("%4d signs / %3d at-rank", row[:signs], row[:at_rank])
    [format("    %-12s %s   %2d Scouts, %2d at rank", row[:key], worth, row[:scouts],
            row[:at_rank_scouts]),
     format("    %-12s %s", "", row[:title]),
     format("    %-12s at rank: %s", "", Render.names(row[:at_rank_who], 8))]
  end

  def clocks(rows, soon_days)
    Render.section("CLOCKS — what has to start now")
    puts "One row per clock, not per Scout: a work-start clock runs from --start, so"
    puts "everyone who still needs it shares the same start-by date."
    puts
    rows.each { |row| puts clock_lines(row) }
    puts
    urgent = Clocks.soon(rows, soon_days)
    return if urgent.empty?

    puts "Within #{soon_days} days:"
    urgent.each do |row|
      puts format("    %s — start by %s (%s)", row[:label], row[:start_by],
                  plural(row[:scouts], "Scout"))
    end
    puts
  end

  def clock_lines(row)
    head = format("    [%-11s] %-36s %-10s", row[:kind], row[:label],
                  plural(row[:scouts], "Scout"))
    head += "   start by #{row[:start_by]}#{', at the earliest' if row[:start_by_varies]}" if
      row[:start_by]
    verdict = []
    verdict << "#{row[:makes]} make it" if row[:makes].positive?
    verdict << "#{row[:misses]} miss" if row[:misses].positive?
    verdict << "#{row[:undated]} with no date" if row[:undated].positive?
    verdict << "start-by varies by Scout" if row[:start_by_varies]
    [row[:detail] ? [head, format("    %-13s %s", "", row[:detail])] : head,
     *banked_line(row),
     format("    %-13s %s", "", verdict.join("; "))]
  end

  # "34 nights short between 6 Scouts" is the number to take to the calendar:
  # compare it against the nights the campouts before the target date offer.
  def banked_line(row)
    return [] unless row[:unit]

    parts = []
    if row[:behind].positive?
      parts << "#{Render.qty(row[:short])} #{row[:unit]} short between " \
               "#{plural(row[:behind], 'Scout')} — count that against the campouts on the " \
               "calendar before the target"
    end
    parts << "#{plural(row[:banked_met], 'Scout')} already have the #{row[:unit]}" if
      row[:banked_met].positive?
    parts.map { |part| format("    %-13s %s", "", part) }
  end

  def load(row, per_meeting)
    Render.section("CONFERENCE AND BOARD LOAD")
    puts "\"Ready\" is a Scout with nothing left but the conference and the board;"
    puts "\"close\" is #{NEAR_ITEMS} items or fewer besides. Both are in the load below."
    puts
    puts format("    ready now        %2d", row[:ready])
    puts format("    close (<= %d)     %2d", NEAR_ITEMS, row[:close])
    puts format("    further off      %2d", row[:later])
    puts
    load_totals(row, per_meeting)
    puts
    row[:who].each { |scout| puts load_line(scout) }
    puts
  end

  def load_totals(row, per_meeting)
    eagle = row[:eagle_bor].positive? ? "   (+#{row[:eagle_bor]} Eagle, not troop boards)" : ""
    puts format("    conferences      %2d", row[:smc])
    puts format("    troop boards     %2d%s", row[:bor] - row[:eagle_bor], eagle)
    puts
    puts format("    at %d per meeting, that is %s", per_meeting,
                plural(Load.meetings(row, per_meeting), "meeting night"))
    puts "    conferences and boards run concurrently, so the two do not add up"
    return unless row[:waiting_only].positive?

    puts format("    %d of them %s waiting only on a clock or a project — take that date",
                row[:waiting_only], row[:waiting_only] == 1 ? "is" : "are")
    puts "    off CLOCKS, not off the meeting schedule"
  end

  def load_line(scout)
    waiting = scout[:waiting].empty? ? "" : "   waiting on #{scout[:waiting].join(', ')}"
    format("    %-22s %-13s %2d left%s", scout[:name], scout[:working], scout[:left], waiting)
  end

  def badges(slots, partials, stalled, min)
    Render.section("MERIT BADGE WORK SEVERAL SCOUTS SHARE")
    shared = slots.select { |row| row[:scouts] >= min }
    unless shared.empty?
      puts "Eagle-required slots still open (Star, Life, and Eagle Scouts only):"
      shared.each do |row|
        puts format("    %-42s %2d Scouts  %s", row[:label], row[:scouts], Render.names(row[:who]))
      end
      puts
    end

    open_partials = partials.select { |row| row[:scouts] >= min }
    unless open_partials.empty?
      puts "Partials in progress:"
      open_partials.each do |row|
        progress = format("%2d at 80%%+, best %2d%%", row[:near], row[:best])
        tail = format("%-16s req. year %s", row[:eagle] ? "Eagle-required" : "",
                      row[:years].join("/"))
        puts format("    %-30s %2d Scouts  %s  %s", row[:name], row[:scouts], progress, tail)
      end
      puts
    end

    stalled_partials(stalled, min)
  end

  def stalled_partials(stalled, min)
    shared = stalled.select { |row| row[:scouts] >= min }
    return if shared.empty?

    puts "Partials nobody has moved (a whole group stopped, not one Scout):"
    shared.each do |row|
      idle = format("idle %d-%d days, best %2d%%", row[:least_idle], row[:idle], row[:best])
      puts format("    %-30s %2d Scouts  %s  %s", row[:name], row[:scouts], idle,
                  row[:eagle] ? "Eagle-required" : "")
    end
    puts "A partial does not expire — it is good until the Scout turns 18 — but a"
    puts "requirement year that has since changed is a real complication. Check with"
    puts "`scout-req` before restarting one."
    puts
  end

  def attention(rows)
    Render.section("SCOUTS WHO NEED AN ADULT")
    if rows.empty?
      puts "    nothing flagged."
      puts
      return
    end

    rows.each do |row|
      puts format("    %-22s %s", row[:name], row[:working])
      row[:flags].each { |flag| puts "        - #{flag[:text]}" }
    end
    puts
  end
end

# --------------------------------------------------------------------------
# verify — nothing here parses anything, so what it checks is silent disablement
# --------------------------------------------------------------------------
module Verify
  module_function

  def call(recs, pairs, plans)
    problems = delegate + coverage(pairs) + tables(recs) + open_counts(pairs, plans)
    report(problems, pairs.size)
  end

  def report(problems, count)
    if problems.empty?
      puts "OK — generate-advancement-plan verifies, every requirement is claimed by a " \
           "theme, a closing item, or an individual one, and the open counts agree with " \
           "it for all #{count} Scouts."
      return
    end
    warn "FAILED — #{problems.size} problem(s):"
    problems.each { |problem| warn "  #{problem}" }
    exit 1
  end

  # Everything here rests on generate-advancement-plan's match keys, so its own
  # verify runs first and its failure is this one's failure.
  def delegate
    ok, output = Record.verify_plan
    return [] if ok

    ["generate-advancement-plan's own verify fails, so nothing here can be trusted:",
     *output.strip.lines.map { |line| "  #{line.chomp}" }]
  end

  # Forward: a requirement claimed by nothing is invisible to the analysis.
  def coverage(pairs)
    unclaimed = {}
    pairs.map(&:first).each do |rec|
      rec["requirements"].each do |req|
        rank = req["rank"]
        next unless RANK_LADDER.include?(rank)
        next if req["kind"] == "badge_slot"
        next if Open.closing(rank, req) || Open.individual?(req) || Themes.of(rank, req)

        unclaimed["#{rank} #{req['req_id']} #{req['label']}"] = true
      end
    end

    unclaimed.keys.map do |item|
      "#{item.inspect} is in no theme, no closing set, and no individual list"
    end
  end

  # Backward: a table entry matching nothing is a rule that has stopped
  # applying. A rank nobody is working on carries no rows at all, so that case
  # is a note rather than a failure.
  def tables(recs)
    seen = Hash.new { |hash, key| hash[key] = [] }
    recs.each do |rec|
      rec["requirements"].each { |req| seen[req["rank"]] << req["req_id"] << req["label"] }
    end

    wanted = THEMES.flat_map { |theme| theme[:items] } +
             CLOSING.keys.map { |rank, id| [rank, [id]] }
    wanted.flat_map { |rank, keys| keys.map { |key| [rank, key] } }
          .reject { |rank, key| seen.key?(rank) && seen[rank].include?(key) }
          .filter_map { |rank, key| missing_note(seen, rank, key) }
  end

  def missing_note(seen, rank, key)
    return nil unless seen.key?(rank)

    "#{rank} #{key.inspect} is named in a table here but is in no imported record"
  end

  # The one derivation this script makes for itself, checked Scout by Scout
  # against the skill that owns it.
  def open_counts(pairs, plans)
    by_name = plans.to_h { |plan| [plan["scout"]["name"], plan] }

    pairs.filter_map do |rec, working|
      rung = by_name[rec["name"]]["ladder"].find { |row| row["working"] } or next
      mine = Open.at(rec, working).size
      next if mine == rung["open"].size

      "open count for #{rec['name']} at #{working} is #{mine} here but " \
        "#{rung['open'].size} in generate-advancement-plan"
    end
  end
end

# --------------------------------------------------------------------------
# the whole brief, which is what a plan is written from
# --------------------------------------------------------------------------
module Brief
  module_function

  def call(state, opts)
    Render.header(state[:plans], state[:pairs].size, state[:plans].first["target"])
    Show.cohorts(state[:cohorts])
    Show.banked(state[:cohorts], opts[:min_banked])
    Show.load(state[:load], opts[:per_meeting])
    Show.themes(state[:themes], opts[:min], state[:service])
    Show.clocks(state[:clocks], opts[:soon])
    Show.badges(state[:slots], state[:partials], state[:stalled], opts[:min])
    Show.attention(state[:attention])
  end
end

def build(state, opts)
  { scouts: state[:pairs].size, target: state[:plans].first["target"],
    report_date: state[:plans].first["scout"]["report_date"],
    report_age_days: state[:plans].map { |p| p["report_age_days"].to_i }.max,
    cohorts: state[:cohorts], load: state[:load].merge(
      per_meeting: opts[:per_meeting], meeting_nights: Load.meetings(state[:load],
                                                                     opts[:per_meeting])
    ),
    themes: state[:themes], service: state[:service], clocks: state[:clocks],
    eagle_slots: state[:slots], partials: state[:partials], stalled: state[:stalled],
    attention: state[:attention] }
end

USAGE = <<~TEXT.freeze
  usage: ruby scripts/troop.rb COMMAND [options]

    brief        everything below, in the order a plan is written in
    cohorts      who is working on what, how close, and what is banked above
    themes       what one meeting, campout, or outing is worth across the troop
    clocks       every clock rolled up: what has to start now, and for whom
    load         the conference and board load against meeting-night capacity
    badges       Eagle slots and partials several Scouts share
    attention    Scouts who need an adult, most urgent first
    json         all of it, machine-readable
    verify       plan.rb verifies; every requirement claimed; open counts agree

  options:
    --exclude NAME     drop a Scout who has left the troop, before anything is
                       counted. Repeatable; the names come from "Scout Updates"
                       in TROOP-SETTINGS.md.
    --by DATE          the date to plan against; defaults to the next court of
                       honor's cut-off in TROOP-SETTINGS.md
    --start DATE       when work begins; work-start clocks run from here, not
                       from the record. Defaults to today.
    --test-date DATE   when Tenderfoot 6a is actually run. Defaults to --start.
    --tenderfoot-6bc sequential   read 6b and 6c as two consecutive 30-day
                       windows rather than Troop 400's one shared window.
    --min N            hide themes and shared badges under N Scouts (default 2)
    --min-banked N     hide banked-work rows under N signed items (default 5)
    --per-meeting N    conferences, or boards, per meeting night (default #{PER_MEETING})
    --soon DAYS        how far ahead a clock counts as urgent (default #{SOON_DAYS})
    --quiet DAYS       silence that flags a Scout for attention (default #{QUIET_DAYS})
    --stalled DAYS     idle time that makes a partial count as stopped, in the
                       `badges` roll-up (default #{STALLED_DAYS})

  Every per-Scout number comes from generate-advancement-plan, so this and the
  individual plans cannot disagree. Requirement text comes from `scout-req`, who
  counsels a badge from `mbc`, and real dates from `troop-calendar`.

  Everything it prints is about minors: fine in a session and in `plans/`, never
  in a tracked file, a commit message, or a PR description.
TEXT

def take(args, flag)
  index = args.index(flag) or return nil
  args.delete_at(index + 1).tap { args.delete_at(index) }
end

def take_all(args, flag)
  values = []
  while (value = take(args, flag))
    values << value
  end
  values
end

def integer(value, fallback)
  value.nil? ? fallback : Integer(value, exception: false) || fallback
end

COMMANDS = %w[brief cohorts themes clocks load badges attention
              json verify].freeze

args    = ARGV.dup
command = args.shift
abort USAGE unless COMMANDS.include?(command)

excludes = take_all(args, "--exclude")
opts = { min: integer(take(args, "--min"), 2),
         min_banked: integer(take(args, "--min-banked"), 5),
         per_meeting: integer(take(args, "--per-meeting"), PER_MEETING),
         soon: integer(take(args, "--soon"), SOON_DAYS),
         quiet: integer(take(args, "--quiet"), QUIET_DAYS),
         stalled: integer(take(args, "--stalled"), STALLED_DAYS) }

forwarded = ["--by", "--start", "--test-date", "--tenderfoot-6bc"]
            .flat_map { |flag| (value = take(args, flag)) ? [flag, value] : [] }
die USAGE unless args.empty?

recs = Record.all
die "nothing imported yet — run the import-individual-history skill first" if recs.empty?

kept, unused = Roster.select(recs, excludes)
Roster.report(recs, kept, unused)
die "every imported Scout was excluded" if kept.empty?

plans = Record.plans(kept.map { |rec| rec["name"] }, forwarded)
# A Scout who has earned Eagle has no working rank and nothing left to plan.
pairs = kept.zip(plans.map { |plan| plan["working_rank"] })
            .select { |_, working| working }

if command == "verify"
  Verify.call(recs, pairs, plans)
  exit 0
end

state = { pairs: pairs, plans: plans }
state[:cohorts]   = Cohorts.rows(pairs, plans)
state[:load]      = Load.rows(state[:cohorts])
state[:themes]    = Themes.tally(pairs)
state[:clocks]    = Clocks.rows(plans)
state[:slots]     = BadgeWork.slots(plans)
state[:partials]  = BadgeWork.partials(plans)
state[:stalled]   = BadgeWork.stalled(plans, opts[:stalled])
state[:attention] = Attention.rows(pairs, plans, opts)
state[:service]   = ServiceWork.summary(ServiceWork.rows(plans))

case command
when "brief" then Brief.call(state, opts)
when "cohorts"
  Render.header(plans, pairs.size, plans.first["target"])
  Show.cohorts(state[:cohorts])
  Show.banked(state[:cohorts], opts[:min_banked])
when "themes"    then Show.themes(state[:themes], opts[:min], state[:service])
when "clocks"    then Show.clocks(state[:clocks], opts[:soon])
when "load"      then Show.load(state[:load], opts[:per_meeting])
when "badges"    then Show.badges(state[:slots], state[:partials], state[:stalled], opts[:min])
when "attention" then Show.attention(state[:attention])
when "json"      then puts JSON.pretty_generate(build(state, opts))
end
