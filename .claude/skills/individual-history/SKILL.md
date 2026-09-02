---
name: individual-history
description: Answer questions about a Scout's advancement record — ranks, requirement sign-offs, merit badges and partials, Eagle-required coverage, leadership tenure, awards — from the imported TroopMaster "Individual History" data.
---

# Individual history

Answer **"what does the troop's record actually say?"** about one Scout, or
about everyone at once, from the database `import-individual-history` builds.

This is the skill to reach for in a Scoutmaster conference, when a parent asks
what their Scout still needs, when the Advancement Chair is deciding who to put
in front of a board of review, or when someone asks which Life Scouts are short
on their position of responsibility.

**It reports; it does not plan.**  It says what is signed off, what is not, how
many months of credited leadership a Scout has, and which Eagle slots are
filled.  It never decides what a Scout should work on next, in what order, or by
when — that is `generate-advancement-plan`.  Keeping the line sharp is what lets
a plan be checked against the record it came from.

It is also strictly a reader: it never writes to the database and never opens a
PDF.  `import-individual-history` is the only writer.

## Tool

`scripts/history.rb` reads
`../import-individual-history/.cache/individual-history.db`.  It needs the
repo's gems (`bundle install` from the repository root) and no PDF tools at all.

```
ruby scripts/history.rb show     NAME               everything the record holds
ruby scripts/history.rb json     [NAME]             the same, machine-readable
ruby scripts/history.rb needs    NAME [--rank R]    what is unsigned for the next rank, or rank R
ruby scripts/history.rb eagle    [NAME]             the 14 Eagle-required slots
ruby scripts/history.rb por      [NAME]             credited months toward the next rank's position
ruby scripts/history.rb roster                      rank, what each is working on, open count, POR
ruby scripts/history.rb who      LABEL [--rank R]   who still has this requirement unsigned
ruby scripts/history.rb badge    BADGE              who earned it, who started it, who has not
ruby scripts/history.rb partials [NAME] [--stalled DAYS]   open partials, most idle first
```

The per-Scout commands (`json`, `eagle`, `por`, `partials`) cover **everyone
imported** when the name is left off, which is usually how a troop-wide question
gets answered.

`NAME` matches `"Rivera, Sam"`, `"Sam Rivera"`, `Rivera`, or `Sam`.  A name that
matches two Scouts is an error naming both, never a guess — an answer given
about the wrong Scout is worse than no answer.

If nothing has been imported the script says so and gives the command to run.

## Start by checking the data is fresh

Every answer here is only as current as the report it came from, and freshness
is **per Scout** — a report run for one patrol does not refresh anyone else.
`roster` prints each Scout's report age and marks anything over 30 days
`STALE`; `show`, `needs`, and `eagle` carry the same note in their header.

A stale record does not look stale in an answer.  It looks like a Scout who has
not done the work — confidently listing requirements they finished last month.
When the note appears, re-run the Individual History report and import it before
answering.

## Reading the answers

- **`[ ]` means the report printed `__/__/__`** — the troop's record positively
  says the requirement is not signed off.  That is different from a requirement
  the report never showed at all, which simply is not there.  Never report the
  second as though it were the first.
- **A rank with nothing listed has been earned.**  The report prints
  requirement blocks only for ranks not yet earned.
- **`N more merit badges` is a count of unfilled slots**, not a named
  requirement.  Which badges fill them is the Scout's choice, within the
  Eagle-required list.
- **`who` spans every unearned rank at once.**  Because the report prints a
  block for each of them, a Scout-rank Scout matches "Position of
  Responsibility" three times — at Star, at Life, and at Eagle.  The rank column
  says which; `--rank Star` narrows it.
- **`partials` reports idle time, not expiry.**  A partial does not lapse on a
  schedule — it is good until the Scout turns 18, though a requirement *year*
  that has since changed is a real complication.  `idle 592d` means nobody has
  recorded progress in that long, which is worth a conversation, not a deadline.

## Eagle coverage is computed from the badge names, not from the star

