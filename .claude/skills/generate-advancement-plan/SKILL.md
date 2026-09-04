---
name: generate-advancement-plan
description: Turn one Scout's imported TroopMaster "Individual History" record into a personalized advancement plan — what to work on, in what order, and by which date — covering rank requirements, merit badges, and position of responsibility.
---

# Generate advancement plan

Build an advancement plan for **one Scout**, from the record
`import-individual-history` stored and `individual-history` reports.

The record says what is *done*. The plan's job is to say what to *do*, in what
order, and by which date. Almost all of the value is in four things the record
does not state: which work is on a clock that cannot be compressed, which rank
is blocking a pile of work already signed above it, which badge is one sign-off
from closing, and whether any of it makes the next court of honor.

This is the skill for a Scoutmaster conference, for a parent who asks "what's
next", and for the Advancement Chair deciding where to spend a Saturday.

**It plans; it does not report.** What the record says is `individual-history`,
and a plan should be checkable against it line by line. It also plans for **one
Scout at a time** — cohort work, batch sessions, and meeting-night throughput
are not here (see "What this skill is not", below).

## Tool

`scripts/plan.rb` does the dated arithmetic. It reads the record through
`individual-history` rather than out of the database, so a plan and a report
cannot describe different Scouts. It needs the repo's gems
(`bundle install` from the repository root) and no PDF tools.

```
ruby scripts/plan.rb brief  NAME    everything below, in the order a plan is written in
ruby scripts/plan.rb ladder NAME    ranks in sequence, what is open, work banked above them
ruby scripts/plan.rb clocks NAME    every dated item, earliest date, whether it makes the target
ruby scripts/plan.rb badges NAME    Eagle slots open, partials by closing cost, prerequisites
ruby scripts/plan.rb names  NAME    badge names in play, one per line, for `req.rb check`
ruby scripts/plan.rb json   NAME    all of it, machine-readable
ruby scripts/plan.rb verify         every match key resolves; both copied algorithms agree
```

Options, on every per-Scout command:

- `--by DATE` — the date to plan against. Defaults to the next court of honor's
  cut-off in `TROOP-SETTINGS.md`, and the header always prints which date it
  used and where it came from.
- `--start DATE` — when the Scout actually begins work. Every *work-start* clock
  runs from here; defaults to today, but the first meeting after the plan lands
  is usually the honest choice.
- `--test-date DATE` — when Tenderfoot 6a is actually run, for a Scout who has
  not taken it. Everything downstream of it moves with this date. Defaults to
  `--start`.
- `--tenderfoot-6bc sequential` — read 6b and 6c as two consecutive 30-day
  windows. Troop 400 reads them as one shared window (the default); that is
  settled in `TROOP-SETTINGS.md`, not in the book.

`NAME` is resolved by `individual-history`: `"Rivera, Sam"`, `"Sam Rivera"`,
`Rivera`, or `Sam`. An ambiguous name is an error naming both, never a guess.

## Run these three before writing anything

### 1. `verify` — the match keys still resolve

```
ruby scripts/plan.rb verify
```

There is no PDF to check a parse against here; the record arrives already
verified by the importing skill. What goes wrong instead is **silent
disablement**. A badge renamed in the requirements book, a requirement label
TroopMaster reworded, or one of the two duplicated algorithms edited in only one
of its copies leaves a plan that reads perfectly and has quietly stopped
applying a rule. `verify` resolves every badge name against `scout-req`, checks
every requirement label and fitness-chain link against the imported data, and
cross-checks this skill's Eagle slots and position-of-responsibility months
against what `individual-history` prints for every Scout.

### 2. Check the badge names against `scout-req`

```
ruby scripts/plan.rb names NAME | ruby ../scout-req/scripts/req.rb check
```

A TroopMaster report has no way to know what year a badge's requirements are
from. It prints "Artificial Intelligence" at 20% as calmly as it prints Camping,
and a plan built on the 2025 book for a badge that changed in 2026 sends a Scout
to do months of the wrong work. Nothing downstream catches it — the plan reads
perfectly.

**Exit 3 means stop.** Lead the plan with the banner, say plainly that the
requirements must come from `www.scouting.org/meritbadges`, and assign no work
on that badge. Do not substitute the 2025 text. A badge merely *changed* for
2026 is not exit 3 — `check` prints a note and `req.rb show` prints the updated
text, so the plan can use it; say which year it is quoting.

