---
name: troop-advancement-plan
description: Plan the troop's next few meetings, campouts, and outings from the imported TroopMaster "Individual History" data — which program themes clear the most work, what has to start now, whether the conference and board load fits, and which Scouts need an adult.
---

# Troop advancement plan

Answer **"what do we actually do at the next few meetings and activities?"**
across the whole troop, from the record `import-individual-history` stored and
`generate-advancement-plan` reasons about.

This is the skill for the Scoutmaster and Advancement Chair sitting down to
schedule a quarter: which evening is worth running, which campout closes the
most work, what has to start this month or it misses the court of honor,
whether the conference and board load fits the meeting nights available, and
which four or five Scouts need someone to notice them.

**It plans for the troop; it does not plan for a Scout.** Every number it prints
comes back from `generate-advancement-plan`, so the two cannot disagree — but
this skill deliberately stops at the cohort. When a Scout here needs a real plan
of their own, run `generate-advancement-plan` for them and write that plan
separately.

## Tool

`scripts/troop.rb` does the cohort arithmetic. It reads each Scout's analysis
back out of `generate-advancement-plan` and the raw record out of
`individual-history`; it opens no PDF and writes to no database. It needs the
repo's gems (`bundle install` from the repository root) and no PDF tools.

```
ruby scripts/troop.rb brief     everything below, in the order a plan is written in
ruby scripts/troop.rb cohorts   who is working on what, how close, what is banked above
ruby scripts/troop.rb themes    what one meeting, campout, or outing is worth
ruby scripts/troop.rb clocks    every clock rolled up: what has to start now, and for whom
ruby scripts/troop.rb load      the conference and board load against meeting-night capacity
ruby scripts/troop.rb badges    Eagle slots and partials several Scouts share
ruby scripts/troop.rb attention Scouts who need an adult, most urgent first
ruby scripts/troop.rb json      all of it, machine-readable
ruby scripts/troop.rb verify    plan.rb verifies; every requirement claimed; counts agree
```

Options, on every command:

- `--exclude NAME` — drop a Scout who has left the troop, **before anything is
  counted**. Repeatable. See "Before anything else", below.
- `--by DATE` — the date to plan against. Defaults to the next court of honor's
  cut-off in `TROOP-SETTINGS.md`; the header prints which date it used and where
  it came from.
- `--start DATE` — when work actually begins. Every *work-start* clock runs from
  here; defaults to today, but the first meeting after the plan lands is usually
  the honest choice.
- `--test-date DATE` — when Tenderfoot 6a is actually run, for the Scouts who
  have not taken it. Everything downstream moves with it. Defaults to `--start`.
- `--tenderfoot-6bc sequential` — read 6b and 6c as two consecutive 30-day
  windows. Troop 400 reads them as one shared window (the default); that is
  settled in `TROOP-SETTINGS.md`, not in the book.

Sizing and threshold options: `--min N` (hide themes and shared badges under N
Scouts, default 2), `--min-banked N` (default 5), `--per-meeting N` (default 3),
`--soon DAYS` (default 21), `--quiet DAYS` (default 150), `--stalled DAYS`
(default 365).

`--by`, `--start`, `--test-date`, and `--tenderfoot-6bc` are passed through to
`generate-advancement-plan` unchanged, so a troop plan and the individual plans
written from the same flags agree line for line.

## Before anything else: exclude Scouts who have left

Read **"Scout Updates"** in `TROOP-SETTINGS.md` and pass `--exclude` for every
Scout named there as having left. TroopMaster keeps printing them:

```
ruby scripts/troop.rb brief --exclude "Lastname"
```

A departure is a rounding error in one Scout's plan and a real error here — it
inflates a cohort, a conference count, and a meeting-night total, and the wrong
number is the one the troop schedules against. Pass the same `--exclude` flags
to every command in the run so the cohort sizes, the load, and the theme counts
all agree. The script prints a stderr note with the count; put that count in the
plan without naming anyone. A pattern that matches nobody is a note, not an
error — once TroopMaster catches up, last month's essential `--exclude` matches
nothing.

