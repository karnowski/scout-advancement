source "https://rubygems.org"

ruby "3.4.5"

# Local data storage — the troop-calendar occurrence cache.
gem "sqlite3", "~> 2.9"

# Read the advancement PDFs in docs/. Good on the single-column requirements
# book; guide-to-advancement still uses pdftotext, because pdf-reader interleaves
# that PDF's two columns and drops the spaces inside its headings.
gem "pdf-reader", "~> 2.15"

# Parse the troop's iCal feed, expand its recurrence rules, and convert the
# feed's UTC stamps to calendar-local time.
gem "icalendar", "~> 2.12"
gem "rrule", "~> 0.8"
gem "tzinfo", "~> 2.0"

# Lint the skill scripts. Not needed at runtime, so it stays unrequired.
group :development do
  gem "rubocop", "~> 1.88", require: false
end