This matters more here than anywhere else in the repo: **45 of the 95 badges on
the troop's current whole-troop Individual History report changed effective Jan.
1, 2026**, and every partial carries the requirement *year* the Scout started
under, which is often neither.

### 3. Check the record is fresh

`brief` prints the report's age in its header and repeats it under NOTES past 30
days. **A stale record does not look stale in a plan.** It looks like a Scout
who has not done the work, and produces a to-do list of things they finished
last month. Re-run the Individual History report and import it before planning.

## The analysis

### Read the ladder before the clocks

`ladder` lists every unearned rank with what is open, what is signed, and how
many merit badge slots are unfilled, marking the one being worked on. Two things
come out of it:

- **Ranks must be earned in sequence.** Scout through First Class "may be worked
  on simultaneously; however, these ranks must be earned in sequence" (*Guide to
  Advancement 2025*, 4.2.0.1, printed p. 18). So a Scout can have a large amount
  of First Class work signed and still be stuck behind Tenderfoot.
- **The banked line is the highest-yield finding in any record.** When it says
  36 requirements are signed above the working rank, a handful of cheap items at
  the working rank converts all of them into rank. Lead with those Scouts, and
  chain the finding against `clocks` to say which ranks they can realistically
  reach and by when.

`ladder` also prints a `!!` line for a fitness-chain sign-off recorded out of
order. That is a question for the Advancement Chair about the record, not
something to plan around.

### The three kinds of clock are not interchangeable

`clocks` tags every dated item, and the tag decides how the date may be used.
Conflating them is how a plan gets a confident, specific, wrong date.

| Tag | What it is | Where the date comes from |
| :-- | :--------- | :------------------------ |
| `[elapsed]` | active participation, position-of-responsibility tenure | the record's own dates — calendar time passes whether or not anyone is working on it |
| `[work]` | Tenderfoot 6b/6c, Second Class 7a, First Class 8a, Personal Management 2, Personal Fitness 7/8, Family Life 3, Gardening 5, Multisport 5 | `--start`, because "30 days" means 30 days of *tracked work* |
| `[opportunity]` | Camping 9a's 20 nights, Citizenship in the Community 7's 8 volunteer hours, Personal Fitness 1's exams | nowhere — these need an event or an appointment |

Three consequences worth stating in the plan:

- **An `[elapsed]` date is a fact.** "Six months active as a Star Scout, from
  May 12" comes due on Nov 12 no matter what anyone does, and a Scout who misses
  a court of honor on it cannot be helped by working harder. Say so plainly and
  give the date they *can* make.
- **A `[work]` clock's "start by" is the number the plan schedules against.**
  A 13-week badge started the week of the report finishes about three months
  later; started a month after, it misses. On the fitness chain the start-by is
  **cumulative** — the line reads "the chain must start by", because each link
  needs the one above it finished and First Class 8a is twelve weeks out, not
  four.
- **An `[opportunity]` row has no date and must not be given one.** Take it to
  `troop-calendar` and find the event that closes it. A Scout blocked on 20
  nights of camping with two campouts on the calendar is a different problem
  from one blocked on a 90-day log, and the plan should not make them look alike.

An opportunity still has a *size*, though, and where the record can supply one
the row carries it:

```
[opportunity] Camping req. 9                       —   scheduled against an opportunity
              20 nights — req. 9a is 20 nights of camping
              16 of 20 nights on the record — 4 more to go
              16 of them since 2025-01-03, across 7 outings
```

The headline figure is TroopMaster's own **lifetime** total out of the record,
because req. 9a's nights are a lifetime count. The second line comes from the
Individual Participation report and is only the recent rate, because that
report's date range is a window — a Scout who camped before it would come out
short if the window were used as the total. Where the report can see cabin
nights it says so, since req. 9a does not accept them.

### Service hours are a quantity, and the plan says how many

Every other open requirement is a checkbox. Service is not, and "3 of 6 hours,
at least 1 of it conservation" is a Saturday morning where "you still owe the
service requirement" is an unbounded ask. The working rank's line carries it:

```
[ ]          Service Project   3 of 6 hours since Aug 16, 2025, 2 of 3 conservation
                               — 3 short, at least 1 of it conservation
```

