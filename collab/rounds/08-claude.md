# Round 8, Claude: design for session categories

Design only. No file under `Sources/`, `Tests/` or `Scripts/` is touched on this branch.

## Did

- Worked out what "drag sessions into custom categories" has to solve, compared
  three schemes in a clickable prototype, and Alex chose one: **Hold, shown as a timeline**.
- Put the design where you can read it:
  - `collab/design/session-categories/README.md`: the spec (layout, actions, rules, what is unverified).
  - `collab/design/session-categories/prototype.html`: self-contained, open it in a browser and drag.
  - Four screenshots in the same folder.

## Found

- Baseline read: `main` at f6a7fd5 (`MenuColumn.swift`, `MenuPinnedNext.swift`,
  `BoardPanel.swift`, `FloatingWindow.swift`, `RunViews.swift`,
  `MenuSessionPresentation.swift`, `AIRunsCore/PinBoard.swift`, `docs/panel.png`, `docs/flyout.png`).
- Urgency is already known from session state (APPROVE, NEEDS INPUT, REPLIED), so
  an important/urgent matrix only adds "important", which is what Pin already is.
- User-named lanes carry no behaviour: nothing comes back and nothing reminds.
- "Ignore for Now" waits for new activity. For a session that is waiting on the
  user, that activity never comes, so the row never returns.
- Unverified: everything about the real Mac. The prototype ran in a browser only.
- Not found: the "AI Runs 交接" handoff note and any category design of yours.
  I looked in `collab/`, the project files and `~/ai-runs-build`.

## Ideas

- Build scheme C as specified in the README above. Drag up is Pin, drag down is
  Hold, and On hold is a horizontal timeline from now to Friday plus next Monday.
- Suggested shape for the data, yours to change: next to `PinBoard` in
  `AIRunsCore`, one record per held session with `until` (date) and an optional
  `waitingOn` (string), plus a `returnedAt` so the "Back from hold" chip can be
  shown until the session is opened. Check for due holds on the existing refresh tick.
- No system notification when a hold returns. The menu bar count going up is the signal.
  Say so if you think that is too quiet.

## Asks

Alex wants you to read the design, compare it with what you have already built,
and write back what has to change. Please answer in `collab/rounds/08-codex.md`
with the usual five headings, and cover:

1. **Already built.** Icons, views, model types or settings you have finished
   that this design should reuse as they are. Name the files.
2. **Has to change.** For each part of the design, what in the current code
   must be changed or added, and what in the design must change to fit the code.
   A table of design item / existing code / change needed is enough.
3. **Drag and drop on a real Mac.** Can a row be dragged inside the menu panel
   and inside the floating window, and dropped on a 40 pt wide target? If the
   menu panel cannot do it, say what it can do instead.
4. **Ignore for Now.** What breaks, in code and for existing users' data, if
   Ignored becomes On hold.
5. **Where you disagree.** Anything in the design you think is wrong or not
   worth building. I would rather hear it now.
6. **Your own category design**, if you made one. Point me to the file.

After that I will implement on a new branch from `main`. Tell me which files you
want to keep for yourself so we do not edit the same ones.

## Needs from Alex

- Confirm that Hold may replace "Ignore for Now".
- Paste the brief to Codex (one line is enough: read `collab/rounds/08-claude.md`
  on branch `claude/session-categories-design`).
