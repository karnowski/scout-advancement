---
name: eagle-req
description: Answer Eagle Scout service project questions — proposal, plan, fundraising, report, approvals — from the Eagle Scout Service Project Workbook.
---

# Eagle Scout service project workbook

Answer questions about the Eagle Scout service project — what the four forms
ask for, what a proposal has to show, who approves what and in what order, what
fundraising needs an application, what goes in the report — from the **Eagle
Scout Service Project Workbook, No. 512-927, revision 2023a**
(`references/EagleProjectWorkbook2023a.pdf`), quoting the text that supports the
answer and citing the workbook's own page label.

**Never answer from memory.** This is the most-mythologized requirement in
Scouting: "you need 100 hours," "it has to leave something built," "the troop
approves the plan," "the beneficiary signs last," "anything involving a business
is out." Every one of those is wrong or badly oversimplified, and every one gets
repeated confidently by adults who have been around a long time. Quote the
workbook, which addresses all five directly.

## Scope — and what belongs to another skill

The workbook is the **form and the process**: the five tests, the fields, the
signatures, the fundraising standards, the beneficiary handout. Three
neighbouring questions belong elsewhere:

- **How advancement is administered** — the Eagle board of review, the Eagle
  Scout Rank Application, appeals, time extensions, what happens after the
  project — is the *Guide to Advancement*, via `guide-to-advancement`. See
  "Where the Guide overrides this workbook" below; it is not optional.
- **The text of requirement 5, or of any rank or merit badge requirement**, is
  `scout-req`:

      ruby ../scout-req/scripts/req.rb show "Eagle"

  The workbook quotes requirement 5 on Page 3, but that is a 2023 reprint of it.
  Quote the requirement from `scout-req`, which reads the current book and is
  loud when a printing cannot answer.
- **Which Scouts in the troop still need a project, and by when** is
  `target-eagle`; real dates for a work weekend come from `troop-calendar`.

The workbook is also silent on everything local: who the district's project
approval representative is, whether the council requires a fundraising
application under some dollar threshold, who serves as project coach. It says
plainly that councils and districts may set limited local procedures. Route
those to `TROOP-SETTINGS.md` if it records them, and otherwise say the answer is
local and name who to ask.

## Where the Guide overrides this workbook

**The workbook is February 2023; the Guide to Advancement is 2025.** Page 4's
"What an Eagle Scout Candidate Should Expect" and the whole of Page 5 are
excerpts and summaries *of the Guide*, and each names the Guide topic it was
taken from:

    Page 4   what a candidate should expect          9.0.2.1
    Page 5   project coaches                         9.0.2.9
    Page 5   "give leadership to others"             9.0.2.4
    Page 5   evaluating the project after completion 9.0.2.13
    Page 5   risk management                         9.0.2.14
    Page 5   insurance                               9.0.2.15

When a question lands on one of those, **quote the workbook for what the form
requires and read the Guide for the policy**, because a 2023 summary of a 2025
policy manual is exactly where a stale answer comes from:

    ruby ../guide-to-advancement/scripts/gta.rb section 9.0.2.9
    ruby ../guide-to-advancement/scripts/gta.rb toc --section 9

Where the two disagree, the Guide governs and the answer should say so. Where
they agree, citing both is stronger than citing either.

The Guide's `9.0.2.0`–`9.0.2.16` also cover ground the workbook does not, and
those are worth reaching for unprompted: `9.0.2.12` addresses common
misconceptions about the project, and `9.0.2.16` covers Messengers of Peace,
which the 2023a workbook predates entirely.

The drift is real and visible: the workbook says a project must "benefit an
organization other than the Boy Scouts of America," where the Guide's own
heading for the same rule now reads "Benefit an Organization Other Than
Scouting America." Quote the workbook as printed — do not silently modernize
text inside quotation marks — but name the rename when it matters.

## Tool

`scripts/eagle.rb` decodes the workbook and searches it. It builds its cache on
first use. **No poppler needed** — unlike the other reference skills, this one
is pure Ruby, because this PDF has to be decoded by hand (see below).

    ruby scripts/eagle.rb verify                      cross-check the decoding — run this first
    ruby scripts/eagle.rb toc                         every page with its workbook label
    ruby scripts/eagle.rb search PATTERN [--context N] [--max N] [--part NAME]
    ruby scripts/eagle.rb page LABEL [--to LABEL]     "Proposal Page D", "Page 3", or a PDF page number
    ruby scripts/eagle.rb part NAME                   front, proposal, plan, fundraising, report, navigating, revisions
    ruby scripts/eagle.rb build [--force]