The hours come from `import-activities-history`, clipped to the Scout's own
rank date. Three things about the arithmetic, all confirmed against the figures
TroopMaster printed on the Target Eagle report this replaced:

- **Hours count only while holding the prior rank.** Hours banked before the
  rank date are real hours and count toward nothing here.
- **Conservation hours count toward the total**, not separately from it.
- **Life's shortfall is the larger of the two gaps**, never their sum. A Scout
  eight hours in with no conservation still owes three, and a Scout three hours
  in with two of them conservation also owes three. Both cases are in the
  troop's data and only this reading reproduces what TroopMaster printed.

**The participation report is optional and everything degrades without it.**
With no report the line reads `no participation report imported`, a note at the
bottom says which figures are missing, and the rest of the plan is unchanged.
If the report's date range starts *after* the Scout earned their rank the line
says so and gives no number at all, because a count would run short — and
running short on service hours reads as a Scout who owes work they have already
done.

### The position of responsibility is where plans go wrong

`clocks` prints one `[elapsed]` row for it, and the two failure modes read very
differently:

- **A clock that has not finished yet** — "3.7 of 6 months credited since May 12,
  Assistant SPL running" — is on track and needs nothing but time.
- **No credited position running at all** is the largest problem in a record,
  and the row says so instead of giving a date. Nothing is accruing, so the
  earliest possible finish is a full term after one *starts*. That is usually
  fixable the same week, because most Eagle-qualifying positions are appointed
  rather than elected — but the list of which positions qualify is Eagle
  requirement 4 and does not include every job a troop hands out. Get it from
  `req.rb show Eagle` before naming one to a Scout.

Two things about the tenure figure itself, both of which `individual-history`
computes and this skill reuses: time counts only **since the Scout earned the
rank they hold now**, so a Scout with years of leadership can legitimately show
zero months toward Life; and overlapping terms are **one stretch of calendar
time, not two**.

The months are a threshold, not the requirement. Whether a Scout has "served
actively" is a judgment for the Scoutmaster, and the governing text comes from
`scout-req`.

### Merit badges: cheapest first, and mind the year

`badges` prints the Eagle-required slots still open, then every partial ordered
by what it costs to close — furthest along first, then fewest open
requirements.

- **A badge at 94% with one requirement open is the cheapest advancement
  available.** Say which requirement, in the requirement's own words from
  `scout-req`, not from the report's code.
- **Every partial carries the requirement year it was started under**
  (`Personal Management (2019)`). Say which year, and check the current text
  before telling a Scout what is left. This is the single most common way an
  otherwise correct plan sends a Scout to do the wrong work.
- **`**` lines are badge-to-badge dependencies.** Emergency Preparedness
  requirement 1 is the First Aid merit badge, so a Scout at 98% on First Aid and
  97% on Emergency Preparedness is *one sign-off* from two Eagle-required
  badges. Confirm the wording with `req.rb show "Emergency Preparedness"` before
  it reaches a plan.
- **Idle time is not expiry.** A partial is good until the Scout turns 18. `idle
  591d` means nobody has recorded progress in that long, which is worth a
  conversation, not a deadline — though a requirement *year* that has since
  changed is a real complication.
- **Below Star no merit badge is required at all**, so for a Scout working Scout
  through First Class the only badge clocks shown are for badges they have
  already started. Do not pad a Tenderfoot Scout's plan with Eagle badge work.

### Eagle coverage is 13 slots, and three of them are OR-groups

`badges` reports the **13 Eagle-required slots**: Emergency Preparedness *or*
Lifesaving; Environmental Science *or* Sustainability; Swimming *or* Hiking *or*
Cycling. Any one alternate fills its slot, so 13 slots are not 13 badges and
counting a Scout's Eagle-required badges overstates what is left.

**The troop counts 13, not the 14 printed at Eagle requirement 3** —
Citizenship in Society counts toward the 21 badges Eagle asks for and fills no
required slot. That is a decision of the troop's and it departs from the printed
book, so `scout-req` will quote 14 and is not wrong to. `individual-history`
sets out the evidence; when it matters, say which basis the plan is on. See also
"Advancement Updates" in `TROOP-SETTINGS.md`, which is where the troop records
the change and its own offer to help any Scout who wants to finish the badge
anyway.

