#!/usr/bin/env ruby
# frozen_string_literal: true

#
# badge-inventory — read the troop's badge inventory spreadsheet.
#
# Downloads every tab of the Google Sheet as CSV and caches the rows in SQLite
# under .cache/inventory.db, with the fetch time and each row's own
# "Last Checked" date.
#
#   ruby scripts/inventory.rb sync [--force]
#   ruby scripts/inventory.rb count NAME...
#   ruby scripts/inventory.rb list [--category NAME] [--section N] [--json]
#   ruby scripts/inventory.rb low [--at N]
#   ruby scripts/inventory.rb stale [--days N]
#   ruby scripts/inventory.rb verify
#   ruby scripts/inventory.rb info
#
# --------------------------------------------------------------------------
# Facts about the spreadsheet this script depends on
# --------------------------------------------------------------------------
#
# * **The sheet is link-shared, so no Google credentials are involved.** Every
#   fetch is a plain HTTP GET. If a future sheet is locked down, these URLs start
#   returning an HTML sign-in page instead of CSV, which `Fetch.csv` catches by
#   checking the content type rather than letting the HTML parse as one wide
#   column of garbage.
#
# * **`export?format=csv` with no `gid` returns the *first* tab, which is not
#   `gid=0`.** In this sheet `gid=0` is "Positions" while the first tab is
#   "Ranks". Never rely on the default; always pass an explicit gid.
#
# * **Tab names and gids come from the `/htmlview` page.** There is no
#   unauthenticated API that lists the tabs of a sheet, and the CSV endpoint
#   takes a gid but will not enumerate them. The htmlview HTML embeds
#   `items.push({name: "Ranks", pageUrl: "...", gid: "1256471678", ...})`, one
#   per tab, in tab order. That scrape is the one brittle step in this script, so
#   it fails loudly: a sheet that silently enumerated three of its four tabs
#   would produce an inventory that looks complete and is not.
#
# * **All four tabs share one 5-column shape** — a label column, `Count`,
#   `Last Checked`, `Checked by`, `Notes`. Only the first header cell differs
#   ("Rank", "Position", "Award", "MB"), so the header is validated on the last
#   four columns and the first is simply recorded.
#
# * **Blank rows are section breaks, not end-of-data.** The "Ranks" tab holds two
#   blocks separated by two blank rows: the rank patches themselves, then the
#   rank pins ("Scout Youth Pin", "Scout Adult Pin", ...). A parser that stopped
#   at the first blank row would silently drop every pin — which is half that
#   tab. Rows carry `section_index` so the structure survives, but the sections
#   are not given invented names; the item names already say what they are.
#
# * **The pin block does not cover every rank.** There are Youth and Adult pins
#   for Scout through Life, and none for Eagle. `verify` reports missing
#   rank/pin combinations as an observation, never as a failure — the troop
#   stores Eagle items separately, as that tab's own notes say.
#
# * **The Merit Badges tab is not the book's badge list.** It carries badges the
#   2025 printing does not have (Artificial Intelligence, Cybersecurity,
#   American Indian Culture) and spells Fly-Fishing as "Fly Fishing". `verify`
#   reconciles it through `scout-req`, and `normalize` folds the punctuation so
#   the hyphen is not a mismatch. Both directions are reported, because "we hold
#   no patches for that badge" and "that is not a badge" are different answers.
#
# * **The Notes column names Scouts** ("last awarded to ..."). The cache is under
#   .cache/, which .gitignore covers. Nothing from this script may be pasted into
#   a tracked file — see CLAUDE.md.
#
# * **Two dates matter and they are not the same.** `synced_at` is when this
#   script last downloaded the sheet; a row's `Last Checked` is when a human last
#   physically counted that item. A fresh sync over a count taken seven months
#   ago is still a seven-month-old count, so `stale` and `info` report the
#   second one and the answer commands print it alongside every number.

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "csv"
require "date"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "time"
require "uri"

require "sqlite3"

CACHE_DIR = File.join(SKILL_DIR, ".cache")
DB_PATH   = File.join(CACHE_DIR, "inventory.db")
SETTINGS  = File.join(REPO_ROOT, "TROOP-SETTINGS.md")
REQ_SCRIPT = File.join(REPO_ROOT, ".claude", "skills", "scout-req", "scripts", "req.rb")