## Run these three before writing anything

### 1. `verify` — nothing has silently stopped applying

```
ruby scripts/troop.rb verify
```

There is no PDF to check a parse against; the record arrives already verified.
What goes wrong here is **silent disablement**, and `verify` checks the three
ways it can happen. It runs `generate-advancement-plan`'s own `verify` first and
fails if that fails, because every per-Scout number here comes from it. It then
checks that **every requirement in the imported data is claimed by exactly one
of** a program theme, the closing set, or the individual set — a requirement
claimed by nothing is invisible to the whole analysis, and produces a plan that
reads perfectly with a hole in it. And it checks the one derivation this script
makes for itself, the count of open requirements at each Scout's working rank,
against `generate-advancement-plan`'s own, Scout by Scout.

### 2. Check the badge names against `scout-req`

```
ruby ../import-individual-history/scripts/individual_history.rb badges \
  | ruby ../scout-req/scripts/req.rb check
```

This is the whole-troop version of the check every planning skill runs.
**Exit 3 means stop** for the badges it names: lead the plan with the banner,
say the requirements must come from `www.scouting.org/meritbadges`, and put no
badge session on the calendar for them. A badge merely *changed* for 2026 is not
exit 3 — `req.rb show` prints the updated text, so a session can be planned; say
which year it is quoting.

This matters more here than in an individual plan, because a badge session
sends a dozen Scouts to do the same wrong work at once. **45 of the 95 badges on
the troop's current whole-troop report changed effective Jan. 1, 2026.**

### 3. Check the record is fresh

The header prints the report date and flags the oldest record as `STALE` past 30
days; `attention` repeats it per Scout. Freshness is **per Scout** — a report
run for one patrol does not refresh anyone else. **A stale record does not look
stale in a plan.** It looks like a troop that has not done the work, and
produces a quarter's schedule built around requirements half the troop finished
last month.

## The analysis

### Cohorts, and the banked-work finding

`cohorts` groups every Scout by **working rank** — the lowest rank not yet
complete — and says how many items are left there. Ranks must be earned in
sequence: Scout through First Class "may be worked on simultaneously; however,
these ranks must be earned in sequence" (*Guide to Advancement 2025*, 4.2.0.1,
printed p. 18).

That sequence rule is what makes the **banked-work list the highest-yield
finding in any run.** A Scout with thirty-odd requirements signed above the rank
they are working on is a handful of cheap items away from converting all of it.
Lead the plan with those Scouts, and chain them against `themes` and `clocks` to
say which ranks they can reach and by when. The cohort line also says what is
waiting one rung up (`then 3 to Star`), which is how a Scout clears two ranks in
a season — but see the conference ordering under "Load", because they cannot do
it in one night.

Two things the cohort line reports separately, because they are different
problems: **`waiting on ...`** means the only thing left is an elapsed clock or
a project, so no amount of program time helps and the date comes off `clocks`;
**`N MB slots open`** means merit badges, which is `badges`.

### Themes: what one evening is actually worth

`themes` is the command this skill exists for. It sorts every open requirement
in the troop into a program theme — cooking, knots, first aid, navigation,
aquatics, service — and groups the themes by what it takes to run one: a
**meeting night**, a **campout**, an **outing** (a pool, an orienteering
course), or a **service project**.

Two numbers, and they answer different questions:

- **`signs`** is every sign-off the session could produce, across every unearned
  rank. One cooking campout signs Tenderfoot 2a for one Scout, Second Class 2e
  for another, and First Class 2b for a third — and for a new Scout it can sign
  work at all three ranks at once. This is what the evening is *worth*.
- **`at-rank`** is the subset that counts toward the rank each Scout is working
  on now. Everything else banks until the ranks below it are earned. This is
  what the evening *advances*, and it is the number that decides which court of
  honor a session shows up in.