`page` is forgiving about the label: `"Proposal Page D"`, `"proposal d"`, and
`11` all reach the same page.

**Run `verify` before quoting from a fresh clone or after touching the script.**
The text layer of this PDF is broken in a way that deletes letters silently, and
the decoder that repairs it is this skill's whole foundation — see "Facts about
the workbook the script depends on."

## Citing

The workbook restarts its page numbering in every part, and cites *itself* that
way — "page B of the fundraising application," "as stated on page 3 of this
workbook." So do that: **cite the part and the lettered page**, e.g.
*Proposal Page A, "Meeting the Five Tests of an Acceptable Eagle Scout Service
Project"*. Every command prints the label, along with the PDF page number to
hand to the Read tool if you need to look at the page image.

## What is on which page

    Page 2             How to use the workbook; the four forms; "only the official
                       workbook may be used"; the note to unit/district/council reviewers
    Page 3             Meeting Eagle Scout Requirement 5 — purpose, choosing a project,
                       restrictions and other considerations, collecting service project data
    Page 4             Message to Scouts and Parents or Guardians; what a candidate
                       should expect
    Page 5             Excerpts from the Guide — project coaches, "give leadership to
                       others," evaluating after completion, risk management, insurance

    Proposal Page A    Instructions: the five tests; working with the beneficiary
    Proposal Page B    Contact information
    Proposal Page C    Project description and benefit; planned start and finish
    Proposal Page D    Giving leadership; materials; supplies
    Proposal Page E    Tools; other needs; permits and permissions
    Proposal Page F    Preliminary cost estimate; fundraising; project phases; logistics
    Proposal Page G    Safety issues; project planning
    Proposal Page H    Candidate's promise; the four approvals and their order

    Project Plan A     Proposal review comments; changes from the proposal; present condition
    Project Plan B     Phases; work processes; attachments; permits
    Project Plan C     Itemized materials, supplies, tools, other needs with costs
    Project Plan D     Expenses and revenue; the giving-leadership chart; logistics
    Project Plan E     Tools, hours, food, restrooms; safety, hazards, PPE, first aid
    Project Plan F     Contingency plans; project coach's comments

    Fundraising A      The application form
    Fundraising B      Procedures and Limitations on Eagle Scout Service Project Fundraising

    Project Report A   Execution dates; description; observations; changes
    Project Report B   Leadership; materials; the service-hours data table
    Project Report C   Funding summary; photos; candidate's promise; final approvals

    Navigating 1–2     "Navigating the Eagle Scout Service Project" — the handout for
                       the beneficiary, to be given at the first meeting
    Revision Tracking  Revision history, 2021a through 2023a

## Answering

Structure the answer as:

- **The direct answer**, in a sentence or two.
- **The supporting text, quoted verbatim**, with enough around it to carry the
  reasoning — the sentence that decides the question plus any that qualifies it.
- **The citation**: part and page label, e.g. *Fundraising Application Page B,
  standard 1*.
- **What is required versus what is a form field.** These are not the same, and
  conflating them is how units invent requirements.

Two things to be actively loud about, because both come up constantly and both
are places where units add requirements the workbook forbids:

- **The proposal is approved; the project plan is not.** Page 2 is explicit
  that no one approves the plan, though the beneficiary may review it and
  require changes, and the plan is strongly encouraged rather than mandatory.
  A unit that requires its own sign-off on the plan is adding a requirement.
- **The workbook is the whole form.** Page 2 states that no council, district,
  unit, or individual may produce or require additional forms, add or change
  requirements, or alter the workbook. Quote that whenever a question starts
  "our troop also asks Scouts to…".

When the workbook does not answer something, say so plainly, and distinguish the
three cases: the workbook answers it; the *Guide* answers it and the workbook is
only summarizing (go to `guide-to-advancement`); nobody national answers it and
the decision is local (name the council or district advancement chair).

## Facts about the workbook the script depends on

All verified against `references/EagleProjectWorkbook2023a.pdf`, 32 pages,
February 2023.

- **The text layer of this PDF is broken, and it fails silently.** `pdftotext`,
  `pdftohtml`, and pdf-reader's own decoding all *drop* letters rather than
  garbling them. Requirement 5 comes out of every one of them as "W ile a i e
  Scout la evelo a give lea er i to ot er…". The output still reads as prose and
  still quotes cleanly, so nothing downstream can catch it. **This is the reason
  the skill exists as a script instead of an instruction to read the PDF.**