### The 18th birthday is the only deadline that cannot move

The header prints it and the days remaining. For a Life Scout it governs
everything: Eagle requirements 1–6 — the project, the position of
responsibility, and the Scoutmaster conference included — must all be complete
**before** the 18th birthday. Only the board of review may happen afterward, up
to 24 months without special approval (*Scouts BSA Requirements 2025*, Eagle
rank footnote 13, citing *Guide to Advancement* 8.0.3.1; `req.rb show Eagle`
prints the footnote and the citation line to quote). That exception does not
cover the project, and a project proposal needs four approvals — the benefiting
organization, the Scoutmaster, the troop committee, and the council or district
— before any work starts. `eagle-req` has the workbook.

**A missing date of birth is a finding, not a blank line.** The header says so
and NOTES repeats it: TroopMaster cannot compute the deadline, and the gap will
break the Eagle application later.

## Troop conventions

**Read all of `TROOP-SETTINGS.md` before writing the plan, not just one
section.** Three of its sections change what the plan says, and two can silently
invalidate output that otherwise looks right:

- **"How the troop runs advancement"** — the SMC/BoR abbreviations, whether
  conferences and boards appear on the calendar, sign-off authority, and any
  recurring sign-off event like "Saturday at the Shed". It also records local
  readings of ambiguous requirements: the Tenderfoot 6b/6c question is settled
  there, not in the book, and it is what `--tenderfoot-6bc` exists for.
- **"Advancement Updates"** — requirement changes that postdate the 2025
  printings. These override both the requirements book and the record's own
  marks, and **no script catches them**: `req.rb check` is silent when a badge
  still exists but its rank status changed, and TroopMaster keeps printing the
  old Eagle-required star. Apply them by hand and say in the plan that you did.
- **"Scout Updates"** — per-Scout facts the record cannot know: a Scout who has
  left the troop and must not appear in any plan at all, work already finished
  that the record still shows as open, or a Scout who has decided not to attempt
  Eagle. **Check the Scout's name against this section before writing a line.**
  A plan for a Scout who has left the troop, or an Eagle plan for a Scout who
  has said they do not want one, is worse than no plan.

Two things that hold regardless of troop convention:

- Committee members conduct boards of review and "may not test or pass Scouts on
  rank requirements" (*GTA* 4.2.1.2, printed p. 19), so board reviewers should
  never be drawn from the sign-off crew. Only the Scoutmaster runs Scoutmaster
  conferences.
- **The Eagle board of review is not a troop board.** It is conducted per council
  policy, usually by the district. Do not schedule it into a troop meeting.

Where the troop's convention collapses the closing three requirements into one
line — "needs an SMC/BoR meeting" — follow it, with the two exceptions
`TROOP-SETTINGS.md` names: Scout rank has no board of review, and at Eagle the
board stays a separate line because it is not a troop board.

## Working with the other skills

- **individual-history** — what the record says. Every claim in the plan should
  be checkable against `history.rb show NAME`.
- **import-activities-history** — the only source of a *quantity*: service
  hours, conservation hours, and camping nights, each dated, so they can be
  clipped to a rank date. Optional; without it the plan says a requirement is
  open and cannot say how much of it is done.
- **scout-req** — the requirement text, and the only thing that knows whether a
  badge is still current. Use it for **every requirement the plan names**: the
  record gives a code like `8d` and a label like `4c. Tell How to Prevent
  Injury`, and those are TroopMaster's abbreviations, far too short to plan from
  and not maintained against the book. Never quote one as requirement text.
- **troop-calendar** — the real dates. Anchor every piece of work to an event
  that can actually close it: cooking requirements to a campout, Camping 9b to a
  canoe trip, conservation hours to a cleanup, classroom badges to a merit badge
  college. Then **flag the requirements with no opportunity on the calendar** —
  a swim test with no pool date is a Scout who cannot finish, and that is worth
  more to the reader than another to-do line. Search a year out, not just the
  planning window; "the next one is in January" is the finding.
- **mbc** — who counsels a badge, and which badges have no counselor at all. A
  plan that tells a Scout to start Personal Management without saying who can
  sign it is half a plan.
- **guide-to-advancement** — the policy, with citations: sequence, sign-off
  authority, boards, conferences, extensions, and anything about the 18th
  birthday.
