# Session categories: Hold, shown as a timeline

Design only. Nothing here is built. Baseline is `main` at f6a7fd5.
Alex has seen the prototype and said he is happy with it (2026-11-24).

## How to look at it

- `prototype.html` in this folder is self-contained. Open it in any browser:
  `open collab/design/session-categories/prototype.html`.
  The explanation around the mock is in Chinese; the product UI inside the mock is English.
- Pick scheme **C · Hold** and the display **时间线** (both are the defaults).
  Step through with 下一步, or just drag rows with the mouse. The buttons under
  "自己推动时间和状态" move the clock so you can watch held sessions come back.
- Screenshots of the same thing, for when a browser is not handy:
  `day-2-dragging.png`, `day-4-waiting-on-someone.png`, `day-5-back-from-hold.png`, `week-planned.png`.
- Schemes A (Matrix) and B (Lanes) and the displays 四个格子 / 安静 are in the
  prototype only as the alternatives that were turned down. Do not build them.

The mock copies the look of the menu panel (384 pt) and floating window (310 pt)
from `docs/panel.png`, `MenuColumn.swift`, `FloatingWindow.swift` and `RunViews.swift`
by eye. Where the mock and the real views differ in spacing or type, the real views win.

## The idea in three lines

- The user asked for custom categories. What they need is somewhere to put a
  session that wants them **but not now**, and to have it come back by itself.
- Drag up = Pin (exists today). Drag down = Hold until a time, or while waiting on a person.
- A held session leaves Needs you and the menu bar count, and returns on its own.

## On hold dock

**Position is not decided yet.** Two candidates, switchable in the prototype under "时间线放在哪":

- **Top** (menu panel only): under the Need you / Working / Today numbers. Seen
  first, reads as "numbers are now, the line is what comes next", and the drag
  from Needs you is short. It pushes Needs you down by roughly 100 pt, and both
  Pin and Hold targets end up above the list. The tray opens under the line.
- **Bottom**: at the end of the list, above the footer. Needs you stays highest
  and "up is Pin, down is later" is easy to remember. Less visible, longest drag.

The floating window has no numbers area, so there the dock is at the bottom in both cases.
The screenshots in this folder show the bottom position.

| State | What shows |
|---|---|
| Nothing held | One line: clock icon, **On hold**, hint "Drag a session onto the day you want it back". The timeline appears only while a row is being dragged. |
| Something held | Header (clock icon, **On hold**) and the timeline, always visible. |
| A day is opened | A tray between header and timeline listing that day's rows. |

### Timeline

- Left end is **now**, drawn as a short thick bar.
- Segments, left to right: **Today** (about 1.8 times as wide as a day), then each
  remaining weekday through **Fri**, then **Mon** (next Monday). The line into Mon
  is dashed to stand for the weekend. On a Friday or at the weekend there are only Today and Mon.
- Right of the line is an end cap **Waiting** (person icon, dashed outline).
- Each held session is one dot, about 11 pt, in its tool colour (Claude clay,
  OpenAI ink). Waiting on someone is a hollow ring in the same colour.
  At most four dots per day, then "+N".
- Day label is semibold and primary colour when the day has dots, grey when empty.
- Line under the label: Today shows the earliest return time ("1:40 PM"); a day
  with waiting sessions shows the names ("Li, Sam").
- No new colours. The dots reuse the tool colours; everything else is grey.
  Pinned and On hold get an icon and a semibold header because the user arranges
  them; the state groups the app sorts stay as they are.

### Tray (click a day that has dots)

One compact row per session: host icon, title, then the name (waiting) or the
return time (when it differs from the first row), the session's current state
word, and the `···` button. Click the day again to close. Rows in the tray can be
dragged like any other row.

## Actions

| Action | Result |
|---|---|
| Drag a row onto a day | Held until 9:00 that day. |
| Drag a row onto Today | Held until the time under the pointer. The segment spans now to end of day (the later of now + 4 h and 21:00), snapped to 30 min, never sooner than the next half hour that is at least 15 min away. |
| Drag a row onto Waiting | Held as "waiting on someone". Check-back defaults to 9:00 two days later. The tray opens with an inline field (placeholder "who or what"). |
| Drag a dot along the line | Reschedules it. A waiting session stays waiting and keeps its name. |
| Drag a dot or a tray row up onto "Bring back now" | Hold removed. The target appears at the top only while a held session is being dragged. |
| Drag a plain row up onto "Pin to Top" | Same as clicking the pin. |
| `···` on a row | Click path for the same things: "Hold until" Today (+3 h), Tomorrow 9:00, Fri 9:00, Waiting on…; for a held row also "Bring back now". |

While dragging, a small chip follows the pointer (host icon, title) with a live
readout: "Back today 3:00 PM", "Back Thu 9:00 AM", "Waiting on…". In Today a
tick on the line shows where the dot will land.

## Rules

1. A held session is not in Needs you and not in the menu bar count. It is still tracked.
2. When its time comes it goes back to Needs you and is counted, with an outlined
   chip next to the state pill: clock icon "Back from hold", or person icon
   "Check back with Li". The chip goes away when the user opens the session.
3. If a held session asks for approval, the hold ends at once and it shows as a
   normal APPROVE row. Approval never waits.
4. If a held session finishes in the background it stays held and nothing is
   announced. Its current state is visible in the tray.
5. Opening a held session from the tray does not end the hold.
6. Hold takes the place of "Ignore for Now": Ignored becomes On hold, and the
   entry stays where Ignore is today. Ignore waits for new activity that often
   never comes; Hold has a return time. **Alex has not confirmed this swap yet.**
7. Pinned keeps its rules. "Later" (saved replies and notes) is untouched, and
   Hold never uses the word "Later".
8. Defaults are fixed for now, with no settings: +3 h, 9:00 next day, 9:00 Friday
   (next Monday when Friday is less than two days away), check-back after two days.

## Not verified

- Only tried in a desktop browser with a mouse. Never on a Mac, never in the real panel.
- Whether rows can be dragged inside the menu panel at all.
- In the 310 pt floating window a day is about 40 pt wide. It may be too tight.
- Whether half-hour precision inside Today is worth having.
