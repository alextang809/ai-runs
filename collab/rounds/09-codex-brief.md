# Round 9 brief for Codex: try the Hold timeline on the Mac

Claude built the Hold timeline that Alex approved in round 8, on branch
`claude/hold-timeline` (from `codex/token-usage` at `04da81b`). CI compiles it and runs
the unit tests on macOS 15 and 26. Nobody has seen it on a Mac yet. You own the on-Mac
acceptance pass; Claude owns the feature files. If something needs a code change, write
it under Found with the file and line, or push a fix to `codex/round-09` and say so.

Read first: `collab/design/session-categories/README.md` on `claude/session-categories-design`
(the approved design and "Changed after Codex's review"), then this brief.

## Install

```
cd ~/ai-runs-build
git fetch origin claude/hold-timeline
git checkout --detach origin/claude/hold-timeline
./Scripts/install_local.sh
```

## What was built

- **Store** (`Sources/AIRunsCore/Hold.swift`, `SessionStore.swift`): `Session.hold`
  (deadline `until`, optional `waitingOn`, `heldAt`, `returnedAt`). Kept separate from
  the real state. Commands: `hold`, `reschedule`, `setWaitingName`, `bringBack`,
  `acknowledgeReturn`, `reconcileHolds(now:)`. A row waiting for approval can't be held;
  an approval event ends a hold. Held rows survive SessionEnd and `pruneStale` like
  pinned rows, and move with an executor onto its project thread row. Remove cancels
  the hold, and Undo restores it. Holding clears an old `ignored` flag. Rows ignored by
  earlier versions keep their Ignored section and get "Stop Ignoring".
- **Count rule**: `Session.needsUser`. Held = not counted; due = counted and in
  Needs you, whatever the real state, until opened. Menu, floating badge, menu bar
  count and the header all read it.
- **Due**: `reconcileHolds` runs at launch, every 30 s tick, on panel open (`refresh`)
  and on `NSWorkspace.didWakeNotification`. Opening through `Jumper.open` with
  success clears "Back from hold"; opening before due keeps the hold. A user prompt
  typed into a returned session also clears it.
- **Notifications** (`AlertPlanner`): a hold withdraws the alert and the 15 min reminder,
  coming due posts nothing, and the same wait is not announced after the hold ends.
  The notification button "Ignore" became "Hold 3 Hours" (old delivered "Ignore"
  buttons hold too). Snooze 15m is unchanged.
- **Dates** (`HoldPlan`): Today = now + 3 h; a day = 9:00; Waiting = check back 9:00 two
  days later; menu presets Today (+3 h), Tomorrow 9:00, Fri 9:00 (next Mon when Friday
  is under two days away). Unit tests cover weekend, midnight, time zones and DST.
- **UI** (`Sources/AIRunsApp/HoldViews.swift`): `HoldDock` at the bottom of both
  surfaces, above the footer, outside the scrolled list. In the menu it is part of the
  footer's height budget. Empty: one dashed line with the hint; while a row is dragged
  the line rises **over** the end of the list (overlay), so the panel doesn't resize under
  the pointer. Tray opens on a day click. Waiting's "who or what" field opens in the
  window where the drop happened.
- **Drag**: `SwiftUI DragGesture` (min 6 pt) on each row as a simultaneous gesture, in a
  named coordinate space per window; drop targets report frames via a preference. No
  pasteboard, so the board's drop handler never sees it. Approval rows have the gesture
  switched off. Hover details are frozen during a drag. Escape cancels the drag first
  (both its own key monitor and the panel's Escape monitor), then details, then the panel.
  The row's click right after a drag is swallowed (`consumesClick`, 0.3 s).
- **Click paths**: row right-click "Hold Until ▸" / "Bring Back Now"; menu flyout
  "Hold Until…" (NSMenu at the pointer) and "Bring Back Now"; floating window hover
  capsule "Hold" (was "Ignore") and its details; tray row `···`. VoiceOver actions:
  "Hold Until Tomorrow 9:00 AM", "Bring Back Now".
- **Floating window widths**: on a Monday, Today narrows to a day's width so every day
  is at least 40 pt. Alex is choosing between this and the prototype's wider Today
  (`float-monday-widths.png` in the project files).

## Test, and report what you saw

Use the real menu panel and floating window, with another app frontmost, mouse and
trackpad. Report counts and behaviour only; no titles, prompts or ids.

1. Drag a Needs you row onto a day, onto Today, onto Waiting, in both windows. Centre
   and edge drops at day boundaries. Does the row's click ever fire after a drag? Does
   the panel resize or jump during a drag? Do hover details stay hidden?
2. Scroll the list, then drag from a row that was scrolled into view.
3. Escape in the middle of a drag: nothing changes, panel stays open. Drop outside any
   target: nothing changes.
4. Drag up onto "Pin to Top"; drag a tray row or a held row up onto "Bring back now".
5. Waiting: does the field get focus in the floating window (it is a non-activating
   panel)? Typing a name, Return, clicking elsewhere, leaving it empty.
6. Approval rows: no drag, Hold Until disabled; a held row that asks for approval comes
   back at once and alerts.
7. Coming due: hold one for Today, change the Mac's clock or wait; also sleep the Mac
   past a deadline. It returns to Needs you with "Back from hold", counts in the menu
   bar and capsule, and posts no notification. Open it: the chip goes away.
   Open a held row from the tray before it is due: it stays held.
8. The flyout's "Hold Until…" pop-up menu inside the non-activating panel.
9. VoiceOver on a row: the two actions.
10. Legacy: if any row still has `"ignored": true` in `sessions.json`, it shows under
    Ignored with Stop Ignoring.

If drag proves unreliable in the menu panel, say so: the menus already call the same
commands, and the drag can be switched off there alone.

## Write back

`collab/rounds/09-codex.md` with Did / Found / Ideas / Asks / Needs from Alex,
on `codex/round-09`.
