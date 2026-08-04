---
name: mbc
description: Answer who in the troop counsels a given merit badge, from the TroopMaster "MBC Grouped By Badge" report.
---

# Merit badge counselors

Answer **"do we have a counselor for this badge, and who is it?"** from the
troop's own TroopMaster **MBC Grouped By Badge** report.

This is the question that decides whether a Scout can start a badge this month
or has to wait for the district to find someone.  It comes up constantly — in a
Scoutmaster conference, when a Scout picks a badge off a summer camp list, when
a Life Scout is three badges from Eagle — and the roster changes as adults
register and move away, so it is never answered from memory.

**This skill answers *who counsels*, never *what the requirements are*.**  Those
are different sources: counselors come from TroopMaster, requirement text comes
from the `scout-req` skill.  A badge can have a perfectly good counselor and
still be one the 2025 requirements book cannot answer for (Cybersecurity is
exactly that today) — see "Requirement text" below.

## Tool

`scripts/mbc.rb` parses the report into SQLite at `.cache/mbc.db` and queries
it.  Needs `pdftotext` (`brew install poppler`).

    ruby scripts/mbc.rb verify    [REPORT.pdf]      cross-check the parse — run this first
    ruby scripts/mbc.rb load      [REPORT.pdf] [--force]
    ruby scripts/mbc.rb who       BADGE [BADGE...]  who counsels this badge, if anyone
    ruby scripts/mbc.rb counselor NAME              what a counselor covers
    ruby scripts/mbc.rb badges    [--eagle]         badges the troop covers
    ruby scripts/mbc.rb gaps      [--eagle]         badges with no counselor
    ruby scripts/mbc.rb roster                      every counselor, busiest first
    ruby scripts/mbc.rb info                        what is loaded
    ruby scripts/mbc.rb json

With no `REPORT.pdf`, the newest `*MBC*.pdf` in `reports/` is used.  Queries
load it automatically on first use, and reload on their own when a newer report
appears in `reports/`, so `load` is only needed to force a rebuild.

Ask the user for the report if `reports/` has none.  It is TroopMaster's
**Reports → Merit Badge Counselors → Grouped By Badge**.

## Reading the answer

`who` gives three materially different answers, and the difference matters:

- **A counselor list.**  Give the names and phone numbers.  More than one
  counselor is worth saying out loud — a Scout who cannot reach the first has
  somewhere else to go.
- **"NO COUNSELOR in the troop's list."**  The badge is real and in the
  requirements book; nobody in *this troop* is registered for it.  The Scout is
  not blocked — councils maintain counselor lists well beyond any one troop.
  Say the troop has nobody and that the district or council can supply one; do
  not tell a Scout the badge is unavailable.
- **"is not a merit badge…"**  The name did not match the book *or* the report.
  Usually a misremembered name; the command suggests near matches.

`counselor` takes a name in whatever order it was said — "Jason Holmes" and
"Holmes, Jason" both work, though the report itself stores "Last, First".  A
bare surname returns **everyone** who has it, and the troop currently has two
Holmeses; when more than one person comes back, say so rather than picking one.

`gaps --eagle` is the one to run unprompted when the conversation is about a
Life Scout or an Eagle timeline.  It reports the **14 Eagle-required slots**,
not 14 badges: three of them are OR-groups (Emergency Preparedness OR
Lifesaving; Environmental Science OR Sustainability; Swimming OR Hiking OR
Cycling), and one counselor for any alternate fills the slot.  A slot with no
counselor at all is a real scheduling problem worth raising with the
Advancement Chair.

## Requirement text

**Never quote requirements from this skill.**  It knows badge *names* and who
counsels them, nothing more.  Requirement text comes from `scout-req`, which is
the only reader of the requirements book and the only thing that knows the 2025
printing's limits:

    ruby ../scout-req/scripts/req.rb show "Personal Management"

When `who` prints the "not in Scouts BSA Requirements 2025" note, the counselor
is still correct — TroopMaster is current where the 2025 book is not.  What is
missing is the requirement text, and it must come from
`www.scouting.org/meritbadges`, not from memory.  Say that plainly rather than
supplying 2025 text for a badge that has been revised.