- **The cause is incomplete ToUnicode CMaps.** Eleven Identity-H (CID-keyed)
  Arial subsets are embedded; eight of them map only some of the glyph IDs they
  use, and an unmapped CID is dropped. The loss falls hardest on italic and
  heading text — which is where requirement 5, the boxed notices, and most
  section titles live, so the damage concentrates in exactly the passages worth
  quoting.
- **The repair is `CID = ASCII − 29`**, applied only to Type0 Arial fonts. Every
  Arial subset here numbers glyphs in the standard Macintosh ordering, so CID 3
  is space, 36 is "A", 68 is "a". This is measured, not assumed: across the
  eleven CMaps, 251 mappings covering 65 distinct CIDs all obey it and none
  disagree. `verify` re-derives that from the PDF every run.
- **The rule must not be applied to the other fonts.** The Symbol CID font uses
  a different glyph order (its CID 118 is a bullet; in the Arial order 118 is an
  accented i), and the simple WinAnsi TrueType fonts are byte-encoded and
  already correct. Widening the rule would turn missing letters into *wrong*
  letters, which is worse than the bug.
- **One glyph could not be recovered from the file and was read off the page.**
  CID 171 is mapped by no CMap in the workbook; it is the ellipsis in Page 5's
  heading, `Give Leadership to Others …?`, and occurs exactly once.
- **The PDF is encrypted and slightly damaged** — the 2023a revision's own
  changelog says "Repaired Security Settings" — and at least one object fails
  AES decryption, so `ObjectHash#each` raises partway through. Font objects are
  fetched one at a time. Page content is unaffected.
- **Page labels are the citation scheme, and each part restarts them.** Front
  matter is numbered (Page 2–4), then Proposal Page A–H, Project Plan Page A–F,
  Fundraising Application Page A–B, Project Report Page A–C. Section covers,
  the two blank pages, the beneficiary handout, and the revision page print no
  label at all; the script assigns those synthetic names and `verify` checks the
  other 22 against the footer the page actually prints.
- **The workbook contradicts itself about where the parents' message is.** Page
  2 twice says "pages 5 and 6"; it is actually on Page 4 and the unnumbered page
  after it, which is what Proposal Page H says ("on page 4"). The revision
  history shows three other page references being corrected in 2021c, so treat
  the printed cross-references as fallible and check with `search`.
- **Side-by-side boxes interleave.** The four approval blocks on Proposal Page H
  and the approval row on Fundraising Application Page A are table cells, and
  come out line-by-line interleaved. All the text is there and the interleaving
  is obvious rather than silent, but **read the page image with the Read tool
  before quoting those blocks** — `page` prints the PDF page number for exactly
  this.
- **The form pages are mostly field labels, and that is the content.** "What
  does the proposal ask for?" is answered by the labels on Proposal Pages B–G,
  not by prose. Quote them as the questions they are.
- **The workbook is set justified, and the extraction keeps the visual gaps**,
  so prose comes out with runs of spaces between words ("Send  the  completed
  form  with  any"). Collapse whitespace when quoting; it is layout, not
  wording. Exactly one word in the workbook is broken across a gap — `projec
  t.` in the hours footnote on Project Report Page B — so a search for a phrase
  that comes back empty is worth retrying with `\s*` between the letters before
  concluding the text is not there.

### What `verify` checks, and why

The workbook prints no tally or index to check a parse against, so `verify`
attacks the one thing that can actually go wrong here — the decoding:

1. **32 pages.** Any other count is a different revision, and every page label
   and extraction fact above was established against this one.
2. **The glyph-order rule holds.** Re-reads all eleven Arial CMaps out of the
   PDF and fails if any mapping contradicts `CID = ASCII − 29`, or if two fonts
   disagree about a CID. This is the assumption the whole decoder rests on.
3. **Every CID used in the document resolves.** A CID that is neither mapped nor
   covered by the rule is still being dropped, and names itself here.
4. **The 22 printed footers match the labels the script assigns.** A structural
   cross-check of the script's page map against the document's own numbering.
5. **Ten canary passages are intact** — one from each part carrying prose, each
   chosen because it is mangled without the repair, none crossing an interleaved
   box.
6. **No dropped-glyph signature remains.** It extracts the workbook a second
   time with the repair switched off and counts runs of stranded single letters
   in both: 44 with the repair off, 0 with it on. This is the check that would
   catch a regression the canaries happened to miss, and it reports what the
   repair is worth rather than only that nothing is currently wrong.
