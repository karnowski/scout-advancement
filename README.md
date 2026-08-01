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

Every answer comes from the text of the Guide to Advancement 2025
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

`scripts/calendar.rb` downloads the iCal feed, expands recurring events into
concrete occurrences (resolving the many single-instance overrides the troop's
calendar accumulates), and caches them in SQLite, re-syncing when the cache goes
stale.

```
ruby scripts/calendar.rb next --days 30
ruby scripts/calendar.rb month 2026-08 2026-09
ruby scripts/calendar.rb search camporee
```

The skill reports dates and flags provisional entries, then separates what the
calendar *says* from what it *implies* for advancement — it will note that a
campout spans two nights, but leaves whether that satisfies a requirement to the
requirements book and the `guide-to-advancement` skill.