SCHEMA_VERSION = 1
STALE_SECONDS  = 6 * 3600    # re-download if the cache is older than this
STALE_DAYS     = 90          # a physical count older than this wants re-checking

# The four columns every tab shares after its own label column.
COMMON_HEADER = ["Count", "Last Checked", "Checked by", "Notes"].freeze

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# Fold spelling differences between the sheet, the requirements book, and
# whatever the user typed. **This must stay identical to `normalize` in
# `req.rb` and `mbc.rb`** — "and" and "the" go because the book's own Merit
# Badge Library abbreviates that way. It is also what makes the sheet's
# "Fly Fishing" resolve against the book's "Fly-Fishing".
IGNORED_WORDS = %w[and the].freeze

def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------
module DB
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

  def init
    handle.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")

    # The cache is disposable; on a schema change just rebuild it.
    if meta("schema_version") != SCHEMA_VERSION.to_s
      handle.execute("DROP TABLE IF EXISTS items")
      set_meta("synced_at", "")
    end

    handle.execute_batch(<<~SQL)
      CREATE TABLE IF NOT EXISTS items (
        category      TEXT NOT NULL,             -- tab name, verbatim
        gid           TEXT NOT NULL DEFAULT '',
        tab_index     INTEGER NOT NULL DEFAULT 0,
        section_index INTEGER NOT NULL DEFAULT 0,
        row_index     INTEGER NOT NULL DEFAULT 0,
        name          TEXT NOT NULL,
        norm          TEXT NOT NULL DEFAULT '',
        count         INTEGER,                   -- NULL when the cell is blank
        last_checked  TEXT NOT NULL DEFAULT '',  -- YYYY-MM-DD, from the sheet
        checked_by    TEXT NOT NULL DEFAULT '',
        notes         TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (category, name)
      );
      CREATE INDEX IF NOT EXISTS idx_items_norm ON items (norm);
    SQL
    set_meta("schema_version", SCHEMA_VERSION.to_s)
  end

  # Called before init on a fresh cache, so a missing table is not an error.
  def meta(key)
    handle.get_first_value("SELECT value FROM meta WHERE key = ?", key)
  rescue SQLite3::SQLException
    nil
  end

  def set_meta(key, value)
    handle.execute("INSERT INTO meta (key, value) VALUES (?, ?) " \
                   "ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value.to_s])
  end

  COLUMNS = %i[category gid tab_index section_index row_index
               name norm count last_checked checked_by notes].freeze

  def replace_items(rows)
    handle.transaction do
      handle.execute("DELETE FROM items")
      stmt = handle.prepare(
        "INSERT OR REPLACE INTO items (#{COLUMNS.join(',')}) " \
        "VALUES (#{(['?'] * COLUMNS.size).join(',')})"
      )
      rows.each { |row| stmt.execute(row.values_at(*COLUMNS)) }
      stmt.close
    end
  end
end

# --------------------------------------------------------------------------
# the sheet URL
#
# TROOP-SETTINGS.md is the source of record (see CLAUDE.md); the environment
# variable is an override for trying a different sheet, and the cached value is
# the fallback so later runs work even if the settings file moves.
# --------------------------------------------------------------------------
module Source
  SHEET_ID = %r{/spreadsheets/d/([A-Za-z0-9_-]+)}
  HEADING  = /^#+\s*.*badge\s+inventory/i
  ANY_URL  = %r{https://docs\.google\.com/spreadsheets/\S+}

  module_function

  def url
    ENV["BADGE_INVENTORY_URL"] || from_settings || (DB.ready? ? DB.meta("source_url") : nil) ||
      die("No badge inventory sheet URL. Add a \"Badge inventory sheet\" section to\n" \
          "#{' ' * 7}TROOP-SETTINGS.md (see TROOP-SETTINGS.md.example), or set " \
          "BADGE_INVENTORY_URL.")
  end

  # Prefer a spreadsheet URL under a "Badge inventory" heading; fall back to the
  # only one in the file. Anything more than that would be guessing which sheet
  # a multi-sheet settings file meant.
  def from_settings
    return nil unless File.file?(SETTINGS)

    text = File.read(SETTINGS)
    after = text.split(HEADING, 2)[1]
    (after && after[ANY_URL]) || text[ANY_URL]
  end

  def sheet_id(url)
    url[SHEET_ID, 1] || die("Not a Google Sheets URL: #{url}")
  end
end

# --------------------------------------------------------------------------
# fetching
# --------------------------------------------------------------------------
module Fetch
  # One `items.push({name: "...", ..., gid: "123"})` per tab, in tab order.
  TAB_ENTRY = /items\.push\(\{name:\s*"((?:[^"\\]|\\.)*)".*?gid:\s*"(\d+)"/m

  module_function

  def get(url, redirects: 5)
    raise "too many redirects fetching #{url}" if redirects.negative?

    response = Net::HTTP.get_response(URI.parse(url))
    case response
    when Net::HTTPRedirection then get(response["location"], redirects: redirects - 1)
    when Net::HTTPSuccess     then response
    else raise "fetch failed (HTTP #{response.code}) for #{url}"
    end
  end

  def body(url) = get(url).body.to_s.force_encoding("UTF-8")

  # Tab names and gids, in the order the sheet shows them.
  def tabs(sheet_id)
    html = body("https://docs.google.com/spreadsheets/d/#{sheet_id}/htmlview")
    tabs = html.scan(TAB_ENTRY).map { |name, gid| { name: unescape(name), gid: gid } }.uniq

    raise "could not find any tabs on the sheet's htmlview page" if tabs.empty?

    tabs
  end

  # A CSV export, or a clear error if Google served a sign-in page instead.
  def csv(sheet_id, gid)
    response = get("https://docs.google.com/spreadsheets/d/#{sheet_id}/export?format=csv&gid=#{gid}")
    type = response["content-type"].to_s
    unless type.include?("csv")
      raise "the sheet did not return CSV for gid #{gid} (got #{type.split(';').first.inspect}). " \
            "It is probably no longer shared with anyone who has the link."
    end

    response.body.to_s.force_encoding("UTF-8")
  end

  def unescape(str)
    str.gsub(/\\u([0-9a-fA-F]{4})/) { ::Regexp.last_match(1).hex.chr(Encoding::UTF_8) }
       .gsub(/\\(.)/, '\1')
  end
end

# --------------------------------------------------------------------------
# parsing one tab
# --------------------------------------------------------------------------
module Tab
  module_function

  def blank?(row) = row.all? { |cell| cell.to_s.strip.empty? }

  # Rows for one tab. Blank rows advance section_index rather than ending the
  # tab: the Ranks tab keeps its pins in a second block below two blank rows.
  def rows(tab, tab_index, text)
    table = CSV.parse(text)
    header = table.shift or raise "tab #{tab[:name].inspect} is empty"
    check_header(tab[:name], header)

    section = 0
    pending = false
    table.each_with_index.filter_map do |row, index|
      # A run of blank rows is one break, and trailing blanks are no break at
      # all -- the Ranks tab separates its two blocks with two blank rows, so
      # counting each one would number the pins section 2 instead of 1.
      if blank?(row)
        pending = true
        next
      end
      if pending
        section += 1
        pending = false
      end
      build(tab, tab_index, section, index, row)
    end
  end

  def check_header(name, header)
    got = header[1, 4].map { |cell| cell.to_s.strip }
    return if got == COMMON_HEADER

    raise "tab #{name.inspect} has an unexpected header: #{header.inspect}\n       " \
          "expected columns 2-5 to be #{COMMON_HEADER.inspect}"
  end

  def build(tab, tab_index, section, index, row)
    name = row[0].to_s.strip
    raise "tab #{tab[:name].inspect} row #{index + 2} has a count but no name" if name.empty?

    { category:      tab[:name],
      gid:           tab[:gid],
      tab_index:     tab_index,
      section_index: section,
      row_index:     index,
      name:          name,
      norm:          normalize(name),
      count:         parse_count(row[1]),
      last_checked:  parse_date(row[2]),
      checked_by:    row[3].to_s.strip,
      notes:         row[4].to_s.strip }
  end

  # A blank count is recorded as NULL rather than 0: "nobody has written a
  # number here" and "we have none" are different, and only one is actionable.
  def parse_count(cell)
    text = cell.to_s.strip
    return nil if text.empty?

    Integer(text, exception: false)
  end

  def parse_date(cell)
    text = cell.to_s.strip
    return "" if text.empty?

    Date.parse(text).to_s
  rescue Date::Error
    text                      # kept verbatim; `verify` names it
  end
end

# --------------------------------------------------------------------------
# sync
# --------------------------------------------------------------------------
def synced_time
  raw = DB.ready? ? DB.meta("synced_at") : nil
  return nil if raw.nil? || raw.empty?

  Time.parse(raw)
rescue ArgumentError
  nil
end

def download_all(sheet_id)
  tabs = Fetch.tabs(sheet_id)
  rows = tabs.each_with_index.flat_map do |tab, index|
    Tab.rows(tab, index, Fetch.csv(sheet_id, tab[:gid]))
  end
  [tabs, rows]
end

def sync(force: false, quiet: false)
  DB.init

  synced_at = synced_time
  if synced_at && !force && (Time.now - synced_at) < STALE_SECONDS
    warn "Cache is current (synced #{synced_at.iso8601})." unless quiet
    return
  end

  url = Source.url
  tabs, rows = download_all(Source.sheet_id(url))
  die "the sheet parsed to no rows at all" if rows.empty?

  DB.replace_items(rows)
  # Only remember a URL that actually served the sheet, so a bad
  # BADGE_INVENTORY_URL cannot poison later runs.
  DB.set_meta("source_url", url)
  DB.set_meta("synced_at", Time.now.iso8601)
  DB.set_meta("tabs", tabs.map { |t| t[:name] }.join(" | "))
  DB.set_meta("item_count", rows.size)

  warn "Synced #{rows.size} items from #{tabs.size} tabs." unless quiet
rescue StandardError => e
  die e.message
end

def ensure_synced
  at = synced_time
  sync(quiet: true) if at.nil? || (Time.now - at) >= STALE_SECONDS
end

# --------------------------------------------------------------------------
# queries
# --------------------------------------------------------------------------
def all_items(category: nil, section: nil)
  where = []
  params = []
  if category
    where << "category = ? COLLATE NOCASE"
    params << category
  end
  if section
    where << "section_index = ?"
    params << section.to_i
  end
  clause = where.empty? ? "" : "WHERE #{where.join(' AND ')}"
  DB.query("SELECT * FROM items #{clause} ORDER BY tab_index, section_index, row_index", params)
end

# Exact normalized match first, then substring, then a de-pluralized retry so
# "Life adult pins" finds "Life Adult Pin".
def match(query)
  norm = normalize(query)
  return [] if norm.empty?

  rows = all_items
  exact = rows.select { |r| r["norm"] == norm }
  return exact unless exact.empty?

  subs = rows.select { |r| r["norm"].include?(norm) }
  return subs unless subs.empty?

  singular = norm.split.map { |w| w.sub(/s\z/, "") }.join(" ")
  rows.select { |r| r["norm"].split.map { |w| w.sub(/s\z/, "") }.join(" ").include?(singular) }
end

# Rows that mention the query but were not shown, so an exact hit on "First
# Class" still points at the two pin rows the question probably also meant.
def related(query, shown)
  norm = normalize(query)
  return [] if norm.empty?

  names = shown.map { |r| r["name"] }
  all_items.select { |r| r["norm"].include?(norm) && !names.include?(r["name"]) }
end

def days_since(date_str)
  return nil if date_str.to_s.empty?

  (Date.today - Date.parse(date_str)).to_i
rescue Date::Error
  nil
end

# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------
def count_text(row) = row["count"].nil? ? "—" : row["count"].to_s

def age_text(row)
  days = days_since(row["last_checked"])
  return "never checked" if row["last_checked"].to_s.empty?
  return "checked #{row['last_checked']}" if days.nil?

  "checked #{row['last_checked']}, #{days} day#{'s' unless days == 1} ago"
end

def print_items(rows, show_notes: true)
  if rows.empty?
    puts "Nothing matched."
    return
  end

  width = rows.map { |r| r["name"].length }.max
  category = nil
  rows.each do |row|
    if row["category"] != category
      puts "" if category
      puts "== #{row['category']} =="
      category = row["category"]
    end
    line = format("%-#{width}s  %4s   (%s)", row["name"], count_text(row), age_text(row))
    line += "  #{row['notes']}" if show_notes && !row["notes"].to_s.empty?
    puts line
  end
  puts "\n#{rows.size} item#{'s' unless rows.size == 1}."
end

def emit(rows, json:, **)
  json ? puts(JSON.pretty_generate(rows)) : print_items(rows, **)
end

# --------------------------------------------------------------------------
# verify
#
# The sheet has no tally row to check against, so `verify` leans on what the
# shape of a hand-kept inventory guarantees: every row named and counted, every
# date real and not in the future, no duplicates, and — for the one tab whose
# rows have an external authority — every badge reconciled against the
# requirements book through scout-req.
# --------------------------------------------------------------------------
module Book
  LIST_LINE = /\Amerit badge\s+p\.(\d+)\s+(.+?)\s*(?:\[pamphlet (\d+)\])?\z/
  # `req.rb list` ends with its own count — "(139 entries: 139 merit badge)".
  LIST_TOTAL = /\A\((\d+) entries:/

  module_function

  def badges
    out, err, status = Open3.capture3(RbConfig.ruby, REQ_SCRIPT, "list", "--kind", "badge")
    unless status.success?
      die "scout-req could not list the merit badges (#{err.strip.lines.first})"
    end

    names = out.lines.filter_map { |l| l.strip.match(LIST_LINE)&.[](2)&.strip }
    total = out.lines.filter_map { |l| l.strip.match(LIST_TOTAL)&.[](1)&.to_i }.first
    if total && total != names.size
      die "parsed #{names.size} badges from scout-req but it reported #{total}"
    end

    names
  end
end

def check_rows(rows, problems)
  rows.each do |row|
    where = "#{row['category']} / #{row['name']}"
    problems << "#{where}: count is blank" if row["count"].nil?
    problems << "#{where}: negative count #{row['count']}" if row["count"].to_i.negative?
    check_date(row, where, problems)
  end
end

def check_date(row, where, problems)
  raw = row["last_checked"].to_s
  return problems << "#{where}: no Last Checked date" if raw.empty?

  date = parse_or_nil(raw)
  return problems << "#{where}: unparseable Last Checked #{raw.inspect}" if date.nil?

  problems << "#{where}: Last Checked #{raw} is in the future" if date > Date.today
end

def parse_or_nil(raw)
  Date.parse(raw)
rescue Date::Error
  nil
end

def check_duplicates(rows, problems)
  rows.group_by { |r| [r["category"], normalize(r["name"])] }
      .select { |_, group| group.size > 1 }
      .each do |(cat, _), group|
    problems << "#{cat}: duplicate #{group.map do |r|
      r['name']
    end.inspect}"
  end
end

# The badge tab is the only one with an outside authority to check against.
def check_badges(rows, problems, notes)
  sheet = rows.select { |r| r["category"].to_s.match?(/merit\s*badge/i) }
  return problems << "no merit badge tab found" if sheet.empty?

  book = Book.badges
  book_norm = book.to_h { |n| [normalize(n), n] }
  sheet_norm = sheet.to_h { |r| [r["norm"], r["name"]] }

  (book_norm.keys - sheet_norm.keys).each do |key|
    problems << "merit badge #{book_norm[key].inspect} is in the book but not on the sheet"
  end
  extra = (sheet_norm.keys - book_norm.keys).map { |key| sheet_norm[key] }
  return if extra.empty?

  notes << "#{extra.size} badge(s) on the sheet are not in the 2025 printing: " \
           "#{extra.sort.join(', ')}. Confirm through scout-req before quoting requirements."
end

# Reported, never failed: the troop keeps Eagle items elsewhere.
def check_pin_coverage(rows, notes)
  pins = rows.select { |r| r["name"].match?(/\bpin\b/i) }
  return if pins.empty?

  ranks = ["Scout", "Tenderfoot", "Second Class", "First Class", "Star", "Life", "Eagle"]
  missing = ranks.product(%w[Youth Adult]).reject do |rank, kind|
    pins.any? { |r| r["norm"] == normalize("#{rank} #{kind} Pin") }
  end
  return if missing.empty?

  notes << "no pin row for: #{missing.map { |r, k| "#{r} #{k}" }.join(', ')}."
end

def run_verify
  ensure_synced
  rows = all_items
  die "the cache is empty; run `sync --force`" if rows.empty?

  problems = []
  notes = []
  check_rows(rows, problems)
  check_duplicates(rows, problems)
  check_badges(rows, problems, notes)
  check_pin_coverage(rows, notes)

  notes.each { |n| puts "note: #{n}" }
  puts "" unless notes.empty?
  $stdout.flush   # failures go to stderr; without this they overtake the notes

  if problems.empty?
    puts "OK: #{rows.size} items across #{rows.map { |r| r['category'] }.uniq.size} tabs."
    return
  end

  problems.each { |p| warn "FAIL: #{p}" }
  warn "\n#{problems.size} problem#{'s' unless problems.size == 1}."
  exit 1
end

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def flag(args, name, default = nil)
  idx = args.index(name)
  return default unless idx

  args.delete_at(idx)
  args.delete_at(idx) || default
end

def cmd_count(args)
  json = !args.delete("--json").nil?
  abort "usage: inventory.rb count NAME..." if args.empty?

  ensure_synced
  rows = match(args.join(" "))
  if rows.empty? && !json
    puts "Nothing on the inventory sheet matches #{args.join(' ').inspect}."
    return
  end
  emit(rows, json: json)
  return if json

  extra = related(args.join(" "), rows)
  puts "\nAlso on the sheet: #{extra.map { |r| r['name'] }.join(', ')}." unless extra.empty?
end

def cmd_list(args)
  json = !args.delete("--json").nil?
  category = flag(args, "--category")
  section = flag(args, "--section")

  ensure_synced
  emit(all_items(category: category, section: section), json: json)
end

def cmd_low(args)
  json = !args.delete("--json").nil?
  at = (flag(args, "--at") || 0).to_i

  ensure_synced
  rows = all_items.select { |r| !r["count"].nil? && r["count"] <= at }
  puts "Items at or below #{at}:" unless json || rows.empty?
  emit(rows, json: json)
end

def cmd_stale(args)
  json = !args.delete("--json").nil?
  days = (flag(args, "--days") || STALE_DAYS).to_i

  ensure_synced
  rows = all_items.select do |r|
    age = days_since(r["last_checked"])
    age.nil? || age >= days
  end
  puts "Not physically counted in #{days}+ days:" unless json || rows.empty?
  emit(rows, json: json, show_notes: false)
end

def cmd_info
  ensure_synced
  rows = all_items
  oldest = rows.map { |r| r["last_checked"] }.reject(&:empty?).min
  puts "sheet:    #{DB.meta('source_url')}"
  puts "synced:   #{DB.meta('synced_at')}   (this cache)"
  puts "items:    #{DB.meta('item_count')}"
  puts "tabs:     #{DB.meta('tabs')}"
  puts "oldest physical count: #{oldest} (#{days_since(oldest)} days ago)" if oldest
  puts ""
  rows.group_by { |r| r["category"] }.each do |category, group|
    sections = group.map { |r| r["section_index"] }.uniq.size
    total = group.sum { |r| r["count"].to_i }
    puts format("%-14s %3d rows, %2d block(s), %4d on hand", category, group.size, sections, total)
  end
end

def usage
  warn <<~USAGE
    usage: ruby scripts/inventory.rb <command>

      sync [--force]                 refresh the cached sheet
      count NAME...                  how many of an item we have
      list [--category NAME] [--section N]
      low [--at N]                   items at or below N (default 0)
      stale [--days N]               rows not physically counted lately (default #{STALE_DAYS})
      verify                         cross-check the parse — run this first
      info                           sheet URL, sync time, per-tab totals

    Query commands accept --json, and sync themselves when the cache is over
    six hours old. The sheet URL comes from TROOP-SETTINGS.md; override it
    with BADGE_INVENTORY_URL.
  USAGE
  exit 1
end

args = ARGV.dup
case args.shift
when "sync"   then sync(force: args.include?("--force"))
when "count"  then cmd_count(args)
when "list"   then cmd_list(args)
when "low"    then cmd_low(args)
when "stale"  then cmd_stale(args)
when "verify" then run_verify
when "info"   then cmd_info
else usage
end
