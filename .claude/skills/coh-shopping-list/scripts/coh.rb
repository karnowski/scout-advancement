#!/usr/bin/env ruby
# frozen_string_literal: true

#
# coh-shopping-list — turn a TroopMaster "Court Of Honor" report into a Scout
# Shop order, by subtracting what the troop already holds.
#
#   ruby scripts/coh.rb verify  REPORT.pdf
#   ruby scripts/coh.rb badges  REPORT.pdf
#   ruby scripts/coh.rb awards  REPORT.pdf
#   ruby scripts/coh.rb restock REPORT.pdf
#   ruby scripts/coh.rb order   REPORT.pdf
#   ruby scripts/coh.rb notes   REPORT.pdf
#   ruby scripts/coh.rb json    REPORT.pdf
#
# Inventory comes from the badge-inventory skill (`inventory.rb list --json`),
# never from reading the spreadsheet here. Requirement text and the badge list
# come from scout-req. This script owns exactly one thing: the arithmetic
# between a report and a box of patches.
#
# --------------------------------------------------------------------------
# Facts about the report and the troop's process this script depends on
# --------------------------------------------------------------------------
#
# * **The troop distributes on two different clocks, and the whole order splits
#   along that line.** Rank patches and position patches are handed over as soon
#   as they are earned ("immediate"); merit badges, special awards, National
#   Outdoor Awards, and both the youth and adult rank pins are held for the
#   ceremony ("court of honor"). So a rank appearing in the report does **not**
#   mean a rank patch must be bought for it — that patch left the box weeks ago.
#   It means two *pins* are needed. Getting this backwards produces an order
#   that is wrong in both directions at once: it buys rank patches nobody is
#   waiting for and misses the pins that are actually short.
#
# * **Every merit badge handed over comes with a merit badge card, and cards
#   are sold by the package.** One card per badge awarded, so the need is the
#   report's own merit badge total. The Scout Shop's usual unit is a package of
#   100 — single cards turn up but are not reliable — so an order is a whole
#   number of packages, rounded up. Nothing is subtracted from it: the
#   inventory sheet has no row for cards and is not meant to grow one, so the
#   line is a ceiling that says "check the drawer", not a measured shortfall.
#   A bare package count is never printed on its own, because "2" against a
#   need of 107 is two packages, not two cards.
#
# * **The sheet counts retired designs in a column of their own, and so does
#   this.** `inventory.rb` reports an `Out of Date` count beside `Count` —
#   patches that are in the box but of a design the troop no longer hands out
#   (Lifesaving reads `Count` 0, `Out of Date` 2). The sheet keeps the two
#   apart deliberately and nothing here folds them together: an out-of-date
#   patch is never in `on_hand`, never reduces a `short`, and never takes a
#   line off the order. Whether an older border is good enough anyway is the
#   Advancement Chair's call, so the number rides along on `Stock` to be
#   reported — with the sheet's own note ("no PFD on rower"), which is what
#   that call gets made on.
#
# * **The report carries its own tally, unlike the Target grids.** The last page
#   is an "Awards Summary" whose section headers declare the totals ("15 Rank
#   Badges", "107 Merit Badges"). `verify` checks three things against each
#   other: the declared total, the summary's own line items, and an independent
#   re-tally of the per-Scout detail pages. All three must agree. A layout
#   misparse shows up as a number that is merely plausible, so this is not
#   optional.
#
# * **The summary is two columns of items, and column boundaries are the only
#   thing separating them.** A regex over the line will happily read
#   "Citizenship In Nation* MB 10304 1 Metalwork MB" as one item name. Split on
#   runs of two-or-more spaces instead and take the fields positionally.
#
# * **Special Awards have no item code; every other section does.** Rank,
#   Merit Badge, and National Outdoor Award lines are (name, code, quantity)
#   triples, Special Awards lines are (name, quantity) pairs. Slicing all four
#   sections by three silently shifts the Special Awards quantities into the
#   names.
#
# * **Detail lines only name their kind once.** The first entry under a Scout
#   reads "Merit Badge:  Insect Study MB  07/10/26" and the rest are bare
#   continuation lines. The parser carries the last-seen kind forward, and
#   resets it at each Scout, so an unlabelled line is never orphaned.
#
# * **A rank's on-hand count is only usable if it was taken after the award.**
#   Rank patches go out immediately, so a count from before a Scout ranked up
#   still includes a patch that has since left the box. The sheet's own notes
#   ("last awarded to ...") are the Advancement Chair recording exactly this.
#   `effective_on_hand` subtracts any award dated after the row's Last Checked;
#   in a healthy report that subtraction is zero, and `verify` says so per rank
#   rather than assuming it.
#
# * **A count taken before this report's award period cannot reflect the last
#   court of honor.** The period start is printed at the top of every page
#   ("04/08/26 - 08/18/26"). Anything counted before that date is reported as
#   unreliable rather than used — that is what catches the position patches,
#   whose counts predate the spring ceremony by months.
#
# * **TroopMaster and the inventory sheet do not spell things alike.** Badge
#   names carry a trailing " MB" and an "*" on the Eagle-required ones. Beyond
#   that, `normalize` — which **must stay identical to `normalize` in
#   `req.rb`, `mbc.rb`, and `inventory.rb`** — folds nearly everything: it drops
#   "and"/"the", so "Citizenship In Nation*" meets "Citizenship in the Nation"
#   and "Small Boat Sailing" meets "Small-Boat Sailing". Prefix matching in
#   either direction closes the rest ("Fish and Wildlife" → "Fish and Wildlife
#   Management", "Paul Bunyan Woodsman" → "Paul Bunyan"). Only the National
#   Outdoor Awards need a hand-written alias: nothing folds "NOA - Hiking" into
#   "National Outdoor Awards (Hiking)". Lookups are scoped to the tab that can
#   hold the item, so a loose prefix cannot reach across into a different kind.
#
# * **A National Outdoor Award is up to three separate purchases.** The
#   pentagon-shaped base badge — the "award center emblem" — is the award
#   itself; the segments (Riding, Hiking, Camping, Aquatics, Adventure,
#   Conservation) are sewn around it; and the gold and silver devices are small
#   pins added to a segment already on the uniform, for further experience. The
#   report names segments ("NOA - Hiking", under National Outdoor Awards) and
#   devices ("NOA Camping Gold", under Special Awards) but **never the
#   pentagon**, because a Scout needs one only with their first segment ever
#   and TroopMaster does not record it separately. So the pentagon is inferred,
#   and can only be a ceiling: one per Scout who earned a segment in this
#   period, flagged for the Advancement Chair to check against each Scout's own
#   history. Every gold device is the same pin whatever segment it goes on, so
#   the per-segment device lines are summed before they are subtracted from the
#   one stock of devices — two lines each subtracted from a stock of one would
#   both come out covered.
#
# * **An item absent from the sheet is not an item the troop lacks.** The sheet
#   is a hand-kept inventory, not a catalogue — it has no row for the NOA silver
#   device at all. That is reported as "not tracked", separately from a real
#   zero, because only one of the two is a fact about the box.
#
# * **A blank count is not zero.** `inventory.rb` stores "nobody ever wrote a
#   number here" as null. It is carried through as unknown.
#
# * **The report names Scouts on every page.** Nothing this script prints may
#   reach a tracked file — see CLAUDE.md. `plans/` is gitignored and is where
#   generated output belongs.

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "json"
require "open3"
require "rbconfig"