A theme with a high `signs` and a low `at-rank` is still worth running — it is
the troop banking work — but say so in the plan rather than promising ranks from
it.

**The service theme is the one whose size is knowable**, and it prints the
hours as well as the sign-off count:

```
service        71 signs /   7 at-rank   31 Scouts,  7 at rank
               A troop service project
               29 hours still owed between 7 Scouts at Star or Life,
               of which 7 must be conservation work (3 of them)
```

A sign-off count says how many Scouts a project serves; the hours say how many
mornings it takes. The conservation figure is **not a subtotal** — Life asks for
three of its six hours to be conservation-related, so those seven hours are part
of the twenty-nine and not extra to them. A park cleanup closes both; a food
drive closes only the first, which is why the split is worth booking around.

The hours come back from `generate-advancement-plan`, which gets them from
`import-activities-history` clipped to each Scout's own rank date. That report
is optional: without it the line names the Scouts whose hours could not be
counted and says why, and it does the same for any Scout whose rank predates the
report's date range, because a count there would run short.

**The theme titles are match keys, not a syllabus.** They say a requirement
belongs to an evening; they say nothing about what the requirement asks for.
Before a session goes on the calendar, get the actual text:

```
ruby ../scout-req/scripts/req.rb show tenderfoot
ruby ../scout-req/scripts/req.rb show "first class"
```

### The calendar gap sweep — run it every time

`themes` says what a campout, an outing, or a service project would be *worth*.
Only the calendar says whether one exists. A theme with a hundred sign-offs
behind it and no event on the feed is the single most useful thing this skill
produces, and **it is invisible unless you go looking** — no script will find
it, because deciding whether an event supports a requirement is a reading, not
a lookup. Canoe camping serves First Class 6b/6c/6d and does *not* serve 6a.

So search the troop's feed for each of these, and note which return **nothing**:

| Search the feed for | What it would run |
| :------------------ | :---------------- |
| `camp`, `campout`, `camporee`, `summer camp` | the `campcraft` and `cooking` themes, and Camping 9's nights |
| `swim`, `pool`, `aquatic`, `waterfront` | the `aquatics` theme, which is a pool or a waterfront date and nothing else |
| `orient`, `compass`, `hike`, `trail` | the `navigation` theme |
| `park`, `nature`, `garden`, `trail` | the `nature` theme |
| `service`, `cleanup`, `conservation`, `flag` | the `service` theme, and Citizenship in the Community 7's volunteer hours |
| `merit badge`, `college`, `midway` | the shared badge sessions `badges` names |
| `shed` | every concentrated sign-off session — **count them; there may be one** |
| `court of honor` | the `--by` date every clock in the run is measured against |

Four things about running it:

- **Search a year out, not just the planning window.** "The next one is in
  January" is the finding, and it is a different finding from "there is none".
- **Cross-check each count against the Scouts.** `themes` and `clocks` both name
  who needs the session; a booking that serves twenty Scouts and a booking that
  serves two are not the same request to the committee.
- **A gap is a booking, not a to-do.** It belongs in "Activities to book" and in
  the Advancement Chair's list, never in a Scout's — the Scout cannot fix it.
- **The search terms match the troop's own event names, not requirements.** They
  find candidate events; whether an event actually closes a requirement is a
  reading. Get the text from `scout-req` and check it against what the event
  description says the troop will be doing.

**The `[opportunity]` clocks are what this sweep exists for.** They are the rows
`clocks` deliberately prints with no date, because they are not spans of
calendar at all, and this is where they turn into something schedulable:

- **Camping 9's nights** need campouts, and the count matters — so `clocks`
  prints it: `18 nights short between 3 Scouts`, alongside how many already have
  them. Read that against how many nights the calendar offers before the target
  date. Short by six with two weekends left is a plan that does not close, and
  saying so is worth more than another line of to-dos. The row still carries
  **no date**, because nights are not a span of calendar; a size and a date are
  different claims.
