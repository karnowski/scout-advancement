#!/usr/bin/env ruby
# frozen_string_literal: true

#
# mbc — read a TroopMaster "MBC Grouped By Badge" report and answer who in the
# troop counsels a given merit badge.
#
# The report is a flat, alphabetical list: a badge name flush left, then its
# counselors indented under it. `pdftotext -layout` reproduces that faithfully,
# so unlike the Target grids this parse is straightforward — the care goes into
# the two things the report cannot tell you on its own:
#
#   - TroopMaster's badge names are not the requirements book's names, so the
#     printed names are folded to the same normalized key `scout-req` uses.
#   - The report only lists badges that *have* a counselor. Answering "do we
#     have someone for X" needs the book's full badge list to tell "nobody
#     counsels it" apart from "that is not a merit badge", so the badge index
#     is read from `scout-req` at load time and cached alongside.
#
# Parsed rows go into SQLite at .cache/mbc.db.
#
#   ruby scripts/mbc.rb load      [REPORT.pdf] [--force]
#   ruby scripts/mbc.rb verify    [REPORT.pdf]
#   ruby scripts/mbc.rb who       BADGE [BADGE...]
#   ruby scripts/mbc.rb counselor NAME
#   ruby scripts/mbc.rb badges    [--eagle]
#   ruby scripts/mbc.rb gaps      [--eagle]
#   ruby scripts/mbc.rb roster
#   ruby scripts/mbc.rb info
#   ruby scripts/mbc.rb json
#
# This script never reports requirement text, so it never exits 3 the way
# `req.rb` does — every answer here comes from TroopMaster, not from the book.
# A badge the 2025 printing does not carry (Cybersecurity, as of this writing)
# still has a perfectly good answer to "who counsels it", and gets a note.
#
# Needs `pdftotext` (poppler): brew install poppler

SKILL_DIR = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("../../..", SKILL_DIR)
ENV["BUNDLE_GEMFILE"] ||= File.join(REPO_ROOT, "Gemfile")

require "bundler/setup"

require "date"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "sqlite3"

CACHE_DIR   = File.join(SKILL_DIR, ".cache")
DB_PATH     = File.join(CACHE_DIR, "mbc.db")
REPORTS_DIR = File.join(REPO_ROOT, "reports")
REQ_SCRIPT  = File.join(REPO_ROOT, ".claude", "skills", "scout-req", "scripts", "req.rb")

SCHEMA_VERSION = 1

# A report file dropped in reports/ is found by this, newest first.
REPORT_GLOB = "*MBC*"

# --------------------------------------------------------------------------
# Report shape. See SKILL.md, "Facts about the report the script depends on".
# --------------------------------------------------------------------------

# The title band repeats at the top of every page; the troop's name varies, so
# anchor on the part that does not.
TITLE_LINE = /MBC Grouped By Badge/i
# Page number, top right of pages 2..n, preceded by the form feed.
PAGE_LINE = /\A\s*Page \d+\s*\z/
# The run date, top left of page 1, and the only date on the report.
DATE_LINE = %r{\A\s*(\d{1,2})/(\d{1,2})/(\d{4})\s*\z}
# "Sublett, Scott          (C) (919) 389-6635" — the parenthesized letter is a
# phone type. Only (C) and (H) appear in the reports seen so far; the others are
# accepted so an unseen one does not silently become a badge heading.
COUNSELOR_LINE = /\A\s+(\S.*?)\s{2,}\(([CHWB])\)\s*(.*?)\s*\z/
# Fallback for a counselor carrying no phone at all: still indented, still
# "Last, First". `verify` names anything caught here.
NAMELIKE_LINE = /\A\s+([A-Z][^()]*,\s*\S.*?)\s*\z/
PHONE_TYPES = { "C" => "cell", "H" => "home", "W" => "work", "B" => "business" }.freeze

# TroopMaster stars the Eagle-required badges it prints.
EAGLE_STAR = /\*\z/

# The 14 Eagle-required slots, from Eagle rank requirement 3. These are **match
# keys, not requirement text** — they exist so `gaps --eagle` can tell a covered
# slot from an uncovered one, including for a badge that is absent from the
# report entirely and therefore carries no star. Requirement text comes from
# `scout-req`. Each inner list is one slot; any one of its badges fills it.
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

