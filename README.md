# Scout Advancement

Claude skills to help the troop Advancement Chair and Scoutmasters communicate and plan a Scouting America troop advancement program.

## References

- [Official Troop 400 Calendar](https://calendar.google.com/calendar/ical/troop400durham.org_cc4de26nmjft4ger2t11mon03o%40group.calendar.google.com/public/basic.ics)

## Skills

### `guide-to-advancement`

Answers questions about *how* advancement is administered — boards of review,
Eagle Scout procedures, merit badge counseling, appeals, time extensions,
alternative requirements, advancement for members with special needs, and
unit/district/council roles.

Every answer comes from the text of the _Guide to Advancement 2025_
(`docs/guide-to-advancement-2025.pdf`), never from memory: the skill quotes the
supporting passage verbatim and cites the Guide's own section number, section
title, and printed page (e.g. *8.0.1.1 "Not a Retest or 'Examination'", printed
p. 55*).  It also preserves the Guide's distinction between **must** (mandated),
**should** (recommended), and **may** (optional), which is usually the point of
the question.  When the Guide doesn't cover something, the skill says so and
points to the local district or council advancement chair rather than guessing.

### `troop-calendar`

Answers questions about the troop schedule — what's coming up, when the next
campout or court of honor is, what's on a given date — from the [official Troop
400 calendar feed](#references).

It downloads the Google Calendar iCal feed, expands recurring events into concrete occurrences (resolving the many single-instance overrides the troop's calendar accumulates), and caches them in SQLite, re-syncing when the cache goes stale.

### `target-first-class`

Turns a TroopMaster **Target First Class** report — the dense grid of every
Scout working toward Scout, Tenderfoot, Second Class, and First Class — into an
advancement plan and a set of to-do lists.  The report says what is *done*; the
plan says what to *do*, in what order, and on which dates.

Most of the skill's value is in the three things the grid does not state: which
requirements carry a calendar clock that cannot be compressed (the Tenderfoot →
Second Class → First Class fitness chain), which Scouts have a pile of banked
work sitting behind one unearned rank, and whether the Scoutmaster conference and
board of review load actually fits in the meeting nights available.  It draws
real dates from `troop-calendar`, policy and citations from
`guide-to-advancement`, and requirement text from
`docs/Scouts-BSA-Requirements-2025.pdf`.

Plans are written to `plans/target-first-class-YYYY-MM-DD.md`, dated from the
report they read.