- **eagle-req** — the Eagle project workbook, for any Scout whose plan touches
  the project.

State the calendar fact and the advancement implication separately. The calendar
shows something is scheduled, not that a Scout attended or that a requirement was
met.

## Writing the plan

Lead with the two or three findings that change what the Scout and their leaders
do next, not with a record dump. A good plan has answered: *what has to start
this week, what converts the most work into rank the fastest, and what will this
Scout have finished by the next court of honor?*

Suggested shape:

1. **Bottom line** — three findings, at most. Name the dates.
2. **Where the Scout stands** — rank, working rank, and the ladder, with the
   banked-work finding if there is one.
3. **The clocks** — what must start this week and by when, separated into the
   three kinds. Say which court of honor each item makes.
4. **Rank requirements** — the open items for the working rank, in the
   requirement's own words from `scout-req`, with the closing three collapsed as
   the troop does it.
5. **Merit badges** — cheapest partials first, then the open Eagle slots, with
   the requirement year on every one and the counselor from `mbc`.
6. **Position of responsibility** — where the tenure stands and what to do about
   it, if the rank asks for one.
7. **Calendar hooks and gaps** — which event closes which requirement, and what
   has no date at all.
8. **For the Advancement Chair** — anything needing an adult rather than the
   Scout: a position to appoint, a counselor to find, a record to correct, an
   event to book.
9. **Notes on the source data** — the report's date, anything `verify` or
   `req.rb check` flagged, and any figure that is an estimate.

Write plans to `plans/advancement-plan-{lastname}-{firstname}-YYYY-MM-DD.md`,
**dated from the report the record came from** (`report_date`, which
`plan.rb json` prints), not from today. Lowercase the names and strip anything
that is not a letter or a hyphen: `plans/advancement-plan-rivera-sam-2026-09-02.md`.
Two runs against the same report overwrite; don't invent `-backup` names.
`plans/` is gitignored and already present, and the Write tool creates the
directory anyway, so there is no `mkdir` step.

Three things to keep honest:

- **Distinguish what the record states from what you are projecting.** Every
  `[work]` date moves with `--start`; say which `--start` and `--test-date` the
  plan ran on, so a reader who disagrees knows which numbers to re-read.
- **Say when the Scout cannot realistically make the next court of honor,** and
  give the date they can make instead.
- **When the record cannot answer something, say that it cannot** rather than
  guessing — an `[opportunity]` row with no event on the calendar, a missing date
  of birth, a partial under a requirement year that has since changed.

## Running many at once

One plan is a session's worth of work — the checks, the requirement wording,
the calendar hooks, the counselors. A patrol is eight of those, and the troop is
thirty-eight, which does not fit in one context.

The **`advancement-plan` agent** (`.claude/agents/advancement-plan.md`) is this
skill wrapped for that: hand it a Scout's name and it runs this skill end to end
in its own context and writes the one file. Launch several in the same turn to
cover a patrol.

That does not make this a cohort skill. **Each agent is still one Scout, one
plan** — the fan-out is parallel invocation, not a batch analysis. What the
troop does at its next few meetings is still `troop-advancement-plan`.

Before fanning out, the launching session does the shared work **once**, because
the agents are told not to:

```
ruby .claude/skills/troop-calendar/scripts/calendar.rb sync
ruby .claude/skills/individual-history/scripts/history.rb roster
```

The sync matters: `calendar.rb` re-syncs itself whenever its cache is over six
hours old, so a dozen agents starting cold means a dozen feed fetches racing on
one SQLite file. Warm it first and every agent just reads. Import the Individual
History report first too, for the same reason — the agents read that database
and are forbidden to write it.

The roster is where the names come from, and it is worth reading rather than
skimming: it still lists Scouts who have left the troop, since the report was
run before they left. `TROOP-SETTINGS.md` "Scout Updates" is what says so, and
each agent re-checks its own Scout against it and stops rather than writing a
plan for someone who is gone.

An agent's report is not shown to the user, so relay what comes back — the file
path, the bottom line, and anything it flagged as needing an adult.

## What this skill is not

- **It is not a troop-wide planner.** One Scout, one plan. Requirements several
  Scouts need at once, Saturday-at-the-Shed session plans, and whether the
  conference and board load fits the meeting nights available are cohort
  questions this skill does not answer; `troop-advancement-plan` does. Running
  this skill for thirty-eight Scouts is not the same thing — see "Running many
  at once" above.
