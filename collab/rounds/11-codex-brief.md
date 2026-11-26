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

**Rows, after Alex saw round 9 again (`1507d60`)**
- `···` and the pin are drawn only while the pointer is on a row (panel and float). They stay
  in the accessibility tree and in the right-click menu.
- "Back from hold" is a plain label like "New reply", not an outlined chip.
- The third line no longer repeats the pill: "Show Threads in Claude to refresh", "Open in
  Claude", "Seen in Claude 3m ago"; no third line for STATE UNKNOWN that Claude never showed.
- No lifeline when nothing was observed. "Worked 3m" moved to the details ("Observed working").
- `**`, backticks, `[text](url)`, heading and quote markers are stripped from prompt titles and
  reply previews. A name the user typed is shown as typed.
- A held row's time menu has a section for its day: Morning 9:00, Afternoon 1:00 PM,
  Evening 5:00 PM (only the ones still ahead). The line still only knows days.

**Rows as glass tiles (`de856aa` and later; Alex picked this from a real-size mock)**
- In the menu panel each run is a tile (`SessionRow`, 54 pt): host icon 30 pt, title over one
  line of activity, and on the right the state pill over its time. "Back from hold" and
  "New reply" lead the second line. A repository overlap warning adds a third line.
- `GlassTile` is drawn (translucent white gradient, hairline edge, hairline shadow), not a
  second Liquid Glass layer. Raised for runs that need the user or work in the foreground,
  quiet for done, background, stale and unknown. Reduce Transparency and Increase Contrast
  have their own fills and border.
- On hover the time gives its place to ×, ··· and the pin.
- The lifeline and its time scale left the list; the details flyout shows the last hour.
- On hold in the menu panel is a quiet tile. The floating window is unchanged.

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
6. Rows: hover in and out quickly; do the controls flicker or steal the click that opens the
   row? Is a pinned row in Needs you still recognisable without the pin?
7. Hold for Thu, pick Afternoon: the tray says "Thu 1:00 PM" and the dot moves.
8. Tiles on macOS 26 Liquid Glass and on the frosted fallback, light and dark, over a busy
   and a plain wallpaper: do they read as panes on the panel, or as grey boxes? Screenshots
   please. Is the raised/quiet difference visible? Any text that loses contrast?
9. Tiles: long titles next to NEEDS INPUT; the hover controls against the pill; dragging a
   tile to a day still starts from anywhere on it.

## Write back

`collab/rounds/11-codex.md` on `codex/round-11`, same headings.