## Privacy

The report names adults and lists their **phone numbers**.  The repository is
public.  `reports/` and `.claude/skills/*/.cache/` are both gitignored, which
covers the PDF and `mbc.db` — keep it that way, and never paste counselor names
or numbers into a tracked file, a commit message, or a PR description.  Giving
them to the Advancement Chair in a session is the whole point; committing them
is not.

## Facts about the report the script depends on

All verified against the 8/3/2026 MBC Grouped By Badge report.

- **`pdftotext -layout` reproduces this report correctly**, unlike the Target
  grids.  It is a flat list, not a grid of rotated headers: badge name flush
  left, counselors indented under it.  There is no bounding-box work to do here.
- **Indentation depth is not stable across pages.**  Counselor lines are
  indented two spaces on some pages and one on others.  What holds is that a
  **badge heading starts at column 0 and a counselor line does not**, and that
  a counselor line carries a parenthesized phone-type code.  Do not key the
  parser on a specific indent width.
- **The phone-type code is the reliable discriminator.**  `(C)` and `(H)` are
  the only ones this report uses; `(W)` and `(B)` are accepted so an unseen one
  cannot silently be read as a badge heading.  A counselor line with no phone at
  all is still kept — as a counselor with no number — and named by `verify`.
- **A form feed precedes each page's first line**, which is the page number
  (`Page 2` … `Page 7`), followed by the repeated title band.  Both are dropped.
  Strip the `\f` first, or the page-number line looks flush left and parses as a
  badge.
- **The run date is the only date on the report**, top left of page 1, in
  `M/D/YYYY`.  It is what dates the data — not the file's mtime.
- **`*` after a badge name is TroopMaster's Eagle-required marker.**  It is only
  ever on a badge the report prints, which is why `EAGLE_SLOTS` exists in the
  script: Citizenship in Society is Eagle-required and absent from this report
  entirely, so no star could tell you the slot is empty.
- **The report lists only badges that have at least one counselor.**  It is not
  a list of merit badges, and a badge's absence means "nobody counsels it," not
  "no such badge."  Telling those two apart is why the script reads the full
  badge list from `scout-req` at load time.
- **TroopMaster's badge names are not the requirements book's names.**  It
  prints "Citizenship In Community" for "Citizenship in the Community",
  "Reptile/Amphibian Study", and "Signs, Signals & Codes".  The script folds
  them with the same `normalize` rule `req.rb` uses, and answers under the
  book's spelling while noting TroopMaster's.
- **One name in this report is already past the 2025 book: Cybersecurity.**
  That is expected, not a parse error — it is what the `scout-req` guard is for.
  `info` lists any such name.

### What `verify` checks, and why

The report prints no tally to check against — there is no equivalent of Target
First Class's "Scouts Needing:" row.  `verify` leans instead on four things the
report's shape guarantees, plus one cross-check between independent sources:

1. **Every badge has at least one counselor.**  A *grouped* report never prints
   an empty group, so an empty one means a heading was invented — the failure a
   stray line would cause.
2. **Badge names run in alphabetical order.**  The report is sorted, so a
   dropped, merged, or invented heading shows up here.
3. **Each counselor's phone number is identical everywhere it appears.**  Names
   repeat under every badge they counsel; a mismatch means two lines were
   misjoined.
4. **Every line carrying a phone code became a row.**  Counted from the raw text
   independently of the parse.
5. **The report's stars agree with `EAGLE_SLOTS`.**  Two independent statements
   of which badges are Eagle-required; a disagreement means the report's marker
   was misread or the table has gone stale against the book.

`load` refuses nothing on its own — **run `verify` before trusting a plan built
on this data**, the same as the other report skills.  `mbc.rb` also checks its
own reading of `req.rb list` against that command's printed entry count, so a
change in scout-req's output format cannot quietly shrink the badge index and
inflate `gaps`.