INVENTORY_SCRIPT = File.join(REPO_ROOT, ".claude", "skills", "badge-inventory",
                             "scripts", "inventory.rb")

# Which tab of the inventory sheet can hold each kind of report line, and which
# clock the troop distributes it on.
KINDS = {
  "Rank" => { label: "Rank Badges", tab: "Ranks",
              section: 0, clock: :immediate },
  "Merit Badge" => { label: "Merit Badges", tab: "Merit Badges",
                     section: 0, clock: :court_of_honor },
  "National Outdoor Awards" => { label: "National Outdoor Awards", tab: "Awards",
                                 section: 0, clock: :court_of_honor },
  "Special Awards" => { label: "Special Awards", tab: "Awards",
                        section: 0, clock: :court_of_honor }
}.freeze

# Rank pins live in the Ranks tab's second block and are named off the rank.
PIN_SECTION = 1
PIN_KINDS = %w[Youth Adult].freeze

# Ranks are always listed lowest to highest, never alphabetically and never in
# whatever order a report happens to print them — the Awards Summary's two-column
# layout reads out as Scout, First Class, Tenderfoot, Star, ..., which is the
# order of the page rather than the order of advancement.
RANK_ORDER = ["Scout", "Tenderfoot", "Second Class", "First Class",
              "Star", "Life", "Eagle"].freeze

# Everything else is listed merit badges first, then awards, each alphabetical.
# Rank groups keep RANK_ORDER instead. The cards follow the patches they go
# out with, and precede the awards.
GROUP_ORDER = ["Merit badge patches", "Merit badge cards", "Awards",
               "Rank pins", "Rank patches"].freeze

# The troop hands a merit badge card to the Scout with every merit badge, so
# one card is consumed per badge awarded and the report's merit badge total is
# the need. The Scout Shop sells them by the package; 100 is the usual size.
MERIT_BADGE_CARD  = "Merit Badge Cards"
CARDS_PER_PACKAGE = 100

# How many of each rank patch the troop tries to keep on hand. Rank patches are
# awarded the day they are earned, so the report cannot say what to buy — these
# bands do. Below the low end, order back up to the high end; a band is a
# min/max, not a target, so stock is not topped up on every trip.
#
# The split is by how fast a rank moves and how many Scouts are behind it: the
# ranks up to First Class turn over faster and are kept deeper.
RANK_BANDS = {
  "Scout" => 7..10,
  "Tenderfoot" => 7..10,
  "Second Class" => 7..10,
  "First Class" => 7..10,
  "Star" => 5..8,
  "Life" => 5..8,
  "Eagle" => 5..8
}.freeze

# The one abbreviation no amount of folding will bridge: the report writes
# "NOA - Hiking" where the sheet writes "National Outdoor Awards (Hiking)".
# Expanding the leading token is general enough to cover a segment the troop
# has not started tracking yet, which a hand-written alias table would not be.
EXPANSIONS = { "noa" => "national outdoor awards" }.freeze

