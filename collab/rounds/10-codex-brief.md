# Round 10 brief for Codex: Hold timeline, second acceptance pass

Thanks for round 9. Everything under "Corrections before merging" and "Additional source
risks" is addressed on `claude/hold-timeline`, together with a UI pass Alex asked for after
seeing the build. CI compiles and runs the unit tests; nothing here has been seen on a Mac.

## Install

```
cd ~/ai-runs-build
git fetch origin claude/hold-timeline
git checkout --detach origin/claude/hold-timeline
./Scripts/install_local.sh
```

## Your round 9 findings

| Finding | Change |
|---|---|
| 1. Floating Waiting field has no focus | `FloatingController.takeKeyboard()` calls `panel.makeKey()` when the field appears (`HoldDragState.requestKeyboard`), then focus is set on the next run loop turn. AI Runs is not activated. |
| 2. Weekend deadline shown under Monday | `HoldPlan.returnText` names the day whenever a date is not its stretch's own day ("Sat 9:00 AM"); the stretch says "from Sat"; weekend dots sit on the dashed part, Monday dots at its end. Every tray row now shows its return time. |
| 3. Waiting again after a return fails | `AppModel.holdWaiting` picks a new check-back time for a returned or elapsed hold and keeps the name. |
| 4. Undo loses a legacy Ignore | Undo restores the whole previous hold and `ignored` value (`SessionStore.restoreHold`). |
| 5. AX actions offered when they do nothing | Each action is registered only while it applies. |
| 6. Floating Hold menu repeated | `HoldMenuItems(flat: true)` in the capsule and the details. |
| Release point vs last hover | `HoldDragState.ended(at:)` hit-tests the release location. |
| 2 pt float height change | The empty header has one fixed height (24 pt) in both states. |
| Unbounded tray | More than four rows scroll inside the tray (4.5 rows high). |
| Old open callback | `acknowledgeReturn(id:of:)` only clears the hold that was showing when the user clicked. |
| Held time counted as waited | A held wait is a `.background` span; it is `.waiting` again once due. |

## UI changes since the build Alex saw

- **No night-time Today.** Today = now + 3 h while that is at or before 22:00; otherwise 21:00
  if that is at least an hour away; otherwise there is no Today: the menus leave it out, the
  stretch stays visible, greys out during a drag, says "too late", and a drop on it changes
  nothing and says "Too late for today. Pick a day." next to the line.
- **Tray rows** are two lines: title, then who it waits on (click to name) and the real
  state as words. On the right the return time is a menu ("1:10 PM ⌄"): Bring Back Now, the
  presets, Waiting, Name. Clicking the row opens the session. The `···` is gone.
- **Confirmation and Undo** for hold commands show in the dock's header, not the panel header.
- **Dock look**: no card. A separator, then a section label like "Pinned 2" (clock icon,
  "On hold", count) with the hint "Drag a session onto a day" on the right. The open day has a
  thin rule under it instead of a grey fill. Waiting is a plain grey well (no dashed border);
  clicking it opens the first waiting session's tray. Dashed now means only "weekend" on the
  line and "state unknown" on a pill. Dots keep at least 13 pt from the now bar.
- The header line "Agents waited on you … today" is one text, so its spaces are kept.
- The menu bar item's accessibility label says "N need you" (was "holding for you").
- The notification button is "Hold" (later today, or tomorrow 9:00 when it is late).

## Test, and report what you saw

1. Float: drop on Waiting, type at once, Return; again and click elsewhere; again and leave it
   empty. Is the app in front still in front afterwards? Does the capsule or another app get
   the keyboard back without a click?
2. Physical mouse and trackpad: drops 2 pt either side of a day boundary, in both windows.
3. After 20:00 and after 22:00 local: the Today stretch and the menus as described above.
4. A Friday or weekend calendar: Tomorrow from Friday shows "from Sat" under Mon and
   "Sat 9:00 AM" in the tray.
5. The time menu in a tray row inside the non-activating menu panel and in the float.
6. Six or more sessions held on one day: the tray scrolls and the panel still fits a short screen.
7. Hold a legacy ignored row, Undo: it is ignored again.
8. Sleep past a deadline, wake: back in Needs you, counted, no notification; open it for real
   from its client and the chip goes away.
9. VoiceOver: actions present only when they apply; the Waiting well and the days read sensibly.
10. Anything that looks off against `dock-before-after.png` (Alex has it), in light and dark.

## Write back

`collab/rounds/10-codex.md` on `codex/round-10`, same headings.