# Fold the spelling differences between TroopMaster, the requirements book, and
# whatever the user typed. **This must stay identical to `normalize` in
# `req.rb`** — "and" and "the" go because the book's own Merit Badge Library
# abbreviates that way. `verify` resolves every printed badge name through this
# against the book's list, so a drift between the two copies shows up as a pile
# of unresolved badges rather than as silence.
IGNORED_WORDS = %w[and the].freeze

def normalize(str)
  str.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9]+/, " ")
     .split.reject { |word| IGNORED_WORDS.include?(word) }.join(" ")
end

# --------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------
module Report
  module_function

  def extract(path)
    die "no such report: #{path}" unless File.file?(path)
    out, err, status = Open3.capture3("pdftotext", "-layout", path, "-")
    die "pdftotext failed on #{path}: #{err.strip}" unless status.success?
    out
  end

  # => { date:, badges: [{ name:, eagle_required:, position:, counselors: [...] }],
  #      anomalies: [...], phone_line_count: }
  def parse(path)
    text = extract(path)
    state = { date: nil, badges: [], anomalies: [] }

    text.lines.each_with_index do |raw, index|
      line = raw.delete("\f").rstrip
      next if line.strip.empty? || line =~ PAGE_LINE || line =~ TITLE_LINE

      classify(state, line, index + 1)
    end

    state[:phone_line_count] = text.lines.count { |l| l =~ /\([CHWB]\)/ && l !~ TITLE_LINE }
    state[:path] = path
    state
  end

  def classify(state, line, lineno)
    if (m = line.match(DATE_LINE))
      state[:date] ||= Date.new(m[3].to_i, m[1].to_i, m[2].to_i)
    elsif (m = line.match(COUNSELOR_LINE))
      add_counselor(state, m[1].strip, m[2], m[3].strip, lineno)
    elsif line.start_with?(" ")
      indented_without_phone(state, line, lineno)
    else
      add_badge(state, line, lineno)
    end
  end

  def add_badge(state, line, lineno)
    name = line.strip
    state[:badges] << {
      name:           name.sub(EAGLE_STAR, "").strip,
      eagle_required: name.match?(EAGLE_STAR),
      position:       state[:badges].size,
      lineno:         lineno,
      counselors:     []
    }
  end

  def add_counselor(state, name, type, phone, lineno)
    badge = state[:badges].last
    return state[:anomalies] << "line #{lineno}: counselor #{name.inspect} before any badge" if
      badge.nil?

    badge[:counselors] << { name: name, phone: phone.empty? ? nil : phone, phone_type: type }
  end

  # An indented line with no phone code. Kept rather than dropped: a counselor
  # with no phone on file still counsels the badge.
  def indented_without_phone(state, line, lineno)
    if (m = line.match(NAMELIKE_LINE))
      state[:anomalies] << "line #{lineno}: #{m[1].strip.inspect} has no phone number"
      add_counselor(state, m[1].strip, nil, "", lineno)
    else
      state[:anomalies] << "line #{lineno}: unrecognized indented line #{line.strip.inspect}"
    end
  end
end