# The National Outdoor Award is three things the Scout Shop sells separately,
# and the report names only two of them. A segment line ("NOA - Hiking") is a
# segment patch; a device line ("NOA Camping Gold") is a small gold or silver
# pin added to a segment patch the Scout is already wearing. The pentagon base
# badge goes with a Scout's *first* segment, and nothing in the report says
# whether that has already happened — see `pentagon_items`.
NOA_SEGMENTS = %w[Riding Hiking Camping Aquatics Adventure Conservation].freeze
NOA_SEGMENT_LINE = /\ANOA\s*-\s*(#{Regexp.union(NOA_SEGMENTS)})\z/i
NOA_DEVICE_LINE  = /\ANOA\s+(#{Regexp.union(NOA_SEGMENTS)})\s+(Gold|Silver)\z/i
NOA_PENTAGON = "National Outdoor Awards (pentagon)"

IGNORED_WORDS = %w[and the].freeze

# Must stay identical to `normalize` in req.rb, mbc.rb, and inventory.rb.
def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# --------------------------------------------------------------------------
# the report
# --------------------------------------------------------------------------
Entry = Struct.new(:scout, :kind, :name, :date, keyword_init: true)
Line  = Struct.new(:kind, :name, :code, :qty, keyword_init: true)

class Report
  attr_reader :period_start, :period_end, :entries, :lines

  NOISE  = /Page \d+|Court Of Honor|Awards Summary/
  PERIOD = %r{\A\s*(\d\d/\d\d/\d\d) - (\d\d/\d\d/\d\d)\s*\z}
  KIND   = Regexp.union(KINDS.keys)
  DATED  = %r{\A\s*(?:(#{KIND}):)?\s*(\S.*?)\s{2,}(\d\d/\d\d/\d\d)\s*\z}
  SCOUT  = /\A\s{0,4}(\S[^:]*,\s*\S.*?)\s*\z/

  def initialize(path)
    die "no such file: #{path}" unless File.exist?(path)
    text = extract(path)
    detail, @tail = text.split(/^& - Award earned prior.*$/, 2)
    die "#{path}: no Awards Summary — is this a Court Of Honor report?" if @tail.nil?

    @period_start, @period_end = read_period(text)
    @entries = read_detail(detail)
    @lines   = read_summary
  end

  def scouts = entries.map(&:scout).uniq

  # The total the section header itself declares, e.g. "107 Merit Badges".
  def declared(kind)
    @tail[/^\s*(\d+) #{Regexp.escape(KINDS[kind][:label])}\s*$/, 1]&.to_i
  end

  def lines_for(kind) = lines.select { |l| l.kind == kind }

  def entries_for(kind) = entries.select { |e| e.kind == kind }

  # Latest date on which anything of this kind and name was earned.
  def last_awarded(kind, name)
    entries.select { |e| e.kind == kind && e.name == name }.map(&:date).max
  end

  private

  def extract(path)
    out, err, status = Open3.capture3("pdftotext", "-layout", path, "-")
    die "pdftotext failed on #{path}: #{err.strip}" unless status.success?
    out
  end

  def read_period(text)
    m = text.lines.lazy.filter_map { |l| l.match(PERIOD) }.first
    die "no award period line at the top of the report" if m.nil?
    [parse_date(m[1]), parse_date(m[2])]
  end

  def parse_date(str)
    Date.strptime(str, "%m/%d/%y")
  rescue Date::Error
    die "unparseable date #{str.inspect} in the report"
  end

  # A dated line inherits the last "Kind:" seen for this Scout; an undated
  # "Last, First" line starts a new Scout and clears the kind.
  def read_detail(detail)
    scout = nil
    kind = nil
    detail.each_line.with_object([]) do |line, out|
      next if line.strip.empty? || line.match?(NOISE) || line.match?(PERIOD)

      if (m = line.match(DATED))
        kind = m[1] if m[1]
        die "dated line before any Scout: #{line.strip.inspect}" if scout.nil?
        die "dated line before any kind: #{line.strip.inspect}" if kind.nil?
        out << Entry.new(scout:, kind:, name: m[2].strip, date: parse_date(m[3]))
      elsif (m = line.match(SCOUT))
        scout = m[1]
        kind = nil
      else
        die "unparsed detail line: #{line.strip.inspect}"
      end
    end
  end

  def read_summary
    KINDS.each_key.flat_map do |kind|
      body = @tail[/^\s*\d+ #{Regexp.escape(KINDS[kind][:label])}\s*$(.*?)(?:^\s*$|\z)/m, 1]
      next [] if body.nil?

      # Two columns of items; only the column gaps separate them, so split on
      # runs of spaces and take the fields positionally.
      fields = body.lines.flat_map { |l| l.strip.split(/\s{2,}/) }.reject(&:empty?)
      coded = kind != "Special Awards"   # Special Awards carry no item code
      fields.each_slice(coded ? 3 : 2).map do |name, a, b|
        Line.new(kind:, name:, code: (a if coded), qty: (coded ? b : a).to_i)
      end
    end
  end
end

# --------------------------------------------------------------------------
# the inventory, via the badge-inventory skill
# --------------------------------------------------------------------------
module Inventory
  module_function

  def rows
    @rows ||= begin
      out, err, status = Open3.capture3(RbConfig.ruby, INVENTORY_SCRIPT, "list", "--json")
      unless status.success?
        die "badge-inventory could not list the sheet (#{err.strip.lines.first})"
      end
      JSON.parse(out)
    end
  end

  # Scoped to the tab that can hold this kind of item, so a loose prefix match
  # can never reach across into a different kind of patch.
  def find(name, tab:, section: nil)
    pool = rows.select { |r| r["category"] == tab }
    pool = pool.select { |r| r["section_index"] == section } unless section.nil?

    candidates(name).each do |n|
      hit = pool.find { |r| r["norm"] == n } ||
            pool.find { |r| r["norm"].start_with?(n) } ||
            pool.find { |r| n.start_with?(r["norm"]) }
      return hit if hit
    end
    nil
  end

  def candidates(name)
    n = normalize(name)
    head, rest = n.split(" ", 2)
    [n, ([EXPANSIONS[head], rest].compact.join(" ") if EXPANSIONS.key?(head))].compact
  end
end

# What the troop holds of one item, and how far that number can be trusted.
class Stock
  attr_reader :row, :spent_since_count

  def initialize(row, spent_since_count: 0)
    @row = row
    @spent_since_count = spent_since_count
  end

  def tracked? = !row.nil?
  def counted? = tracked? && !row["count"].nil?

  # A row the sheet ought to have and does not — worth reporting so someone
  # goes and looks. Not the same as an item nobody counts; see Uncounted.
  def missing_row? = !tracked?
  def name = row&.fetch("name")

  # What to call the item: the sheet's spelling once matched, since that is the
  # name it is ordered and filed under. "Fish and Wildlife" on the report is
  # "Fish and Wildlife Management" in the box.
  def label_for(reported) = tracked? ? name : reported
  def notes = row&.fetch("notes").to_s
  def checked = counted? ? Date.parse(row["last_checked"]) : nil

  # The count minus anything that left the box after the count was taken.
  def on_hand = counted? ? row["count"] - spent_since_count : nil

  def short(need) = counted? ? [need - on_hand, 0].max : need

  # Patches in the box of a design the troop no longer hands out. The sheet
  # keeps this out of `Count`, and so does everything above it: it is not in
  # `on_hand` and it never reduces a `short`. It is carried only so the order
  # can say the patches are there — see `Notes.retired`.
  def out_of_date = row ? row["out_of_date"].to_i : 0
  def out_of_date? = out_of_date.positive?

  def describe
    return "not tracked on the inventory sheet" unless tracked?

    [count_description, retired_description].compact.join("; ")
  end

  def count_description
    return "count is blank — never recorded" unless counted?

    s = "checked #{row['last_checked']}"
    s += ", less #{spent_since_count} awarded after that count" if spent_since_count.positive?
    s
  end

  # Said beside the count, never taken off it.
  def retired_description
    "plus #{out_of_date} of an older design" if out_of_date?
  end
end

# An item the troop deliberately does not count. The sheet is a record of
# patches in a box, and nobody is ever going to tally a drawer of merit badge
# cards, so listing this under "not tracked on the inventory sheet" would be
# noise rather than something to go fix. `short` still returns the whole need,
# which is what makes the resulting line a ceiling rather than a shortfall.
class Uncounted < Stock
  def initialize(reason)
    super(nil)
    @reason = reason
  end

  def missing_row? = false
  def describe = @reason
end

# --------------------------------------------------------------------------
# the order
# --------------------------------------------------------------------------
# `need` is how many the ceremony calls for; `band` is how many the troop keeps
# on the shelf. An item has one or the other, never both — that is exactly the
# difference between the two distribution clocks.
# `caveat` is what the arithmetic cannot settle on its own — the NOA pentagon
# count is a ceiling, not a number. A line carrying one is printed even when
# there is nothing to buy, because the caveat is the reason to look at it.
# `pack` is set when the Scout Shop sells the item only by the package, which
# splits every quantity this item reports into two units — see `buy`.
Item = Struct.new(:group, :reported, :need, :stock, :band, :rank, :pin, :caveat,
                  :pack, keyword_init: true) do
  def label = stock.label_for(reported)

  # Group first, then rank order for anything rank-shaped, then alphabetically
  # by the name it will actually be ordered under. One key, used everywhere a
  # list of items is printed, so no two views can disagree.
  def sort_key
    [GROUP_ORDER.index(group) || GROUP_ORDER.size,
     rank ? (RANK_ORDER.index(rank) || RANK_ORDER.size) : 0,
     pin ? PIN_KINDS.index(pin) : 0,
     label.downcase]
  end

  def zero_margin? = band.nil? && stock.counted? && stock.on_hand == need

  # How many to put in the basket: single patches for most things, whole
  # packages for anything the Scout Shop sells only by the package.
  def buy
    return packages(stock.short(need)) if band.nil?
    return 0 unless stock.counted?

    packages(stock.on_hand < band.min ? band.max - stock.on_hand : 0)
  end

  # What `buy` actually brings home. Two packages of 100 is 200 cards against a
  # need counted in single cards, so both numbers have to be said out loud.
  def buy_units = pack ? buy * pack : buy

  # Round up — 107 cards short is two packages, not one and a bit.
  def packages(count) = pack ? count.ceildiv(pack) : count

  # Why the line reads the way it does, for the restock table.
  def verdict
    return "unknown" unless stock.counted?
    return "BUY #{buy}" if buy.positive?

    stock.on_hand > band.max ? "ok (over)" : "ok"
  end
end

class Plan
  attr_reader :report

  def initialize(report)
    @report = report
  end

  # Held back for the ceremony: merit badges, their cards, awards, and both
  # rank pins.
  def court_of_honor_items
    @court_of_honor_items ||=
      (badge_and_award_items + card_items + pin_items).sort_by(&:sort_key)
  end

  # Handed over on the day it was earned, so the box is rebuilt against the
  # troop's stock bands. This covers every rank, including the ones nobody
  # earned this period — a rank absent from the report can still be short.
  def restock_items
    @restock_items ||= RANK_BANDS.map do |rank, band|
      die "RANK_BANDS names #{rank.inspect}, which is not in RANK_ORDER" unless
        RANK_ORDER.include?(rank)

      Item.new(group: "Rank patches", reported: rank, need: nil,
               stock: rank_stock(rank), band:, rank:)
    end.sort_by(&:sort_key)
  end

  # How many of this rank the report says went out; context for the table, not
  # an input to the arithmetic.
  def awarded(rank)
    report.lines_for("Rank").find { |l| l.name == rank }&.qty || 0
  end

  def items = (court_of_honor_items + restock_items).sort_by(&:sort_key)

  def buys = items.reject { |i| i.buy.zero? }

  private

  def badge_and_award_items
    pairs = KINDS.select { |_, v| v[:clock] == :court_of_honor }
                 .flat_map { |kind, cfg| report.lines_for(kind).map { |l| [l, kind, cfg] } }
    devices, plain = pairs.partition { |line, _, _| line.name.match?(NOA_DEVICE_LINE) }

    plain.map do |line, kind, cfg|
      base = line.name.sub(/\s*\*?\s*MB\z/, "").strip
      stock = Stock.new(Inventory.find(base, tab: cfg[:tab], section: cfg[:section]))
      Item.new(group: kind == "Merit Badge" ? "Merit badge patches" : "Awards",
               reported: base, need: line.qty, stock:)
    end + device_items(devices) + pentagon_items
  end

  # A gold device is the same pin whichever segment it goes on, so every
  # segment's device lines draw on one stock and have to be added up before
  # they are subtracted from it. Left as separate lines, two needs of one
  # against a stock of one would both come out covered.
  def device_items(pairs)
    pairs.group_by { |line, _, _| line.name[NOA_DEVICE_LINE, 2].capitalize }
         .map do |metal, group|
      name = "National Outdoor Awards (#{metal} Device)"
      qty = group.sum { |line, _, _| line.qty }
      segments = group.map { |line, _, _| line.name[NOA_DEVICE_LINE, 1] }.uniq.sort
      Item.new(group: "Awards", reported: name, need: qty,
               stock: Stock.new(Inventory.find(name, tab: "Awards", section: 0)),
               caveat: "pin#{'s' unless qty == 1} added to the " \
                       "#{segments.join(', ')} segment#{'s' unless segments.one?} " \
                       "already on the uniform")
    end
  end

  # A Scout needs the pentagon base badge with their *first* segment, and the
  # report covers one award period — it cannot say whether a Scout earned a
  # segment two years ago. So this is a ceiling, one per Scout who earned any
  # segment this period, and it is flagged rather than quietly ordered:
  # `Notes.noa_pentagons` names the Scouts whose history has to be checked.
  def pentagon_items
    scouts = report.entries.select { |e| e.name.match?(NOA_SEGMENT_LINE) }.map(&:scout).uniq
    return [] if scouts.empty?

    [Item.new(group: "Awards", reported: NOA_PENTAGON, need: scouts.size,
              stock: Stock.new(Inventory.find(NOA_PENTAGON, tab: "Awards", section: 0)),
              caveat: "at most one each for #{scouts.size} Scout" \
                      "#{'s' unless scouts.one?} — check whether the pentagon " \
                      "was already awarded for an earlier segment")]
  end

  # One merit badge card per badge awarded, bought by the package. Nothing is
  # subtracted: the sheet has no row for cards and is not meant to grow one, so
  # the number covers the whole ceremony and the caveat says to look in the
  # drawer first. The need is the summary's own total, which `verify` has
  # already reconciled against the detail pages three ways.
  def card_items
    need = report.lines_for("Merit Badge").sum(&:qty)
    return [] if need.zero?

    [Item.new(group: "Merit badge cards", reported: MERIT_BADGE_CARD, need:,
              pack: CARDS_PER_PACKAGE,
              stock: Uncounted.new("cards on hand are not counted anywhere"),
              caveat: "one card per merit badge awarded; subtract whatever is " \
                      "already in the drawer — single cards are not always in stock")]
  end

  # One youth pin and one adult pin for every rank earned in the period.
  def pin_items
    report.lines_for("Rank").flat_map do |line|
      PIN_KINDS.map do |who|
        name = "#{line.name} #{who} Pin"
        stock = Stock.new(Inventory.find(name, tab: "Ranks", section: PIN_SECTION))
        Item.new(group: "Rank pins", reported: name, need: line.qty, stock:,
                 rank: line.name, pin: who)
      end
    end
  end

  # A rank patch left the box the day it was earned, so any award dated after
  # the physical count is not reflected in that count.
  def rank_stock(rank)
    row = Inventory.find(rank, tab: "Ranks", section: 0)
    spent = 0
    if row && row["last_checked"]
      checked = Date.parse(row["last_checked"])
      spent = report.entries_for("Rank").count { |e| e.name == rank && e.date > checked }
    end
    Stock.new(row, spent_since_count: spent)
  end
end

# --------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------
module Verify
  module_function

  # Three independent numbers per section must agree: the total the header
  # declares, the sum of the summary's own line items, and a re-tally of the
  # per-Scout detail pages.
  def ok?(report)
    problems = KINDS.each_key.flat_map { |kind| check_kind(report, kind) }
    problems += check_unknown_kinds(report)
    problems += check_noa_names(report)
    notes = rank_count_notes(report)

    problems.each { |p| puts "FAIL: #{p}" }
    notes.each { |n| puts "note: #{n}" }
    if problems.empty?
      puts "OK: #{report.scouts.size} Scouts, " \
           "#{KINDS.each_key.map do |k|
             "#{report.declared(k)} #{KINDS[k][:label].downcase}"
           end.join(', ')}."
    end
    problems.empty?
  end

  def check_kind(report, kind)
    declared = report.declared(kind)
    return ["#{kind}: no section header in the Awards Summary"] if declared.nil?

    lines = report.lines_for(kind)
    detail = report.entries_for(kind)
    problems = []
    if lines.sum(&:qty) != declared
      problems << "#{kind}: summary lines total #{lines.sum(&:qty)}, header declares #{declared}"
    end
    if detail.size != declared
      problems << "#{kind}: detail pages hold #{detail.size} entries, header declares #{declared}"
    end
    problems + check_items(kind, lines, detail)
  end

  # Every summary line must match the detail pages item by item, not just in total.
  def check_items(kind, lines, detail)
    counted = detail.group_by(&:name).transform_values(&:size)
    lines.filter_map do |line|
      got = counted.delete(line.name)
      "#{kind}: #{line.name} — summary #{line.qty}, detail #{got.inspect}" if got != line.qty
    end + counted.map do |name, n|
            "#{kind}: #{name} × #{n} on the detail pages but not in the summary"
          end
  end

  def check_unknown_kinds(report)
    (report.entries.map(&:kind).uniq - KINDS.keys)
      .map { |k| "unrecognised award kind #{k.inspect} — this script would silently drop it" }
  end

  # Every NOA line is a segment or a device, and the two are ordered as
  # different things. A third shape means a segment name this script does not
  # know, which would be priced as an ordinary award and skip the pentagon.
  def check_noa_names(report)
    names = (report.entries.map(&:name) + report.lines.map(&:name)).uniq
    names.grep(/\ANOA\b/i)
         .reject { |n| n.match?(NOA_SEGMENT_LINE) || n.match?(NOA_DEVICE_LINE) }
         .map do |n|
           "unrecognised National Outdoor Award line #{n.inspect} — " \
             "neither a known segment nor a gold/silver device"
         end
  end

  # Not failures: statements about how far each rank count can be trusted.
  def rank_count_notes(report)
    report.lines_for("Rank").sort_by { |l| RANK_ORDER.index(l.name) || RANK_ORDER.size }
                            .filter_map do |line|
      row = Inventory.find(line.name, tab: "Ranks", section: 0)
      next "#{line.name}: no rank patch row on the inventory sheet" if row.nil?
      next "#{line.name}: rank patch count is blank" if row["count"].nil?

      checked = Date.parse(row["last_checked"])
      last = report.last_awarded("Rank", line.name)
      next if checked >= last

      "#{line.name}: counted #{checked} but last awarded #{last} — " \
        "the count predates the award, so on-hand is reduced accordingly"
    end
  end
end

# --------------------------------------------------------------------------
# things worth saying out loud before ordering
# --------------------------------------------------------------------------
module Notes
  module_function

  def all(report, plan)
    { "Awarded twice to the same Scout" => duplicates(report),
      "Earned an NOA segment — check whether they already have the pentagon" =>
        noa_pentagons(report),
      "Zero margin — need exactly equals stock" => zero_margin(plan),
      "Bought by the package, and never counted" => packaged(plan),
      "Not tracked on the inventory sheet" => untracked(plan),
      "Older design in the box, counted separately" => retired(plan),
      "Counted before this award period began" => stale(report, plan) }
  end

  # The same award to the same Scout on two dates is almost always a double
  # entry rather than a second award, and it inflates the order.
  def duplicates(report)
    report.entries.group_by { |e| [e.scout, e.kind, e.name] }
                  .select { |_, es| es.size > 1 }
                  .sort_by { |(scout, kind, name), _| [KINDS.keys.index(kind), name, scout] }
                  .map do |(scout, _, name), es|
      "#{name} × #{es.size} for #{scout} (#{es.map(&:date).join(', ')})"
    end
  end

  # The pentagon goes with a Scout's first segment ever; this report covers one
  # award period, so it can name the Scouts but never answer the question. The
  # order carries a pentagon for each of them, and this is the list to check
  # against their advancement histories before the trip to the Scout Shop.
  def noa_pentagons(report)
    report.entries.select { |e| e.name.match?(NOA_SEGMENT_LINE) }
                  .group_by(&:scout).sort.map do |scout, es|
      "#{scout} — #{es.map { |e| e.name[NOA_SEGMENT_LINE, 1] }.uniq.sort.join(', ')}"
    end
  end

  def zero_margin(plan)
    plan.court_of_honor_items.select(&:zero_margin?)
        .map { |i| "#{i.label} — need #{i.need}, have #{i.stock.on_hand} (#{i.stock.describe})" }
  end

  # Nobody counts these, so the order covers the whole ceremony and the figure
  # is a ceiling. Say so, rather than letting it read as a measured shortfall.
  def packaged(plan)
    plan.items.reject { |i| i.pack.nil? }.map do |i|
      "#{i.label} — #{i.need} needed, #{i.buy} package#{'s' unless i.buy == 1} " \
        "of #{i.pack} (#{i.buy_units}) unless the drawer already holds some"
    end
  end

  # A row the sheet ought to have and does not. An item the troop deliberately
  # never counts is not one of these — it has its own heading above.
  def untracked(plan)
    plan.items.select { |i| i.stock.missing_row? }.map { |i| "#{i.label} (need #{i.need})" }
  end

  # The sheet counts retired designs apart from `Count`, and so does the
  # arithmetic above — an old-border patch is not one you can hand a Scout, so
  # it takes nothing off the order. Whether it is good enough anyway is the
  # Advancement Chair's decision, and this is the list they make it from; the
  # sheet's own note is what says what is wrong with the patch.
  def retired(plan)
    plan.items.select { |i| i.stock.out_of_date? }.map { |i| retired_line(i) }
  end

  def retired_line(item)
    old = item.stock.out_of_date
    line = "#{item.label} — #{old} of an older design in the box, not in the count"
    line += " (#{item.stock.notes})" unless item.stock.notes.empty?
    return line unless item.buy.positive?

    "#{line}; the order carries #{item.buy} — up to " \
      "#{[item.buy, old].min} fewer if an older border will do"
  end

  # A count older than the period start cannot reflect the previous ceremony.
  def stale(report, plan)
    plan.items.select { |i| i.stock.counted? && i.stock.checked < report.period_start }
              .map do |i|
                "#{i.label} — counted #{i.stock.checked}, " \
                  "period opened #{report.period_start}"
              end
              .uniq
  end
end

# --------------------------------------------------------------------------
# rendering — Markdown, so `order` writes directly to a plans/*.md file
# --------------------------------------------------------------------------
module Render
  module_function

  # Table cells are never free text a Scout typed, but a badge or rank name
  # could in principle carry a literal "|" — escape it so one stray character
  # can't tear the row apart.
  def cell(str) = str.to_s.gsub("|", "\\|")

  # A package count is meaningless on its own: "2" is two packages, which is
  # 200 cards against a need counted in single cards. Always print both.
  def quantity(item)
    return item.buy.to_s if item.pack.nil?

    "#{item.buy} package#{'s' unless item.buy == 1} of #{item.pack} (#{item.buy_units})"
  end

  # The same for a group of lines, which may mix the two units.
  def buy_total(items)
    items.group_by(&:pack).map do |pack, group|
      n = group.sum(&:buy)
      pack ? "#{n} package#{'s' unless n == 1} of #{pack}" : n.to_s
    end.join(" + ")
  end

  # "2 packages of merit badge cards (200)" — for the running total, where the
  # item's name reads better inside the phrase than beside it.
  def pack_phrase(item)
    "#{item.buy} package#{'s' unless item.buy == 1} of " \
      "#{item.label.downcase} (#{item.buy_units})"
  end

  def header(report)
    puts "# Court of Honor Shopping List"
    puts
    puts "- **Award period:** #{report.period_start} to #{report.period_end}"
    puts "- **Scouts:** #{report.scouts.size}"
    puts
  end

  def item_table(items)
    return if items.empty?

    puts "| Item | Need | Have | Buy | Notes |"
    puts "|---|---:|---:|---:|---|"
    items.each do |i|
      have = i.stock.counted? ? i.stock.on_hand.to_s : "-"
      note = [i.stock.describe, i.caveat].compact.join("; ")
      puts "| #{cell(i.label)} | #{i.need} | #{have} | #{quantity(i)} | #{cell(note)} |"
    end
    puts
  end

  def awards(report, plan, banner: true)
    header(report) if banner
    puts "## To award at the Court of Honor"
    puts
    puts "_Merit badges and their cards, awards, and both rank pins are held " \
         "back for the ceremony._"
    puts
    plan.court_of_honor_items.group_by(&:group).each do |group, items|
      puts "### #{group} — #{items.sum(&:need)} to hand out, #{buy_total(items)} to buy"
      puts
      # A caveat is the reason to look at a line, so it is shown even when the
      # arithmetic says there is nothing to buy.
      shown = items.reject { |i| i.buy.zero? && i.caveat.nil? }
      item_table(shown)
      covered = items.size - shown.size
      if covered.positive?
        puts "_#{covered} line#{'s' unless covered == 1} covered by stock on hand._"
        puts
      end
    end
  end

  def restock(report, plan, banner: true)
    header(report) if banner
    puts "## Restock immediate-award stock"
    puts
    puts "_Rank patches went out when they were earned; this rebuilds the box._"
    puts
    puts "Keep #{describe_bands}; below the low end, order back up to the high end."
    puts
    puts "| Rank | Keep | Awarded | On hand | Verdict |"
    puts "|---|---|---:|---:|---|"
    plan.restock_items.each do |i|
      have = i.stock.counted? ? i.stock.on_hand.to_s : "-"
      puts "| #{cell(i.label)} | #{i.band.min}-#{i.band.max} | #{plan.awarded(i.reported)} " \
           "| #{have} | #{cell(i.verdict)} |"
    end
    puts
    puts "_Position patches are immediate-award too, but the troop keeps no target for " \
         "them yet, so they are left out of this order._"
  end

  # "7-10 of Scout/Tenderfoot/..., 5-8 of Star/Life/Eagle" — read off the bands
  # themselves so the sentence cannot drift from the table under it.
  def describe_bands
    RANK_BANDS.sort_by { |rank, _| RANK_ORDER.index(rank) }
              .group_by { |_, band| band }
              .map { |band, pairs| "#{band.min}-#{band.max} of #{pairs.map(&:first).join('/')}" }
              .join(", ")
  end

  def notes(report, plan, banner: true)
    header(report) if banner
    puts "## Notes"
    puts
    Notes.all(report, plan).each do |title, list|
      next if list.empty?

      puts "### #{title} (#{list.size})"
      puts
      list.each { |n| puts "- #{n}" }
      puts
    end
  end

  def order(report, plan)
    header(report)
    awards(report, plan, banner: false)
    restock(report, plan, banner: false)
    puts
    puts "## Shopping list"
    puts
    plan.buys.group_by(&:group).each do |group, items|
      puts "### #{group}"
      puts
      items.sort_by(&:sort_key).each do |i|
        puts "- **#{i.label}** — buy #{quantity(i)} (#{reason(i)})#{" — #{i.caveat}" if i.caveat}"
      end
      puts
    end
    # Packages and single patches are different units, so they are never added
    # into one number — "43" hides two of them being 200 cards.
    packs, singles = plan.buys.partition(&:pack)
    total = "**Total items to buy: #{singles.sum(&:buy)}**"
    total += ", plus #{packs.map { |i| pack_phrase(i) }.join(', ')}" unless packs.empty?
    puts total
    puts
    notes(report, plan, banner: false)
  end

  # Why this line is on the order: a ceremony shortfall, or a shelf running low.
  # With no count behind it, the reason is the reason there is no count — "have
  # no count" reads like an oversight even when nobody was ever going to count.
  def reason(item)
    return "need #{item.need}, #{item.stock.describe}" if item.band.nil? && !item.stock.counted?

    have = item.stock.counted? ? item.stock.on_hand : "no count"
    return "need #{item.need}, have #{have}" if item.band.nil?

    "have #{have}, below the #{item.band.min}-#{item.band.max} kept on hand"
  end

  def badge_names(report)
    report.lines_for("Merit Badge")
          .map { |l| l.name.sub(/\s*\*?\s*MB\z/, "").strip }
          .sort.uniq.each { |n| puts n }
  end

  def json(report, plan)
    puts JSON.pretty_generate(
      period: { start: report.period_start.to_s, end: report.period_end.to_s },
      scouts: report.scouts.size,
      items: plan.items.map do |i|
        { group: i.group, item: i.label, need: i.need,
          keep: i.band && { low: i.band.min, high: i.band.max },
          on_hand: i.stock.on_hand, out_of_date: i.stock.out_of_date, buy: i.buy,
          pack_size: i.pack, buy_units: i.buy_units,
          tracked: i.stock.tracked?, last_checked: i.stock.checked&.to_s,
          sheet_name: i.stock.name, notes: i.stock.notes, caveat: i.caveat }
      end,
      flags: Notes.all(report, plan).reject { |_, v| v.empty? }
    )
  end
end

# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------
USAGE = <<~TEXT
  usage: ruby scripts/coh.rb COMMAND REPORT.pdf [options]

    verify   REPORT.pdf              cross-check the parse — run this first
    badges   REPORT.pdf              merit badge names, one per line, for req.rb check
    awards   REPORT.pdf              what gets handed out at the ceremony, and what is short
    restock  REPORT.pdf              rebuild the immediate-award stock
    order    REPORT.pdf              the whole Scout Shop order, plus what to check first
    notes    REPORT.pdf              only the things worth checking before ordering
    json     REPORT.pdf              the whole computation

  `badges` is meant to be piped, and exit 3 there means stop and read the banner:
      ruby scripts/coh.rb badges REPORT.pdf | ruby ../scout-req/scripts/req.rb check

  How deep to keep each rank patch is the RANK_BANDS table at the top of this
  file, not a flag — it is troop policy, and it belongs somewhere it can carry
  a comment saying why.
TEXT

command = ARGV.shift
path    = ARGV.shift
abort USAGE if command.nil? || path.nil? || path.start_with?("--")

report = Report.new(path)
plan   = Plan.new(report)

case command
when "verify"  then exit(Verify.ok?(report) ? 0 : 1)
when "badges"  then Render.badge_names(report)
when "awards"  then Render.awards(report, plan)
when "restock" then Render.restock(report, plan)
when "order"   then Render.order(report, plan)
when "notes"   then Render.notes(report, plan)
when "json"    then Render.json(report, plan)
else abort USAGE
end