`eagle` reports the **14 Eagle-required slots**, and three of them are
OR-groups: Emergency Preparedness OR Lifesaving; Environmental Science OR
Sustainability; Swimming OR Hiking OR Cycling.  Any one alternate fills its
slot, so 14 slots are not 14 badges, and counting a Scout's Eagle-required
badges overstates what is left.  The line names whichever alternate the Scout
actually holds.

**Do not answer this question from the `eagle_required` flag in the database.**
That flag is set from the `*` TroopMaster prints beside a badge name, and the
report does not always print it — on the troop's current report Citizenship in
Society appears with a `#` instead, so it is stored `eagle_required = 0` for a
badge that is squarely Eagle-required.  `eagle` matches names against the slot
list for exactly this reason.

## Position of responsibility

`por` answers "has this Scout served long enough yet", and two things about it
are easy to get wrong by hand:

- **Time counts only for the rank being worked on.**  The book reads "While a
  Star Scout, serve actively in your troop for six months."  Service before the
  Scout earned their current rank counts toward the rank it was served under,
  not the next one — so a Scout with years of leadership can legitimately show
  zero months toward Life.  Tenure is clipped to start at their own rank date.
- **Overlapping terms are one stretch of calendar time, not two.**  A Scout
  holding Bugler and Patrol Leader over the same six months has served six
  months, not twelve.  The script merges the intervals.

Positions marked "not credited toward rank" (`#` on the report) are excluded,
and the book agrees: a footnote to Star, Life, and Eagle says assistant patrol
leader is not an approved position of responsibility.

The month thresholds the script prints against (4 for Star, 6 for Life, 6 for
Eagle) are **a threshold, not the requirement**.  Whether a Scout has "served
actively" is a judgment for the Scoutmaster, and the governing text comes from
`scout-req`:

    ruby ../scout-req/scripts/req.rb show "Life"

Questions about *how* the determination is made — what counts as active, what
to do about a Scout who was elected but did not serve — are
`guide-to-advancement`.

## Requirement text comes from elsewhere

The labels this skill prints — `4c. Tell How to Prevent Injury`, `Position of
Responsibility` — are **TroopMaster's abbreviations, not the requirements.**
They are far too short to plan from and are not maintained against the book.
Never quote one as though it were requirement text.

The text that governs comes from `scout-req`, which is the only reader of the
requirements book and the only thing that knows the 2025 printing's limits:

    ruby ../scout-req/scripts/req.rb show "First Class"
    ruby ../scout-req/scripts/req.rb show "Personal Management"

This matters most on partials.  Each carries the requirement **year** the Scout
started under (`Personal Management (2019)`), which is often not the current
one, and 65 of the book's 139 merit badges changed effective Jan. 1, 2026 — so
say which year a partial is under, and check the current text before telling a
Scout what is left.

Who counsels a badge comes from `mbc`; when things are scheduled comes from
`troop-calendar`.

## Privacy

**This repository is public and everything here describes minors** — names, and
on `show` also email, phone, and date of birth.

The database lives in the importing skill's `.cache/` and the report in
`reports/`; `.gitignore` covers both.  Names are fine in a session and in
answers to the Advancement Chair.  They never reach a tracked file, a commit
message, a branch name, or a PR description.  The names used in this file are
invented.

## Facts the script depends on

- **The `eagle_required` flag cannot answer Eagle coverage** — see above.  It is
  displayed, never counted.
- **`EAGLE_SLOTS` duplicates the table in `mbc.rb` on purpose.**  Both are match
  keys against badge names — one for counselor coverage, one for badge
  coverage.  Keep the two in step; neither is a copy of the book.
- **`normalize` must stay identical** to the one in `req.rb`, `mbc.rb`,
  `inventory.rb`, and `individual_history.rb`.  Dropping "and"/"the" is what
  makes TroopMaster's `Citizenship In Nation` resolve against the book's
  `Citizenship in the Nation`, and its `Fly Fishing` against `Fly-Fishing`.
- **Tenure is a union of intervals, clipped to the Scout's rank date** — both
  halves matter, and the troop's current report exercises both.
- **Months are reported as days ÷ 30.44**, to one decimal.  It is a measure of
  elapsed time, not a count of calendar months, and it is there to show whether
  a Scout is close — not to settle a sign-off.