# --------------------------------------------------------------------------
# the requirements book's badge list, via scout-req
#
# Nothing here opens the requirements PDF. `scout-req` is the only reader of it
# (see CLAUDE.md), and it is also the only thing that knows the 2025 printing's
# limits, so the badge index is taken from its `list` output.
# --------------------------------------------------------------------------
module Book
  LIST_LINE = /\Amerit badge\s+p\.(\d+)\s+(.+?)\s*(?:\[pamphlet (\d+)\])?\z/
  # `req.rb list` ends with its own count — "(139 entries: 139 merit badge)".
  # Checking against it is what keeps a changed output format from quietly
  # dropping badges here and inflating the `gaps` list.
  LIST_TOTAL = /\A\((\d+) entries:/

  module_function

  def badges
    out, err, status = Open3.capture3(RbConfig.ruby, REQ_SCRIPT, "list", "--kind", "badge")
    unless status.success?
      die "scout-req could not list the merit badges (#{err.strip.split("\n").first}).\n" \
          "#{' ' * 7}Try: ruby #{REQ_SCRIPT} build"
    end

    rows = out.lines.filter_map do |line|
      next unless (m = line.strip.match(LIST_LINE))

      { name: m[2].strip, page: m[1].to_i, norm: normalize(m[2].strip) }
    end
    die "scout-req listed no merit badges; its cache may be empty" if rows.empty?
    check_total!(out, rows)
    rows
  end

  def check_total!(out, rows)
    stated = out.lines.filter_map { |l| l.strip.match(LIST_TOTAL) }.last
    return if stated.nil? || stated[1].to_i == rows.size

    die "read #{rows.size} merit badges from scout-req but it reported #{stated[1]}; " \
        "its list format has changed and mbc.rb's LIST_LINE needs updating"
  end
end

# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------
module Store
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

  def setup
    handle.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    reset if meta("schema_version") != SCHEMA_VERSION.to_s
    handle.execute_batch(<<~SQL)
      CREATE TABLE IF NOT EXISTS counselors (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE,
        phone TEXT, phone_type TEXT
      );
      CREATE TABLE IF NOT EXISTS badges (
        id INTEGER PRIMARY KEY, printed_name TEXT NOT NULL UNIQUE, norm TEXT NOT NULL,
        book_name TEXT, page INTEGER, eagle_required INTEGER NOT NULL DEFAULT 0,
        position INTEGER
      );
      CREATE TABLE IF NOT EXISTS counselor_badges (
        counselor_id INTEGER NOT NULL, badge_id INTEGER NOT NULL,
        PRIMARY KEY (counselor_id, badge_id)
      );
      CREATE TABLE IF NOT EXISTS book_badges (
        norm TEXT PRIMARY KEY, name TEXT NOT NULL, page INTEGER
      );
      CREATE INDEX IF NOT EXISTS badges_norm ON badges (norm);
    SQL
    set_meta("schema_version", SCHEMA_VERSION)
  end

  def reset
    handle.execute_batch(<<~SQL)
      DROP TABLE IF EXISTS counselor_badges;
      DROP TABLE IF EXISTS counselors;
      DROP TABLE IF EXISTS badges;
      DROP TABLE IF EXISTS book_badges;
    SQL
  end

  def meta(key)
    handle.execute("SELECT value FROM meta WHERE key = ?", [key]).dig(0, "value")
  rescue SQLite3::SQLException
    nil
  end

  def set_meta(key, value)
    handle.execute("INSERT INTO meta (key, value) VALUES (?, ?) " \
                   "ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value.to_s])
  end

  def loaded? = !meta("report_path").nil?

  def replace(parsed, book)
    setup
    handle.transaction do
      handle.execute_batch("DELETE FROM counselor_badges; DELETE FROM counselors; " \
                           "DELETE FROM badges; DELETE FROM book_badges;")
      insert_book(book)
      index = book.to_h { |b| [b[:norm], b] }
      parsed[:badges].each { |badge| insert_badge(badge, index) }
      record_source(parsed)
    end
  end

  def insert_book(book)
    stmt = handle.prepare("INSERT INTO book_badges (norm, name, page) VALUES (?, ?, ?)")
    book.each { |b| stmt.execute([b[:norm], b[:name], b[:page]]) }
    stmt.close
  end

  def insert_badge(badge, index)
    entry = index[normalize(badge[:name])]
    handle.execute(
      "INSERT INTO badges (printed_name, norm, book_name, page, eagle_required, position) " \
      "VALUES (?, ?, ?, ?, ?, ?)",
      [badge[:name], normalize(badge[:name]), entry&.fetch(:name), entry&.fetch(:page),
       badge[:eagle_required] ? 1 : 0, badge[:position]]
    )
    badge_id = handle.last_insert_row_id
    badge[:counselors].each { |c| link(c, badge_id) }
  end

  def link(counselor, badge_id)
    handle.execute("INSERT INTO counselors (name, phone, phone_type) VALUES (?, ?, ?) " \
                   "ON CONFLICT(name) DO UPDATE SET " \
                   "phone = COALESCE(counselors.phone, excluded.phone), " \
                   "phone_type = COALESCE(counselors.phone_type, excluded.phone_type)",
                   [counselor[:name], counselor[:phone], counselor[:phone_type]])
    handle.execute("INSERT OR IGNORE INTO counselor_badges (counselor_id, badge_id) " \
                   "SELECT id, ? FROM counselors WHERE name = ?", [badge_id, counselor[:name]])
  end

  def record_source(parsed)
    set_meta("report_path", parsed[:path])
    set_meta("report_date", parsed[:date]&.iso8601)
    set_meta("report_mtime", File.mtime(parsed[:path]).to_i)
    set_meta("loaded_at", Time.now.utc.iso8601)
  end
end

# --------------------------------------------------------------------------
# queries
# --------------------------------------------------------------------------
module Query
  module_function

  # One row per badge the troop covers, with its counselors rolled up.
  def badge(name)
    rows = Store.query(<<~SQL, [normalize(name)])
      SELECT b.printed_name, b.book_name, b.page, b.eagle_required,
             c.name AS counselor, c.phone, c.phone_type
        FROM badges b
        LEFT JOIN counselor_badges cb ON cb.badge_id = b.id
        LEFT JOIN counselors c ON c.id = cb.counselor_id
       WHERE b.norm = ?
       ORDER BY c.name
    SQL
    return nil if rows.empty?

    first = rows.first
    { printed_name: first["printed_name"], book_name: first["book_name"], page: first["page"],
      eagle_required: first["eagle_required"] == 1,
      counselors: rows.filter_map { |r| counselor_row(r) } }
  end

  def counselor_row(row)
    return nil unless row["counselor"]

    { name: row["counselor"], phone: row["phone"], phone_type: row["phone_type"] }
  end

  def in_book(name)
    Store.query("SELECT name, page FROM book_badges WHERE norm = ?", [normalize(name)]).first
  end

  def covered_badges(eagle_only: false)
    sql = +"SELECT b.printed_name, b.book_name, b.eagle_required, COUNT(cb.counselor_id) AS n " \
           "FROM badges b LEFT JOIN counselor_badges cb ON cb.badge_id = b.id "
    sql << "WHERE b.eagle_required = 1 " if eagle_only
    sql << "GROUP BY b.id ORDER BY b.position"
    Store.query(sql)
  end

  # Badges the book carries that nobody in the troop counsels.
  def uncovered
    Store.query(<<~SQL)
      SELECT k.name, k.page FROM book_badges k
       WHERE k.norm NOT IN (SELECT norm FROM badges)
       ORDER BY k.name
    SQL
  end

  # Report badges the 2025 printing does not carry — post-2025 badges, or a
  # spelling this script and `req.rb` fold differently.
  def unmatched
    Store.query("SELECT printed_name FROM badges WHERE book_name IS NULL ORDER BY position")
  end

  def roster
    Store.query(<<~SQL)
      SELECT c.name, c.phone, c.phone_type, COUNT(cb.badge_id) AS n
        FROM counselors c
        LEFT JOIN counselor_badges cb ON cb.counselor_id = c.id
       GROUP BY c.id ORDER BY n DESC, c.name
    SQL
  end

  # The report stores names the way it prints them, "Last, First", but nobody
  # asks that way. Matching each word of the query separately makes the order
  # irrelevant: "Jason Holmes", "Holmes, Jason", and "holmes jason" all land on
  # the same person, while a bare "Holmes" still returns every Holmes — two of
  # them in the 8/3/2026 report, which is exactly when the caller needs to see
  # both rather than an arbitrary one.
  #
  # Deliberately not `normalize`: that drops "and"/"the" to match the book's
  # badge abbreviations, a rule that has no business deciding what a person is
  # called.
  def counselor(name)
    words = name.to_s.downcase.scan(/[a-z0-9]+/)
    return {} if words.empty?

    rows = Store.query(<<~SQL, words.map { |word| "%#{word}%" })
      SELECT c.name, c.phone, c.phone_type, b.printed_name, b.book_name, b.eagle_required
        FROM counselors c
        JOIN counselor_badges cb ON cb.counselor_id = c.id
        JOIN badges b ON b.id = cb.badge_id
       WHERE #{(['LOWER(c.name) LIKE ?'] * words.size).join(' AND ')}
       ORDER BY c.name, b.position
    SQL
    rows.group_by { |r| r["name"] }
  end

  # Names close enough to be worth offering when a lookup misses.
  def suggest(query)
    target = normalize(query)
    return [] if target.empty?

    # The book's spelling is the one to offer; a report badge is only a
    # candidate when the book has no entry for it (a post-2025 badge).
    pool = Store.query(<<~SQL)
      SELECT name, norm FROM book_badges
       UNION
      SELECT printed_name, norm FROM badges WHERE book_name IS NULL
    SQL
    word = target.split.first
    hits = pool.select { |r| r["norm"].include?(target) || target.include?(r["norm"]) }
    hits = pool.select { |r| r["norm"].split.include?(word) } if hits.empty?
    hits.map { |r| r["name"] }.uniq.sort.first(6)
  end

  # Eagle-required coverage, one entry per slot from EAGLE_SLOTS.
  def eagle_slots
    EAGLE_SLOTS.map do |alternates|
      filled = alternates.filter_map do |name|
        found = badge(name)
        found && !found[:counselors].empty? ? { name: name, count: found[:counselors].size } : nil
      end
      { alternates: alternates, filled: filled }
    end
  end
end

# --------------------------------------------------------------------------
# report discovery and freshness
# --------------------------------------------------------------------------
module Source
  module_function

  def newest
    Dir.glob(File.join(REPORTS_DIR, REPORT_GLOB))
       .select { |f| File.file?(f) && f.downcase.end_with?(".pdf") }
       .max_by { |f| File.mtime(f) }
  end

  def resolve(path)
    return path if path

    newest || die("no MBC report given and none found in #{REPORTS_DIR}.\n" \
                  "#{' ' * 7}Drop the TroopMaster \"MBC Grouped By Badge\" PDF there, " \
                  "or name one on the command line.")
  end

  # Load on first use so a query never answers from an empty database, and warn
  # when a newer report is sitting in reports/ than the one that was loaded.
  def ensure_loaded!
    Store.setup
    return load!(resolve(nil)) unless Store.loaded?

    current = newest
    return if current.nil?

    loaded_mtime = Store.meta("report_mtime").to_i
    return unless File.mtime(current).to_i > loaded_mtime

    warn "note: #{File.basename(current)} is newer than the loaded data; reloading."
    load!(current)
  end

  def load!(path)
    parsed = Report.parse(path)
    Store.replace(parsed, Book.badges)
    parsed
  end
end

# --------------------------------------------------------------------------
# verification
#
# The report prints no tally to check against, so `verify` leans on the four
# things its shape guarantees: it is grouped, so every badge has a counselor;
# it is alphabetical; each counselor's phone is the same everywhere; and every
# line carrying a phone code became a row.
# --------------------------------------------------------------------------
module Verify
  module_function

  def run(parsed)
    problems = []
    problems.concat(empty_badges(parsed))
    problems.concat(alphabetical(parsed))
    problems.concat(phone_consistency(parsed))
    problems.concat(line_count(parsed))
    problems.concat(eagle_stars(parsed))
    problems
  end

  def empty_badges(parsed)
    parsed[:badges].reject { |b| b[:counselors].any? }.map do |badge|
      "#{badge[:name].inspect} (line #{badge[:lineno]}) has no counselors — " \
        "a grouped report never prints a badge with none"
    end
  end

  def alphabetical(parsed)
    parsed[:badges].each_cons(2).filter_map do |a, b|
      next if a[:name].downcase <= b[:name].downcase

      "out of alphabetical order: #{a[:name].inspect} precedes #{b[:name].inspect}"
    end
  end

  def phone_consistency(parsed)
    seen = Hash.new { |h, k| h[k] = [] }
    parsed[:badges].each do |badge|
      badge[:counselors].each { |c| seen[c[:name]] << [c[:phone], c[:phone_type]] }
    end
    seen.filter_map do |name, entries|
      distinct = entries.uniq.reject { |phone, _| phone.nil? }
      next if distinct.size <= 1

      "#{name.inspect} has #{distinct.size} different phone numbers: " \
        "#{distinct.map(&:first).join(', ')}"
    end
  end

  def line_count(parsed)
    parsed_rows = parsed[:badges].sum { |b| b[:counselors].count { |c| c[:phone] } }
    return [] if parsed_rows == parsed[:phone_line_count]

    ["parsed #{parsed_rows} counselor rows but the text has " \
     "#{parsed[:phone_line_count]} lines with a phone code"]
  end

  # The star and the EAGLE_SLOTS table are independent statements of the same
  # fact; a disagreement means one of them is stale or misread.
  def eagle_stars(parsed)
    required = EAGLE_SLOTS.flatten.map { |n| normalize(n) }
    parsed[:badges].filter_map do |badge|
      norm = normalize(badge[:name])
      if badge[:eagle_required] && !required.include?(norm)
        "#{badge[:name].inspect} is starred Eagle-required but is not in EAGLE_SLOTS"
      elsif !badge[:eagle_required] && required.include?(norm)
        "#{badge[:name].inspect} is in EAGLE_SLOTS but is not starred on the report"
      end
    end
  end
end

# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
module Render
  module_function

  def phone(row)
    return "(no phone on file)" unless row[:phone] || row["phone"]

    number = row[:phone] || row["phone"]
    label  = PHONE_TYPES.fetch(row[:phone_type] || row["phone_type"], "phone")
    "#{label} #{number}"
  end

  def title(badge)
    name = badge[:book_name] || badge[:printed_name]
    star = badge[:eagle_required] ? "  (Eagle-required)" : ""
    "#{name}#{star}"
  end

  def who(names)
    names.each_with_index do |name, i|
      puts if i.positive?
      one(name)
    end
  end

  def one(name)
    found = Query.badge(name)
    return found_badge(found) if found

    missing_badge(name)
  end

  def found_badge(badge)
    puts title(badge)
    puts "  TroopMaster prints this as #{badge[:printed_name].inspect}." if
      badge[:book_name] && badge[:book_name] != badge[:printed_name]
    unless badge[:book_name]
      puts "  NOTE: not in Scouts BSA Requirements 2025 — a badge introduced or renamed"
      puts "        after that printing. The counselor below is current; get the"
      puts "        requirements from www.scouting.org/meritbadges, not from memory."
    end
    puts "  #{badge[:counselors].size} counselor#{'s' if badge[:counselors].size != 1}:"
    badge[:counselors].each { |c| puts format("    %-22s %s", c[:name], phone(c)) }
  end

  def missing_badge(name)
    entry = Query.in_book(name)
    if entry
      eagle = EAGLE_SLOTS.flatten.map { |n| normalize(n) }.include?(normalize(name))
      puts "#{entry['name']}#{'  (Eagle-required)' if eagle}"
      puts "  NO COUNSELOR in the troop's list."
      puts "  It is a merit badge in Scouts BSA Requirements 2025 (p.#{entry['page']}); the troop"
      puts "  simply has nobody registered for it. Ask the district for a counselor."
      puts "  This one is Eagle-required — worth filling." if eagle
    else
      puts "#{name.inspect} is not a merit badge in Scouts BSA Requirements 2025,"
      puts "  and nobody in the troop's counselor list is registered for it."
      suggestions = Query.suggest(name)
      puts "  Did you mean: #{suggestions.join(', ')}?" if suggestions.any?
    end
  end

  def badges(eagle_only:)
    rows = Query.covered_badges(eagle_only: eagle_only)
    rows.each do |row|
      star = row["eagle_required"] == 1 ? " *" : ""
      puts format("%-34s %2d counselor%s%s", row["book_name"] || row["printed_name"],
                  row["n"], row["n"] == 1 ? " " : "s", star)
    end
    puts "\n#{rows.size} badges covered#{' (Eagle-required only)' if eagle_only}. " \
         "* = Eagle-required."
  end

  def gaps(eagle_only:)
    return eagle_gaps if eagle_only

    rows = Query.uncovered
    rows.each { |row| puts format("%-34s p.%d", row["name"], row["page"]) }
    covered = Query.covered_badges.size
    puts "\n#{rows.size} of #{rows.size + covered} merit badges have no counselor in the troop."
  end

  def eagle_gaps
    Query.eagle_slots.each { |slot| eagle_slot(slot) }
    open = Query.eagle_slots.count { |s| s[:filled].empty? }
    puts "\n#{EAGLE_SLOTS.size - open} of #{EAGLE_SLOTS.size} Eagle-required slots covered."
    puts "A slot with alternates needs only one of them." if open < EAGLE_SLOTS.size
  end

  def eagle_slot(slot)
    label = slot[:alternates].join(" OR ")
    if slot[:filled].empty?
      puts format("%-52s NO COUNSELOR", label)
    else
      detail = slot[:filled].map { |f| "#{f[:name]} (#{f[:count]})" }.join(", ")
      puts format("%-52s %s", label, detail)
    end
  end

  def counselor(name)
    groups = Query.counselor(name)
    return puts("No counselor matching #{name.inspect}.") if groups.empty?

    groups.each_with_index do |(person, rows), i|
      puts if i.positive?
      puts "#{person}    #{phone(rows.first)}"
      rows.each do |row|
        star = row["eagle_required"] == 1 ? " *" : ""
        puts "  #{row['book_name'] || row['printed_name']}#{star}"
      end
      puts "  #{rows.size} badge#{'s' if rows.size != 1}."
    end
  end

  def roster
    rows = Query.roster
    rows.each { |r| puts format("%-22s %2d badges   %s", r["name"], r["n"], phone(r)) }
    puts "\n#{rows.size} counselors, #{Query.covered_badges.size} badges covered."
  end

  def info
    puts "report:      #{Store.meta('report_path')}"
    puts "report date: #{Store.meta('report_date')}"
    puts "loaded at:   #{Store.meta('loaded_at')}"
    puts "database:    #{DB_PATH}"
    puts "counselors:  #{Query.roster.size}"
    puts "badges:      #{Query.covered_badges.size} covered, #{Query.uncovered.size} uncovered"
    unmatched = Query.unmatched
    return if unmatched.empty?

    puts "\nnot in the 2025 requirements book (post-2025 or renamed):"
    unmatched.each { |row| puts "  #{row['printed_name']}" }
  end

  def json
    badges = Query.covered_badges.map do |row|
      found = Query.badge(row["printed_name"])
      { printed_name: row["printed_name"], book_name: row["book_name"],
        eagle_required: row["eagle_required"] == 1, counselors: found[:counselors] }
    end
    puts JSON.pretty_generate(
      report_date: Store.meta("report_date"), report: Store.meta("report_path"),
      badges: badges, uncovered: Query.uncovered.map { |r| r["name"] },
      not_in_2025_book: Query.unmatched.map { |r| r["printed_name"] }
    )
  end
end

# --------------------------------------------------------------------------
# command line
# --------------------------------------------------------------------------
USAGE = <<~TEXT.freeze
  usage: mbc.rb COMMAND [options]

    load      [REPORT.pdf] [--force]   parse the report into .cache/mbc.db
    verify    [REPORT.pdf]             cross-check the parse — run this first
    who       BADGE [BADGE...]         who counsels this badge, if anyone
    counselor NAME                     what one counselor covers
    badges    [--eagle]                badges the troop covers
    gaps      [--eagle]                badges with no counselor
    roster                             every counselor, busiest first
    info                               what is loaded
    json                               the whole thing as JSON

  With no REPORT.pdf, the newest #{REPORT_GLOB}.pdf in reports/ is used.
TEXT

def run_load(argv, force:)
  path = Source.resolve(argv.shift)
  if !force && Store.loaded? && Store.meta("report_path") == path &&
     Store.meta("report_mtime").to_i == File.mtime(path).to_i
    puts "already loaded: #{File.basename(path)} (use --force to reload)"
    return
  end
  parsed = Source.load!(path)
  puts "loaded #{File.basename(path)}: #{parsed[:badges].size} badges, " \
       "#{Query.roster.size} counselors, report date #{parsed[:date]}."
  parsed[:anomalies].each { |a| warn "note: #{a}" }
end

def run_verify(argv)
  path = Source.resolve(argv.shift)
  parsed = Report.parse(path)
  problems = Verify.run(parsed)
  parsed[:anomalies].each { |a| puts "note: #{a}" }

  if problems.empty?
    puts "OK — #{parsed[:badges].size} badges, " \
         "#{parsed[:badges].sum { |b| b[:counselors].size }} counselor rows, " \
         "alphabetical, every badge staffed, phone numbers consistent."
    return
  end

  puts "PARSE PROBLEMS (#{problems.size}):"
  problems.each { |p| puts "  - #{p}" }
  exit 1
end

force = false
eagle = false
parser = OptionParser.new do |o|
  o.banner = USAGE
  o.on("--force", "reload even if the report is unchanged") { force = true }
  o.on("--eagle", "restrict to the Eagle-required badges") { eagle = true }
end
parser.parse!(ARGV)

command = ARGV.shift
die parser.banner if command.nil?

case command
when "load"   then Store.setup and run_load(ARGV, force: force)
when "verify" then run_verify(ARGV)
else
  Source.ensure_loaded!
  case command
  when "who"
    die "usage: mbc.rb who BADGE [BADGE...]" if ARGV.empty?
    Render.who(ARGV)
  when "counselor"
    die "usage: mbc.rb counselor NAME" if ARGV.empty?
    Render.counselor(ARGV.join(" "))
  when "badges" then Render.badges(eagle_only: eagle)
  when "gaps"   then Render.gaps(eagle_only: eagle)
  when "roster" then Render.roster
  when "info"   then Render.info
  when "json"   then Render.json
  else die parser.banner
  end
end
