#!/usr/bin/env ruby
# frozen_string_literal: true

#
# troop-calendar — read the troop's published iCal feed.
#
# Downloads the feed, expands recurring events into concrete occurrences, and
# caches them in SQLite under .cache/calendar.db.
#
#   ruby scripts/calendar.rb sync [--force]
#   ruby scripts/calendar.rb events [--from DATE] [--to DATE] [--json]
#   ruby scripts/calendar.rb month YYYY-MM [YYYY-MM ...]
#   ruby scripts/calendar.rb next [--days N]
#   ruby scripts/calendar.rb search PATTERN [--from DATE] [--to DATE]
#   ruby scripts/calendar.rb info

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "fileutils"
require "json"
require "net/http"
require "time"

require "icalendar"
require "rrule"
require "sqlite3"
require "tzinfo"

CACHE_DIR = File.join(SKILL_DIR, ".cache")
DB_PATH   = File.join(CACHE_DIR, "calendar.db")
ICS_PATH  = File.join(CACHE_DIR, "feed.ics")

# Official Troop 400 calendar (public iCal feed; see README.md).
DEFAULT_FEED_URL =
  "https://calendar.google.com/calendar/ical/" \
  "troop400durham.org_cc4de26nmjft4ger2t11mon03o%40group.calendar.google.com/public/basic.ics"

SCHEMA_VERSION = 1
DEFAULT_TZ    = "America/New_York"
STALE_SECONDS = 6 * 3600          # re-download if the cache is older than this
BACK_YEARS    = 2                 # expansion window around today
FWD_YEARS     = 3

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
      handle.execute("DROP TABLE IF EXISTS occurrences")
      set_meta("synced_at", "")
    end

    handle.execute_batch(<<~SQL)
      CREATE TABLE IF NOT EXISTS occurrences (
        uid         TEXT NOT NULL,
        start_date  TEXT NOT NULL,             -- YYYY-MM-DD, calendar-local
        start_time  TEXT NOT NULL DEFAULT '',  -- HH:MM; '' for all-day
        end_date    TEXT NOT NULL DEFAULT '',
        end_time    TEXT NOT NULL DEFAULT '',
        all_day     INTEGER NOT NULL DEFAULT 0,
        summary     TEXT NOT NULL DEFAULT '',
        location    TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (uid, start_date, start_time)
      ) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS idx_occ_start ON occurrences (start_date);
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

  COLUMNS = %i[uid start_date start_time end_date end_time
               all_day summary location description].freeze

  def replace_occurrences(rows)
    handle.transaction do
      handle.execute("DELETE FROM occurrences")
      stmt = handle.prepare(
        "INSERT OR REPLACE INTO occurrences (#{COLUMNS.join(',')}) " \
        "VALUES (#{(['?'] * COLUMNS.size).join(',')})"
      )
      rows.each { |row| stmt.execute(row.values_at(*COLUMNS)) }
      stmt.close
    end
  end
end

# --------------------------------------------------------------------------
# iCal -> occurrences
#
# The icalendar gem handles unfolding, escaping, and TZID/UTC stamps; the rrule
# gem handles RRULE expansion.  What is left here is the feed's own shape: a
# RECURRENCE-ID event replaces one instance of its master, and DTEND means
# something different for all-day events than for timed ones.
# --------------------------------------------------------------------------
module ICS
  module_function

  def all_day?(value) = value.is_a?(Icalendar::Values::Date)

  # Every stored date and time is calendar-local wall clock, so UTC stamps in the
  # feed have to be converted; the machine's own timezone never enters into it.
  def local_date(zone, value)
    all_day?(value) ? value.to_date : zone.to_local(value.to_time).to_date
  end

  def local_hhmm(zone, value)
    all_day?(value) ? "" : zone.to_local(value.to_time).strftime("%H:%M")
  end

  def cancelled?(event) = event.status.to_s == "CANCELLED"

  # Start dates for one master event, within the window.
  def start_dates(zone, event, window_end)
    first = local_date(zone, event.dtstart)
    return [first] if event.rrule.empty?

    # Noon rather than midnight: a date can never be pushed across a DST shift.
    dtstart = if all_day?(event.dtstart)
                zone.local_time(first.year, first.month, first.day, 12)
              else
                event.dtstart.to_time
              end
    stop = zone.local_time(window_end.year, window_end.month, window_end.day)

    # Hand the rule to the gem as its raw ICAL string. That is what keeps UNTIL
    # correct: `UNTIL=...Z` is a UTC *instant*, not a date. Several series in this
    # feed end at T045959Z, which is 23:59:59 the previous day in Eastern time, so
    # normalizing UNTIL to its date part first yields one occurrence too many per
    # series -- a phantom final meeting, on a date the troop is not meeting.
    times = event.rrule.flat_map do |rule|
      RRule::Rule.new(rule.value_ical, dtstart: dtstart, tzid: zone.identifier)
                 .between(dtstart, stop)
    end
    times.map { |time| zone.to_local(time).to_date }
  end

  # Flatten every VEVENT into concrete occurrences within the window.
  def occurrences(calendar, zone, window_end)
    masters, overrides = calendar.events.partition { |e| e.recurrence_id.nil? }

    # A RECURRENCE-ID event replaces (or cancels) one instance of its master.
    overridden = overrides.to_set { |e| [e.uid.to_s, local_date(zone, e.recurrence_id)] }

    rows = []

    masters.each do |event|
      next unless event.dtstart
      next if cancelled?(event)

      uid = event.uid.to_s
      exdates = event.exdate.flatten.to_set { |v| local_date(zone, v) }

      start_dates(zone, event, window_end).each do |date|
        next if exdates.include?(date)
        next if overridden.include?([uid, date])   # emitted from the override below

        rows << build(zone, event, date)
      end
    end

    overrides.each do |event|
      next if cancelled?(event)
      next unless event.dtstart

      rows << build(zone, event, local_date(zone, event.dtstart))
    end

    rows
  end

  # One occurrence row, with the event's time-of-day and duration applied to the
  # given start date.
  def build(zone, event, date)
    all_day = all_day?(event.dtstart)
    span = event.dtend ? (local_date(zone, event.dtend) - local_date(zone, event.dtstart)).to_i : 0
    span -= 1 if all_day && span.positive?   # DTEND is exclusive for all-day
    span = 0 if span.negative?

    {
      uid:         event.uid.to_s,
      start_date:  date.to_s,
      start_time:  local_hhmm(zone, event.dtstart),
      end_date:    (date + span).to_s,
      end_time:    event.dtend ? local_hhmm(zone, event.dtend) : "",
      all_day:     all_day ? 1 : 0,
      summary:     event.summary.to_s.strip,
      location:    event.location.to_s.strip,
      description: event.description.to_s.strip
    }
  end
