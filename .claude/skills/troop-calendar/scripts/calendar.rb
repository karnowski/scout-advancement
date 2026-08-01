#!/usr/bin/env ruby
# frozen_string_literal: true
#
# troop-calendar — read the troop's published iCal feed.
#
# Downloads the feed, expands recurring events into concrete occurrences, and
# caches them in SQLite under .cache/calendar.db.  Stdlib only; shells out to
# `curl` and the `sqlite3` CLI.
#
#   ruby scripts/calendar.rb sync [--force]
#   ruby scripts/calendar.rb events [--from DATE] [--to DATE] [--json]
#   ruby scripts/calendar.rb month YYYY-MM [YYYY-MM ...]
#   ruby scripts/calendar.rb next [--days N]
#   ruby scripts/calendar.rb search PATTERN [--from DATE] [--to DATE]
#   ruby scripts/calendar.rb info

require "date"
require "time"
require "json"
require "shellwords"

SKILL_DIR  = File.expand_path("..", __dir__)
CACHE_DIR  = File.join(SKILL_DIR, ".cache")
DB_PATH    = File.join(CACHE_DIR, "calendar.db")
ICS_PATH   = File.join(CACHE_DIR, "feed.ics")

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
# sqlite3 CLI wrapper
# --------------------------------------------------------------------------
module DB
  module_function

  def exec_sql(sql)
    IO.popen([ "sqlite3", DB_PATH ], "r+") do |io|
      io.write(sql)
      io.close_write
      io.read
    end
    abort "sqlite3 failed" unless $?.success?
  end

  def query(sql)
    out = IO.popen([ "sqlite3", "-json", DB_PATH, sql ], &:read)
    abort "sqlite3 query failed" unless $?.success?
    out.strip.empty? ? [] : JSON.parse(out)
  end

  def quote(str) = "'#{str.to_s.gsub("'", "''")}'"

  def ready? = File.exist?(DB_PATH)

  def init
    exec_sql(<<~SQL)
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      );
    SQL

    # The cache is disposable; on a schema change just rebuild it.
    if meta("schema_version") != SCHEMA_VERSION.to_s
      exec_sql("DROP TABLE IF EXISTS occurrences;")
      set_meta("synced_at", "")
    end

    exec_sql(<<~SQL)
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

  def meta(key)
    row = query("SELECT value FROM meta WHERE key = #{quote(key)};").first
    row && row["value"]
  end

  def set_meta(key, value)
    exec_sql("INSERT INTO meta (key, value) VALUES (#{quote(key)}, #{quote(value)}) " \
             "ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
  end
end

# --------------------------------------------------------------------------
# iCal parsing
# --------------------------------------------------------------------------
module ICS
  DAYS = { "SU" => 0, "MO" => 1, "TU" => 2, "WE" => 3,
           "TH" => 4, "FR" => 5, "SA" => 6 }.freeze

  module_function

  # RFC 5545: unfold continuation lines, then split into VEVENT property maps.
  def parse(raw)
    lines = raw.gsub(/\r\n[ \t]/, "").gsub(/\n[ \t]/, "").split(/\r?\n/)
    events = []
    cur = nil
    lines.each do |line|
      case line
      when "BEGIN:VEVENT" then cur = {}
      when "END:VEVENT"
        events << cur if cur
        cur = nil
      else
        next unless cur
        name, value = line.split(":", 2)
        next unless value
        key, *params = name.split(";")
        pmap = params.to_h { |x| k, v = x.split("=", 2); [ k.upcase, v ] }
        (cur[key.upcase] ||= []) << [ pmap, value ]
      end
    end
    events
  end

  def calendar_tz(raw)
    raw[/^X-WR-TIMEZONE:(.+)$/, 1]&.strip || DEFAULT_TZ
  end

  def unescape(str)
    str.to_s.gsub("\\n", "\n").gsub("\\N", "\n")
       .gsub("\\,", ",").gsub("\\;", ";").gsub("\\\\", "\\")
  end

  # => [Date (all-day) | Time (local), all_day?]
  def parse_dt(param, value)
    value = value.strip
    if param["VALUE"] == "DATE" || value.match?(/\A\d{8}\z/)
      [ Date.strptime(value, "%Y%m%d"), true ]
    elsif value.end_with?("Z")
      y, mo, d, h, mi, s = value.scan(/\A(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z\z/)
                                .first.map(&:to_i)
      [ Time.utc(y, mo, d, h, mi, s).getlocal, false ]
    else
      # Floating time, or TZID=<calendar tz>.  ENV["TZ"] is set to the feed's
      # own timezone before parsing, so a literal local parse is correct.
      [ Time.strptime(value, "%Y%m%dT%H%M%S"), false ]
    end
  end

  def to_date(val) = val.is_a?(Date) ? val : val.to_date

  # nth weekday of a month; n may be negative (-1 = last).  nil if out of month.
  def nth_wday(year, month, wday, num)
    if num.positive?
      first = Date.new(year, month, 1)
      date  = first + ((wday - first.wday) % 7) + (num - 1) * 7
    else
      last = Date.new(year, month, -1)
      date = last - ((last.wday - wday) % 7) + (num + 1) * 7
    end
    date.month == month ? date : nil
  end

  # Expand an RRULE to start Dates.  Time-of-day is carried from DTSTART.
  def expand(rule, start_date, window_end)
    parts = rule.split(";").to_h { |kv| k, v = kv.split("=", 2); [ k.upcase, v ] }
    interval = [ parts["INTERVAL"].to_i, 1 ].max
    count    = parts["COUNT"]&.to_i
    until_d  = parts["UNTIL"] ? Date.strptime(parts["UNTIL"][0, 8], "%Y%m%d") : nil
    bydays   = parts["BYDAY"]&.split(",") || []
    bymonths = parts["BYMONTH"]&.split(",")&.map(&:to_i)
    stop     = [ window_end, until_d ].compact.min

    out = []
    emitted = 0
    push = lambda do |date|
      return if date.nil? || date < start_date
      emitted += 1                       # COUNT counts every instance the rule
      out << date if date <= stop        # generates, including ones past `stop`
    end

    case parts["FREQ"]&.upcase
    when "DAILY"
      date = start_date
      while date <= stop && !(count && emitted >= count)
        push.call(date)
        date += interval
      end

    when "WEEKLY"
      wdays = bydays.empty? ? [ start_date.wday ] : bydays.filter_map { |b| DAYS[b[-2..]] }
      week  = start_date - start_date.wday          # Sunday of DTSTART's week
      while week <= stop && !(count && emitted >= count)
        wdays.sort.each do |wd|
          break if count && emitted >= count
          push.call(week + wd)
        end
        week += 7 * interval
      end

    when "MONTHLY"
      month = Date.new(start_date.year, start_date.month, 1)
      while month <= stop && !(count && emitted >= count)
        monthly_candidates(month, bydays, start_date).each do |date|
          break if count && emitted >= count
          push.call(date)
        end
        month = month >> interval
      end

    when "YEARLY"
      year = start_date.year
      while Date.new(year, 1, 1) <= stop && !(count && emitted >= count)
        (bymonths || [ start_date.month ]).each do |mo|
          monthly_candidates(Date.new(year, mo, 1), bydays, start_date).each do |date|
            break if count && emitted >= count
            push.call(date)
          end
        end
        year += interval
      end
    end

    out.uniq.sort
  end

  def monthly_candidates(month, bydays, start_date)
    if bydays.empty?
      [ safe_date(month.year, month.month, start_date.day) ]
    else
      bydays.map do |byday|
        num = byday[0..-3].to_i
        nth_wday(month.year, month.month, DAYS[byday[-2..]], num.zero? ? 1 : num)
      end
    end.compact.sort
  end

  def safe_date(year, month, day)
    Date.valid_date?(year, month, day) ? Date.new(year, month, day) : nil
  end

  def cancelled?(event) = event["STATUS"]&.first&.last == "CANCELLED"

  # Flatten every VEVENT into concrete occurrences within the window.
  def occurrences(events, window_end)
    masters, overrides = events.partition { |e| e["RECURRENCE-ID"].nil? }

    # A RECURRENCE-ID event replaces (or cancels) one instance of its master.
    overridden = {}
    overrides.each do |event|
      uid = event["UID"]&.first&.last or next
      rid, = parse_dt(*event["RECURRENCE-ID"].first)
      overridden[[ uid, to_date(rid) ]] = true
    end

    out = []

    masters.each do |event|
      next unless event["DTSTART"]
      uid = event["UID"]&.first&.last or next
      start_val, = parse_dt(*event["DTSTART"].first)
      start_date = to_date(start_val)

      exdates = (event["EXDATE"] || []).flat_map do |param, value|
        value.split(",").map { |v| to_date(parse_dt(param, v).first) }
      end

      dates =
        if event["RRULE"]
          expand(event["RRULE"].first.last, start_date, window_end)
        else
          [ start_date ]
        end

      dates.each do |date|
        next if exdates.include?(date)
        next if overridden[[ uid, date ]]     # emitted from the override below
        next if cancelled?(event)
        out << build(event, date)
      end
    end

    overrides.each do |event|
      next if cancelled?(event)
      next unless event["DTSTART"]
      out << build(event, to_date(parse_dt(*event["DTSTART"].first).first))
    end

    out
  end

  # One occurrence row, with the master's time-of-day and duration applied to
  # the given start date.
  def build(event, date)
    start_val, all_day = parse_dt(*event["DTSTART"].first)
    end_raw   = event["DTEND"]&.first
    end_val, = end_raw ? parse_dt(*end_raw) : [ nil, nil ]

    span = end_val ? (to_date(end_val) - to_date(start_val)).to_i : 0
    span -= 1 if all_day && span.positive?   # DTEND is exclusive for all-day
    span = 0 if span.negative?

    {
      uid:         event["UID"].first.last,
      start_date:  date.to_s,
      start_time:  all_day ? "" : start_val.strftime("%H:%M"),
      end_date:    (date + span).to_s,
      end_time:    (end_val && !all_day) ? end_val.strftime("%H:%M") : "",
      all_day:     all_day ? 1 : 0,
      summary:     unescape(event["SUMMARY"]&.first&.last).strip,
      location:    unescape(event["LOCATION"]&.first&.last).strip,
      description: unescape(event["DESCRIPTION"]&.first&.last).strip,
    }
  end
end

# --------------------------------------------------------------------------
# sync
# --------------------------------------------------------------------------
def feed_url
  ENV["TROOP_CALENDAR_URL"] || (DB.ready? ? DB.meta("feed_url") : nil) || DEFAULT_FEED_URL
end

def download(url)
  raw = IO.popen([ "curl", "-sS", "-L", "--max-time", "60", url ], &:read)
  raise "download failed (curl exit #{$?.exitstatus})" unless $?.success?
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
  Dir.mkdir(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
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
  rescue StandardError => e
    # Offline or the feed is down: re-expand whatever we last downloaded.
    raise "#{e.message}, and no cached feed to fall back on" unless File.exist?(ICS_PATH)
    warn "WARNING: #{e.message}. Re-using the feed downloaded #{synced_at&.iso8601 || 'earlier'}."
    raw = File.read(ICS_PATH, encoding: "UTF-8")
  end

  tz = ICS.calendar_tz(raw)
  ENV["TZ"] = tz

  today = Date.today
  window_end = Date.new(today.year + FWD_YEARS, today.month, 1)
  window_start = Date.new(today.year - BACK_YEARS, today.month, 1)

  events = ICS.parse(raw)
  rows = ICS.occurrences(events, window_end)
           .select { |o| Date.parse(o[:end_date]) >= window_start }
           .uniq { |o| [ o[:uid], o[:start_date], o[:start_time] ] }

  values = rows.map do |o|
    "(#{DB.quote(o[:uid])},#{DB.quote(o[:start_date])},#{DB.quote(o[:start_time])}," \
      "#{DB.quote(o[:end_date])},#{DB.quote(o[:end_time])}," \
      "#{o[:all_day]},#{DB.quote(o[:summary])}," \
      "#{DB.quote(o[:location])},#{DB.quote(o[:description])})"
  end

  sql = +"BEGIN;\nDELETE FROM occurrences;\n"
  values.each_slice(400) do |slice|
    sql << "INSERT OR REPLACE INTO occurrences (uid,start_date,start_time,end_date," \
           "end_time,all_day,summary,location,description) VALUES\n"
    sql << slice.join(",\n") << ";\n"
  end
  sql << "COMMIT;\n"
  DB.exec_sql(sql)

  DB.set_meta("feed_url", url)
  DB.set_meta("timezone", tz)
  DB.set_meta("synced_at", Time.now.iso8601)
  DB.set_meta("window_start", window_start.to_s)
  DB.set_meta("window_end", window_end.to_s)
  DB.set_meta("event_count", rows.size.to_s)

  warn "Synced #{rows.size} occurrences (#{window_start}..#{window_end}), timezone #{tz}." unless quiet
end

def ensure_synced
  at = synced_time
  ENV["TZ"] = (DB.ready? && DB.meta("timezone")) || DEFAULT_TZ
  sync(quiet: true) if at.nil? || (Time.now - at) >= STALE_SECONDS
  ENV["TZ"] = (DB.meta("timezone") || DEFAULT_TZ)
end

# --------------------------------------------------------------------------
# queries + output
# --------------------------------------------------------------------------
def fetch(from:, to:, pattern: nil)
  where = [ "end_date >= #{DB.quote(from)}", "start_date <= #{DB.quote(to)}" ]
  where << "summary LIKE #{DB.quote("%#{pattern}%")} COLLATE NOCASE" if pattern
  DB.query(<<~SQL)
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
    multi ? "#{start_d.strftime('%a %b %-d')} – #{end_d.strftime('%a %b %-d')} (all day)"
          : "#{start_d.strftime('%a %b %-d')} (all day)"
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
  abort "usage: calendar.rb search PATTERN [--from DATE] [--to DATE]" if command == "search" && pattern.nil?

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
