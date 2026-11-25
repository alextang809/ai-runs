# Round 11 brief for Codex: Hold timeline, time rules and type sizes

Small round on top of round 10 (`claude/hold-timeline`). Alex approved these after a
review of type sizes, density and what a time on a day should mean. CI compiles and runs
the unit tests; nothing here has been seen on a Mac. If round 10 is still in progress,
fold these into the same pass.

## Install

```
cd ~/ai-runs-build
git fetch origin claude/hold-timeline
git checkout --detach origin/claude/hold-timeline
./Scripts/install_local.sh
```

## What changed

**Time rules (`HoldPlan`)**
- A hold at 9:00 on a later day is a day hold and reads as the day alone: "Thu", "Mon",
  "Tue 8 Dec" past the line. Any other time keeps day and time ("Wed 1:30 AM").
- Today is now + 3 h rounded up to :00 or :30 ("5:00 PM", not "4:47 PM"), still never
  after 22:00, 21:00 if that is an hour away, otherwise no Today.
- Dates AI Runs picks itself skip the weekend: Tomorrow on a Friday or Saturday is Monday,
  Waiting from Thursday checks back Monday. The same date is offered once in a menu.
  "Fri" (this week) is unchanged. Dropping on a day still means that day.

**Type sizes and density (`HoldViews.swift`)**
- All Hold text is on the app scale; nothing under 10.5 pt. No `minimumScaleFactor`.
- The line is two rows (32 pt) unless some day has something under its name (Today's first
  time, a waiting name, a weekend day such as "Sat" on the dashed stretch, "and later");
  then three rows (47 pt). The height never changes during a drag.
- The open day's sub text is blank: its tray rows say the same.
- "Drag a session onto a day" shows only while nothing is held.
- Waiting well is 44 pt wide (40 in the float), was 50/44.
- Tray titles at body size (12 pt); the return time is a 24 pt high capsule menu in 11.5 pt.
- Float: the return chip says "Back" or the waiting name; the full text is its tooltip.

Picture: `dock-round11.png` (Alex has it).

## Test, and report what you saw

1. Hold something for Thu and nothing else: the line is two rows; the tray says "Thu ⌄";
   the hint is gone.
2. Hold something Today: the sub row appears with the time on :00 or :30; open Today and
   its sub is blank.
3. Fake a Friday clock if you can (or wait for one): Tomorrow lands on Monday, the menu
   offers it once.
4. Is 12 pt in the tray too quiet next to the 13.5 pt rows above? Is the capsule clear as a
   control in light and dark?
5. Float at its narrowest: day labels, Waiting, the compact chip next to a pill.

## Write back

`collab/rounds/11-codex.md` on `codex/round-11`, same headings.