- **Citizenship in the Community 7's volunteer hours** need a specific
  organization, not the troop's own service project. Check `mbc` for a counselor
  in the same pass.
- **Personal Fitness 1's exams are not a troop booking at all.** They are a
  doctor's and a dentist's appointment, so the action is a letter home with
  enough lead time, and it goes in the Advancement Chair's list rather than on
  the calendar. Everything else in that badge is gated behind them.

One thing that is **not** a gap: conferences and boards of review. Whether they
appear on the feed at all is a troop convention — read "How the troop runs
advancement" in `TROOP-SETTINGS.md` before reporting their absence, because in
Troop 400 they are not on the calendar and never were.

### Clocks, rolled up

`clocks` prints one row per clock rather than one per Scout, because that is
where the finding is: nineteen Scouts share a single start-by date for Personal
Management's thirteen weeks. Listing that per Scout produces sixty lines and
buries it; grouped, it is "start it as a group at the September 8 meeting."

The three kinds of clock come straight from `generate-advancement-plan` and are
not interchangeable:

| Tag | What it is | What the plan may say |
| :-- | :--------- | :-------------------- |
| `[work]` | 30 days of *tracked* work — the fitness chain, Personal Management 2, Personal Fitness 7/8, Family Life 3 | a start-by date, from `--start` |
| `[elapsed]` | active participation, position-of-responsibility tenure | a due date, and it is a fact — working harder does not move it |
| `[opportunity]` | Camping's 20 nights, Citizenship in the Community's 8 hours, Personal Fitness's exams | **no date at all** — take it to `troop-calendar` |

Three things to carry into the plan:

- **A `[work]` row with a near start-by is a meeting-night decision.** "Start by
  Sep 15, 19 Scouts" means one announcement at one meeting, not nineteen
  conversations. Say which meeting.
- **An `[elapsed]` row that misses cannot be rescued.** When six Scouts' active
  participation comes due after the court of honor, say so plainly and give the
  date they *can* make. `start-by varies by Scout` on the fitness chain means
  the printed date is the earliest of several — the Scout furthest back sets it.
- **An `[opportunity]` row has no date and must not be given one.** These are
  the rows that turn into calendar bookings, and they are the most useful thing
  in the plan when the calendar has nothing.

### The conference and board load

`load` counts it. "Ready" is a Scout with nothing left but the conference and
the board; "close" is three items or fewer besides. Every Scout needs a
Scoutmaster conference for their working rank; every rank **except Scout** also
needs a board of review (*GTA* 4.2.1.3, printed p. 19), which makes the
Scout-rank cohort the fastest awards available before any court of honor. The
Eagle board is counted apart because it is **not a troop board** — it is
conducted per council policy, usually by the district, and must not be scheduled
into a troop meeting.

The per-meeting figure comes from `TROOP-SETTINGS.md` and is `--per-meeting`'s
default; **check it against that file every run** rather than trusting the
default. Conferences and boards run concurrently, so a night's capacity is
whichever is larger, not the sum — the script does that arithmetic.

Two things `load` does not model, and the plan must:

- **Conferences have their own ordering.** Tenderfoot 10 requires Scout
  requirement 7, Second Class 11 requires Tenderfoot 10, and First Class 12
  requires Second Class 11. A Scout clearing two ranks in a season needs two
  conferences and two boards, in order, on different nights. Cross the
  `then N to <rank>` column in `cohorts` against the nights available.
- **Whether the nights exist.** Take the meeting-night total to
  `troop-calendar` and count the actual meetings in the window. That comparison
  is the finding; the total on its own is not.

### Merit badge work several Scouts share

`badges` prints three lists, and each is a different kind of decision:

- **Eagle-required slots still open**, counted only for Star, Life, and Eagle
  Scouts, because below Star no merit badge is required at all. Ten Scouts short
  the same slot is a group badge session — take the badge to `mbc` for a
  counselor first, because a session with no counselor is not a session.
- **Partials in progress**, with how many are at 80% or better. Nine Scouts at
  80%+ on the same Eagle-required badge is one sign-off session away from nine
  badges, and it is usually the cheapest advancement in the troop.
- **Partials nobody has moved.** This is a *troop* finding rather than a Scout
  one: the same badge idle for the same eighteen months across a dozen Scouts is
  a group that started together and stopped. Decide whether to finish it or write
  it off, and say which. A partial does not expire — it is good until the Scout
  turns 18 — but a requirement *year* that has since changed is a real
  complication, so check the current text before restarting one.

**Every partial carries the requirement year it was started under.** Say which
year, and check it with `scout-req` before a session is built on it.

### Who needs an adult

`attention` ranks Scouts by how much is wrong rather than by how much is left.
The signals, most serious first: **nothing signed, earned, or progressed in
months** — the one thing here the record answers and no per-Scout plan asks, and
usually the most useful line in the run; a Scout approaching **18** who is not
close; **no credited position of responsibility running**, where nothing is
accruing so the earliest finish is a full term after one *starts*; an elapsed
clock that **already misses** the target; a **missing date of birth**, which is
a finding rather than a blank line because it breaks the Eagle application
later; and a **stale record**.

Idle partials are deliberately *not* here — nearly every Scout has one, so
flagging them per Scout buries the four or five who need someone. They are in
`badges`, rolled up by badge.

For any Scout this list surfaces, the next step is their own plan:

```
ruby ../generate-advancement-plan/scripts/plan.rb brief NAME
```

## Troop conventions

**Read all of `TROOP-SETTINGS.md` before writing the plan, not just one
section.** Three of its sections change what the plan says, and two can silently
invalidate output that otherwise looks right:

- **"How the troop runs advancement"** — the SMC/BoR abbreviations, the
  per-meeting cap, sign-off authority, whether conferences and boards appear on
  the calendar (in Troop 400 they do not, so their absence from the feed is not
  a finding), and any recurring sign-off event like "Saturday at the Shed". It
  also settles the Tenderfoot 6b/6c reading, which is what `--tenderfoot-6bc` is
  for.
- **"Advancement Updates"** — requirement changes that postdate the 2025
  printings. These override both the requirements book and the record's own
  marks, and **no script catches them**. Apply them by hand and say in the plan
  that you did.
- **"Scout Updates"** — per-Scout facts the record cannot know. Departures go
  through `--exclude` so every count is net of them; the rest have to be applied
  by hand. **Check every name the plan mentions against this section.** A Scout
  who has decided not to attempt Eagle should not appear in an Eagle-slot push;
  a Scout whose Eagle project is finished and waiting on a council signature is
  not a Scout who needs to start one.

Two things that hold regardless of troop convention:

- Committee members conduct boards of review and "may not test or pass Scouts on
  rank requirements" (*GTA* 4.2.1.2, printed p. 19), so board reviewers must not
  be drawn from the sign-off crew on the same night. Only the Scoutmaster runs
  Scoutmaster conferences. On a night with three boards and three stations
  running, that is a real staffing constraint — name it.
- **The Eagle board of review is not a troop board.** Do not schedule it into a
  troop meeting.

Where the troop's convention collapses the closing three requirements into one
line — "needs an SMC/BoR meeting" — follow it, with the two exceptions
`TROOP-SETTINGS.md` names: Scout rank has no board of review, and at Eagle the
board stays a separate line.

## Working with the other skills

- **troop-calendar** — the real dates, and the single most important pairing
  here. `themes` says what a campout, an outing, or a service project would be
  worth; the calendar says whether one exists. **Run "The calendar gap sweep"
  above every time** — it is the search-term list, the `[opportunity]` clocks
  that have to become bookings, and the rule that a gap belongs to the
  Advancement Chair rather than to a Scout. Also count the meeting nights in the
  window for `load`, and count the Saturdays at the Shed — there may be one.