- **It does not report the record.** `individual-history` does, and a plan that
  disagrees with it is wrong.
- **It does not quote requirements.** `scout-req` does. The tables in `plan.rb`
  — `CLOCKS`, `FITNESS_CHAIN`, `EAGLE_SLOTS`, `POR_MONTHS`, `ACTIVE_MONTHS`,
  `BADGE_PREREQS` — are **match keys, not a second copy of the book**. They exist
  so a span can be found and a Scout sorted onto it. Do not quote one into a
  plan, and do not delete them either: the arithmetic does not work without them.

## Privacy

**This repository is public and this skill is entirely about a minor** — a named
Scout, their rank dates, and their birthday.

Plans go in `plans/`, which is gitignored, and the record lives in the importing
skill's `.cache/`. Names are fine in a session, in a plan file, and in an answer
to the Advancement Chair. They never reach a tracked file, a commit message, a
branch name, or a PR description — summarize a change as "regenerate an
advancement plan", never by whose it is. The names used in this file are
invented.

## Facts the script depends on

- **The record comes from `history.rb json`, never from the database.** The
  importing skill owns the file and `individual-history` is its reader. Going
  round that reader would give the plan its own name matching, its own freshness
  rule, and its own chance to describe a Scout the reporting skill does not.
- **The three kinds of clock are the whole design** — see the table above. An
  `[elapsed]` date read as `[work]`, or an `[opportunity]` given a date at all,
  produces a plan that is specific, confident, and wrong. An opportunity may
  carry a *size* — nights banked, hours banked — and still no date; the two are
  different claims.
- **Service hours are clipped to the rank date, conservation counts toward the
  six, and Life's shortfall is the larger of the two gaps** — see the section
  above, and `SERVICE_HOURS` in the script. Summing the two gaps double-counts;
  ignoring the conservation one sends a Scout to the wrong kind of project.
- **`SERVICE_TYPES` and the `counts:` entries in `CLOCKS` are activity-type
  match keys**, and the types are the troop's own TroopMaster configuration
  rather than anything in the book. A renamed type does not error — it totals
  zero, and every Star and Life Scout is then told to do six hours they may
  already have done. `verify` checks each against the imported participation
  data whenever any has been imported.
- **Citizenship in the Community req. 7 is deliberately not counted**, though
  the participation report carries hours that look as though they would fit.
  Req. 7c's hours are for the Scout's chosen organization, and the troop's own
  service projects are not that.
- **A sign-off date on the previous link does not start the next one.** A Scout
  whose Tenderfoot 6a was signed six months ago has not banked 30 days of 6b
  tracking — 6b is a log the Scout keeps, and nobody kept it. The record's dates
  say which links are *done*; `--start` says when the rest can begin.
- **The fitness chain's start-by is cumulative.** Each link needs the one above
  it finished, so the date that has to be met for First Class 8a is when the
  whole remaining chain starts, not four weeks before the target.
- **A filled merit badge slot is not a signed rank requirement.** Counting the
  two together makes every Scout with badges toward Eagle look as though they had
  banked rank work above the rank they are on. `ladder` counts them apart.
- **`POR_MONTHS` and the tenure algorithm are the second copy**, and
  `EAGLE_SLOTS` is the **third** (`mbc.rb` and `history.rb` carry the others).
  They are duplicated because the skills are siblings with no library between
  them. `verify` cross-checks both against what `individual-history` prints for
  every Scout, so the copies cannot drift unnoticed — **run it after touching
  either table.**
- **A badge nobody has started has every requirement open**, so its clock
  applies in full. The lookup asks whether the badge is in play, not whether a
  partial row exists — the badges whose whole clock is still ahead of them are
  exactly the ones a plan most needs to start.
- **Palms are ranks in the record but not on the ladder.** They are reported as
  remaining work and given no clock arithmetic.
- **The target date comes from a hand-kept table.** `--by` wins; otherwise the
  next court of honor after today is read out of `TROOP-SETTINGS.md`, preferring
  its cut-off date over the ceremony date. The header always prints which date
  it used, where it came from, and — when the table records no cut-off — that it
  fell back to the ceremony date.
