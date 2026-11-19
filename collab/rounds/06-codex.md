# Round 6 — frosted surfaces and compact menus

## Did

- Shared native glass and frosted fallbacks cover outer surfaces. macOS 26 uses
  regular material beneath the Liquid Glass rim; macOS 14/15 use visual effects.
  Reduce Transparency is opaque; Increased Contrast adds a neutral edge.
- Simplified the main menu after Alex reviewed the real-size preview: real host
  icon, full-width title, state and duration. Removed visible source/project
  subtitles, the dashboard, per-row history bars and legend. Done and Ignored
  start collapsed. Removed Pinned from the main menu; the floating window keeps
  its Pinned tab. The compact footer offers Floating Window, Settings and More.
- Main menu typography uses regular SF weights, with 13.5-point row titles,
  12-point body and 10.5-point state labels. Vertical row padding is six points.
  Only an actual approval target, input question or current valid plan adds a
  line; ordinary tool activity remains in the hover details.
- Bounded the session list and detail flyouts to the menu screen's available
  height. Long content scrolls; short menus shrink naturally. Collapsing a group
  cancels pending flyouts. Floating-panel persistence and focus behavior remain
  unchanged.
- Updated both READMEs and the main menu illustration using fictitious sessions.

## Found

- The latest full local run passed 195 Swift tests, including new compact-detail,
  flyout-boundary and pending-hover regressions. Optimized Release builds and the
  signing-script suite (59 checks) passed.
- Synthetic native checks used the actual menu views with a fake model, never
  the real AppModel. Two working sessions fit naturally at 259 points; 24 rows
  respect a 400-point screen budget with the footer visible. Reducing the same
  model from 24 rows to two shrinks the window immediately. Done expansion and
  collapse also resize correctly. Light/dark and actionable-detail captures use
  only the preview process's own window and made-up content.
- Existing surface previews and interaction probes remain in Scripts/probe.
  GitHub CI must pass on macOS 15 and 26 for the final PR head before merge.

## Ideas

- Keep the menu focused on sessions and decisions; source metadata belongs in
  details, and pinned notes belong in the floating window.
- Preserve tool colors and explicit unknown/stale labels rather than inferring
  state or progress from timing.

## Asks

- None. Alex approved submission and merge, then refined the compact layout,
  removed the Pinned menu section and requested regular menu font weights.

## Needs from Alex

- Run the supplied local build/install commands when ready. The compact version
  is not automatically installed. The separate timeline branch is untouched.