- **generate-advancement-plan** — one Scout's plan, for anyone `attention`
  surfaces or `cohorts` puts at the front. It is also where every per-Scout
  number here comes from, so a claim in this plan should be checkable against
  `plan.rb brief NAME`.
- **individual-history** — what the record says, before any planning is layered
  on it. Use it to settle a "does the record really say that?" question.
- **scout-req** — the requirement text, and the only thing that knows whether a
  badge is still current. Use it for **every requirement a session is built
  on**. The theme titles here and the labels in the record are TroopMaster's
  abbreviations and this skill's own shorthand; neither is maintained against
  the book, and neither may be quoted as requirement text.
- **mbc** — who counsels a badge, and which badges have no counselor at all.
  Check it before any badge session goes on the calendar.
- **guide-to-advancement** — the policy, with citations: sequence, sign-off
  authority, boards, conferences, and anything about the 18th birthday.
- **eagle-req** — the workbook, for the Eagle project cohort.

State the calendar fact and the advancement implication separately. The calendar
shows something is scheduled, not that a Scout attended or that a requirement
was met.

## Writing the plan

This is a **short plan about the next few meetings and activities**, not a
roster dump and not thirty-eight individual plans stapled together. Lead with
the two or three decisions that change what the troop does, name the dates, and
keep the per-Scout material to the handful of Scouts who need naming.

A good plan has answered: *what goes on the next three meeting agendas, what has
to be booked, what must start this month or miss the court of honor, does the
conference and board load fit, and who is falling through?*

Suggested shape:

1. **Bottom line** — three or four decisions, at most. Name the dates.
2. **Where the troop stands** — cohort sizes by working rank, and the
   banked-work Scouts, who are the shortest path to a court of honor.
3. **The next few meetings** — a theme per night, with the Scouts it advances
   and the conference and board load for that night, no night over the cap.
4. **Activities to book** — the campout, outing, and service themes, matched to
   real calendar events, with the gaps from the sweep called out as bookings to
   make, each with the number of Scouts it would serve.
5. **What must start this month** — the `[work]` clocks with near start-by
   dates, as group announcements rather than per-Scout to-dos.
6. **Merit badges** — the shared Eagle slots and the near-complete partials
   worth a session, with counselors from `mbc`, plus the stalled-partial
   decision.
7. **Scouts who need an adult** — the short list, one line each, with what the
   adult should do.
8. **For the Advancement Chair** — records to correct, positions to appoint,
   counselors to find, events to book.
9. **Notes on the source data** — the report's date, who was excluded and how
   many, anything `verify` or `req.rb check` flagged, and which `--start` and
   `--by` the run used.

Write plans to `plans/troop-advancement-plan-YYYY-MM-DD.md`, **dated from the
report the record came from** (`report_date`, which `troop.rb json` prints), not
from today. Two runs against the same report overwrite; don't invent `-backup`
names. Add a `-SCOPE` suffix only when a run genuinely covers a subset.
`plans/` is gitignored and already present, so there is no `mkdir` step.

Three things to keep honest:

- **Distinguish what the record states from what you are projecting.** Every
  `[work]` date moves with `--start`; say which `--start` the plan ran on, so a
  reader who disagrees knows which numbers to re-read. Projected advancement
  counts are estimates — label them.
- **Say when a cohort cannot realistically make the next court of honor,** and
  give the date they can make instead.
- **When the record cannot answer something, say that it cannot** rather than
  guessing — an `[opportunity]` with no event on the calendar, a missing date of
  birth, a partial under a requirement year that has since changed.

## What this skill is not

- **It is not an individual advancement plan.** It names Scouts, but it does not
  say what any one of them should do in what order. That is
  `generate-advancement-plan`, one Scout at a time.