end

# --------------------------------------------------------------------------
# sync
# --------------------------------------------------------------------------
def feed_url
  ENV["TROOP_CALENDAR_URL"] || (DB.ready? ? DB.meta("feed_url") : nil) || DEFAULT_FEED_URL
end

def download(url, redirects: 5)
  raise "too many redirects fetching the feed" if redirects.negative?

  response = Net::HTTP.get_response(URI.parse(url))
  case response
  when Net::HTTPRedirection then return download(response["location"], redirects: redirects - 1)
  when Net::HTTPSuccess then nil
  else raise "download failed (HTTP #{response.code})"
  end

  raw = response.body.to_s.force_encoding("UTF-8")
  raise "response is not an iCalendar feed" unless raw.include?("BEGIN:VCALENDAR")

  raw
end

def synced_time
  raw = DB.ready? ? DB.meta("synced_at") : nil
  return nil if raw.nil? || raw.empty?

  Time.parse(raw)
rescue ArgumentError
  nil
end

def sync(force: false, quiet: false)
  DB.init

  synced_at = synced_time
  if synced_at && !force && (Time.now - synced_at) < STALE_SECONDS && File.exist?(ICS_PATH)
    warn "Cache is current (synced #{synced_at.iso8601})." unless quiet
    return
  end

  url = feed_url
  begin
    raw = download(url)
    File.write(ICS_PATH, raw)
    # Only remember a URL that actually served a feed, so a bad
    # TROOP_CALENDAR_URL cannot poison later runs.
    DB.set_meta("feed_url", url)
  rescue StandardError => e
    # Offline or the feed is down: re-expand whatever we last downloaded.
    raise "#{e.message}, and no cached feed to fall back on" unless File.exist?(ICS_PATH)

    warn "WARNING: #{e.message}. Re-using the feed downloaded #{synced_at&.iso8601 || 'earlier'}."
    raw = File.read(ICS_PATH, encoding: "UTF-8")
  end

  calendar = Icalendar::Calendar.parse(raw).first or raise "no VCALENDAR in the feed"
  zone = TZInfo::Timezone.get(calendar.x_wr_timezone.first || DEFAULT_TZ)

  today = Date.today
  window_end   = Date.new(today.year + FWD_YEARS, today.month, 1)
  window_start = Date.new(today.year - BACK_YEARS, today.month, 1)

  rows = ICS.occurrences(calendar, zone, window_end)
            .select { |o| Date.parse(o[:end_date]) >= window_start }
            .uniq { |o| [o[:uid], o[:start_date], o[:start_time]] }
  DB.replace_occurrences(rows)

  DB.set_meta("timezone", zone.identifier)
  DB.set_meta("synced_at", Time.now.iso8601)
  DB.set_meta("window_start", window_start)
  DB.set_meta("window_end", window_end)
  DB.set_meta("event_count", rows.size)

  return if quiet

  warn "Synced #{rows.size} occurrences (#{window_start}..#{window_end}), " \
       "timezone #{zone.identifier}."
end

def ensure_synced
  at = synced_time
  sync(quiet: true) if at.nil? || (Time.now - at) >= STALE_SECONDS
end

