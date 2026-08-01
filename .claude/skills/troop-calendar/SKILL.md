---
name: troop-calendar
description: Look up what is on the troop's calendar — meetings, campouts, courts of honor, service projects, boards of review, troop elections, summer camp — by reading the troop's published iCal feed. Use whenever someone asks what is coming up, what happened on a date, when the next campout or court of honor is, or wants to plan advancement around the troop schedule.
---

# Troop calendar

Answer questions about the troop's schedule from the troop's own published
calendar feed, never from memory or assumption.  The calendar is edited
continuously by troop leadership; the feed is the only current record of it.

## Tool

`scripts/calendar.rb` downloads the feed, expands recurring events into concrete
occurrences, and caches them in SQLite under `.cache/calendar.db`.  It syncs
automatically when the cache is missing or more than six hours old, so normally
you can go straight to a query command.

```
ruby scripts/calendar.rb next [--days N]                 # default 30
ruby scripts/calendar.rb month 2026-08 [2026-09 ...]
ruby scripts/calendar.rb events [--from DATE] [--to DATE]
ruby scripts/calendar.rb search PATTERN [--from DATE] [--to DATE]
ruby scripts/calendar.rb sync [--force]
ruby scripts/calendar.rb info
```

- Dates are `YYYY-MM-DD`.  `events` defaults to the next 90 days.
- `search` is a case-insensitive substring match on the event title.
- All query commands accept `--json` when you need the raw fields.
- `info` reports the feed URL, timezone, last sync, and cached date window.
- Ranges are inclusive and match anything that **overlaps** them, so a campout
  that starts before `--from` and runs into the window still shows up.

The feed URL defaults to the Troop 400 calendar linked in `README.md`; override
it with the `TROOP_CALENDAR_URL` environment variable.  The cache covers roughly
two years back and three years forward, rebuilt on each sync.  If the feed can't
be reached, the script re-expands the last downloaded copy and warns — pass that
warning on, because the answer may be stale.

## Reading the calendar

Report what the calendar says, and keep it separate from what it implies.

- **Quote titles exactly as they appear.**  They are informal and often
  abbreviated or provisional.  A leading `?` or a trailing "TBD" means troop
  leadership has not settled it — say so rather than presenting it as fixed.
- **Recurring meetings are heavily overridden.**  Individual instances get moved
  or renamed (a first-Monday PLC lands on a Tuesday when the Monday is a
  holiday).  The script resolves these, so trust its output over the pattern the
  titles suggest.
- **Patrol names lead many meeting titles.**  Entries like "Brotherhood –
  backpacking" or "Eagles – Sustainability" are a patrol plus that night's
  program topic, not a rank or an award.  Do not read "Eagles" as Eagle Scout or
  "Brotherhood" as the Order of the Arrow honor.
- **Multi-day events show both ends.**  A campout listed
  `Fri Oct 9 5:00 PM – Sun Oct 11 12:00 PM` is two nights, which is the detail
  that matters for camping requirements.
- If nothing matches, say the calendar has nothing scheduled rather than
  guessing.  An empty result means the event is not on the calendar, which is
  not the same as it not happening.

## Advancement relevance

The advancement value of this skill is connecting the schedule to what Scouts
need.  Events that usually matter to the Advancement Chair:

- **Campouts and outdoor events** — nights of camping and the activities that
  feed rank requirements, Camping merit badge, and OA eligibility.
- **Service projects** — service hours for Star, Life, and Eagle.
- **Courts of honor** — the recognition deadline that advancement reporting and
  awards purchasing have to be finished before.
- **Boards of review and Scoutmaster conferences** — when they are scheduled,
  and who needs one before the next court of honor.
- **Troop elections and leadership turnover** — these start and end the
  position-of-responsibility tenure clocks for Star, Life, and Eagle.
- **Summer camp and high-adventure** — the year's densest advancement block.

**State the calendar fact and the advancement implication separately, and do not
assert that an event satisfies a requirement.**  The calendar shows only that
something is scheduled — not who attended, how many nights they stayed, whether
the activity met the requirement's terms, or whether it was approved.  Say
"Fall Camporee is two nights, which would count toward the Camping merit
badge's 20 nights for Scouts who attend," not "this gets them to 20 nights."

For what a requirement actually demands, use `docs/Scouts-BSA-Requirements-2025.pdf`.
For how advancement is administered — board of review procedure, tenure rules,
what counts as a position of responsibility — use the **guide-to-advancement**
skill.  This skill supplies dates; those supply the rules.  When a question needs
both, get the date here and the rule there, and cite each.

## Answering

- Lead with the direct answer — the date and time asked for.
- Give events as a short list or table in chronological order, with the event
  title, the day and date, and the time or date span.  Include the location when
  the feed has one.
- Note anything provisional, moved, or ambiguous in the underlying entry.
- Add advancement implications only when they're relevant to what was asked, and
  flag them as implications.
- If the answer depended on a stale cache or a failed sync, say so.