- **It does not report the record.** `individual-history` does, and a plan that
  disagrees with it is wrong.
- **It does not quote requirements.** `scout-req` does. `THEMES`, `CLOSING`, and
  `INDIVIDUAL_LABELS` in `troop.rb` are **match keys, not a second copy of the
  book** — they exist so a requirement can be sorted onto an evening. Do not
  quote one into a plan, and do not delete them either: the analysis does not
  work without them.
- **It does not decide the calendar.** It says what a session would be worth;
  `troop-calendar` says whether the session exists.

## Privacy

**This repository is public and this skill is about a troop full of minors** —
names, patrols, rank dates, and birthdays.

Plans go in `plans/`, which is gitignored, and the record lives in the importing
skill's `.cache/`. Names are fine in a session, in a plan file, and in an answer
to the Advancement Chair. They never reach a tracked file, a commit message, a
branch name, or a PR description — summarize a change as "regenerate the troop
advancement plan", never by who is in it. The names used in this file are
invented.

## Facts the script depends on

- **Every per-Scout number comes from `plan.rb json`, not from arithmetic of its
  own.** Ladder, banked work, clocks, verdicts, target date, Eagle slots,
  partials, and the service hours are read back from
  `generate-advancement-plan`, one process per Scout, four at a time. **This
  script never opens the participation cache itself**, for the same reason it
  never opens the database: the rank date the hours are clipped to, the
  six-hour threshold, and Life's conservation condition all live one layer down,
  and a troop plan that disagreed with an individual plan about a Scout's hours
  would be worse than one that never mentioned them. That costs a second or two and makes the troop plan and
  the individual plans provably the same analysis. **The one exception** is
  which requirements are open at a given rank — this script needs the `req_id`
  to sort a requirement into a theme, and `plan.rb json` prints labels — and
  `verify` compares that count against `plan.rb`'s own, Scout by Scout.
- **A theme spans every unearned rank, not just the working one.** Counting only
  the working rank makes every activity look half as valuable as it is; counting
  everything and calling it advancement overstates what a court of honor will
  show. Both figures are printed because they answer different questions.
- **The closing three are not a batch opportunity.** Scout Spirit, the
  Scoutmaster conference, and the board of review are open for nearly every
  Scout, so a plain frequency count of open requirements returns them at the top
  and says nothing. `CLOSING` keeps them out of `themes` and feeds `load`
  instead. It matches on `req_id` where TroopMaster prints one, and on the label
  at Star, Life, and Eagle, which number nothing.
- **Neither are the elapsed and project requirements.** Participation, position
  of responsibility, and the Eagle project are clocks and projects, not things a
  meeting can teach. They stay *in* the count of what a Scout has left — a Scout
  whose position is still running is not ready for a board, and calling them
  ready is the one mistake that number must not make — but they are named
  separately on the line, and they are out of `themes`.
- **`verify` asserts coverage in both directions.** Every requirement claimed by
  exactly one of the three tables, and every table entry still present in the
  imported data. A requirement TroopMaster renumbers otherwise drops out of its
  theme in silence, and a theme that has quietly stopped counting anything reads
  exactly like a theme nobody needs. A rank nobody is working on carries no rows
  at all, so that case is a note rather than a failure.
- **An elapsed clock's detail is one Scout's own dates.** The roll-up prints the
  detail line only when every Scout in the group shares it; printing the first
  Scout's dates over a group of eleven is exactly the specific, confident, wrong
  line this command exists to avoid. The same goes for a start-by that varies —
  the printed date is the earliest, and the row says so.
- **Palms are in the record but not on the ladder.** They get no theme and no
  clock arithmetic, and `verify`'s coverage check is scoped to the seven ranks
  for that reason. A palm block otherwise reads as an unclaimed requirement on
  every Life and Eagle Scout.
- **A Scout with no working rank has earned Eagle** and is dropped from the
  cohorts rather than counted as having nothing left.