# --------------------------------------------------------------------------
# queries + output
# --------------------------------------------------------------------------
def fetch(from:, to:, pattern: nil)
  where = ["end_date >= ?", "start_date <= ?"]
  params = [from, to]
  if pattern
    where << "summary LIKE ? COLLATE NOCASE"
    params << "%#{pattern}%"
  end

  DB.query(<<~SQL, params)
    SELECT start_date, start_time, end_date, end_time, all_day, summary, location, description
    FROM occurrences
    WHERE #{where.join(' AND ')}
    ORDER BY start_date, COALESCE(start_time, '00:00'), summary;
  SQL
end

def pretty_time(hhmm)
  Time.strptime(hhmm, "%H:%M").strftime("%-l:%M %p")
end

def format_when(row)
  start_d = Date.parse(row["start_date"])
  end_d   = Date.parse(row["end_date"])
  multi   = end_d > start_d

  has_end = !row["end_time"].to_s.empty?

  if row["all_day"] == 1
    if multi
      "#{start_d.strftime('%a %b %-d')} – #{end_d.strftime('%a %b %-d')} (all day)"
    else
      "#{start_d.strftime('%a %b %-d')} (all day)"
    end
  elsif multi
    tail = has_end ? " #{pretty_time(row['end_time'])}" : ""
    "#{start_d.strftime('%a %b %-d')} #{pretty_time(row['start_time'])} – " \
      "#{end_d.strftime('%a %b %-d')}#{tail}"
  else
    tail = has_end ? "–#{pretty_time(row['end_time'])}" : ""
    "#{start_d.strftime('%a %b %-d')} #{pretty_time(row['start_time'])}#{tail}"
  end
end

def print_rows(rows)
  if rows.empty?
    puts "No events in range."
    return
  end
  month = nil
  rows.each do |row|
    label = Date.parse(row["start_date"]).strftime("%B %Y")
    if label != month
      puts "" if month
      puts "== #{label} =="
      month = label
    end
    line = "#{format_when(row)} | #{row['summary']}"
    line += "  @ #{row['location']}" unless row["location"].to_s.empty?
    puts line
  end
  puts "\n#{rows.size} event#{'s' unless rows.size == 1}."
end

def parse_date(str, what)
  Date.parse(str)
rescue ArgumentError
  abort "Could not parse #{what}: #{str.inspect} (use YYYY-MM-DD)"
end

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
args = ARGV.dup
command = args.shift

def flag(args, name, default = nil)
  idx = args.index(name)
  return default unless idx

  args.delete_at(idx)
  args.delete_at(idx) || default
end

case command
when "sync"
  sync(force: args.include?("--force"))

when "info"
  ensure_synced
  puts "feed:      #{DB.meta('feed_url')}"
  puts "timezone:  #{DB.meta('timezone')}"
  puts "synced:    #{DB.meta('synced_at')}"
  puts "window:    #{DB.meta('window_start')} .. #{DB.meta('window_end')}"
  puts "occurrences: #{DB.meta('event_count')}"

when "events", "search"
  ensure_synced
  json    = !args.delete("--json").nil?
  from    = flag(args, "--from")
  to      = flag(args, "--to")
  pattern = command == "search" ? args.shift : nil
  if command == "search" && pattern.nil?
    abort "usage: calendar.rb search PATTERN [--from DATE] [--to DATE]"
  end

  from_d = from ? parse_date(from, "--from") : Date.today
  to_d   = to   ? parse_date(to, "--to")     : from_d + 90
  rows = fetch(from: from_d.to_s, to: to_d.to_s, pattern: pattern)
  json ? puts(JSON.pretty_generate(rows)) : print_rows(rows)

when "month"
  ensure_synced
  json = !args.delete("--json").nil?
  abort "usage: calendar.rb month YYYY-MM [YYYY-MM ...]" if args.empty?
  months = args.map do |m|
    abort "Bad month #{m.inspect} (use YYYY-MM)" unless m.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)
    Date.strptime(m, "%Y-%m")
  end
  from_d = months.min
  to_d   = Date.new(months.max.year, months.max.month, -1)
  rows = fetch(from: from_d.to_s, to: to_d.to_s)
  json ? puts(JSON.pretty_generate(rows)) : print_rows(rows)

when "next"
  ensure_synced
  json = !args.delete("--json").nil?
  days = (flag(args, "--days") || 30).to_i
  rows = fetch(from: Date.today.to_s, to: (Date.today + days).to_s)
  json ? puts(JSON.pretty_generate(rows)) : print_rows(rows)

else
  warn <<~USAGE
    usage: ruby scripts/calendar.rb <command>

      sync [--force]                        refresh the cached feed
      events [--from DATE] [--to DATE]      events in a date range (default: next 90 days)
      month YYYY-MM [YYYY-MM ...]           whole calendar months
      next [--days N]                       upcoming events (default: 30 days)
      search PATTERN [--from] [--to]        title substring match, case-insensitive
      info                                  feed URL, timezone, sync time, cache window

    All commands accept --json.  Dates are YYYY-MM-DD.
    Override the feed with TROOP_CALENDAR_URL.
  USAGE
  exit 1
end
