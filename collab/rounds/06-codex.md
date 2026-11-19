# Round 6 — frosted surfaces and restored menu context

## Did

- Shared native glass and frosted fallbacks cover outer surfaces. macOS 26 uses
  regular material beneath the Liquid Glass rim; macOS 14/15 use visual effects.
  Reduce Transparency is opaque; Increased Contrast adds a neutral edge.
- Restored the selected information-rich menu: Needs you/Working/Today overview,
  two-hour activity chart, readable row activity and observed history bars. Done
  starts expanded and remains collapsible; Ignored starts collapsed. Actual host
  icons and same-repository branch warnings remain visible. Source/project
  subtitles and Pinned stay out of the main menu; pinned notes remain in the
  floating window. The compact footer offers Floating Window, Settings and More.
- Main menu typography uses regular SF weights, with 13.5-point row titles,
  12-point body, 10.5-point state labels and 24-point tabular metric digits.
  Vertical row padding is six points. Reliable plan summaries take priority over
  ordinary activity; raw connector/tool identifiers stay in the flyout. Approval
  requests and input questions get the full activity line. The floating window
  retains its compact session content.
- Bounded the session list and detail flyouts to the menu screen's available
  height. Long content scrolls; short menus shrink naturally. Collapsing a group
  cancels pending flyouts. Floating-panel persistence and focus behavior remain
  unchanged.
- Updated both READMEs and the main menu illustration using fictitious sessions.

## Found

- The full local run passed 199 Swift tests, including readable activity,
  plan-priority and state-evidence regressions, plus existing compact-detail,
  flyout-boundary, pending-hover, material and floating-panel tests. The optimized
  Release build passed.
- Synthetic native checks used the actual menu views with a fake model, never
  the real AppModel. Two working and two completed sessions fit at 549 points;
  24 rows respect a 400-point screen budget with the footer visible. Done starts
  expanded without a test override, folds naturally, and can be reopened. Plan
  text remains readable without competing with a segmented progress bar. Long
  flyouts remain within the screen budget. Light/dark captures and the README
  illustration contain only made-up sessions.
- Existing surface previews and interaction probes remain in Scripts/probe.
  GitHub CI must pass on macOS 15 and 26 for the final PR head before merge.

## Ideas

- Keep the menu focused on sessions and decisions; source metadata belongs in
  details, and pinned notes belong in the floating window.
- Preserve tool colors and explicit unknown/stale labels rather than inferring
  state or progress from timing.

## Asks

- None for the design. Alex selected the restored-information preview after
  reviewing it; local installation remains manual.

## Needs from Alex

- Run the supplied local build/install commands when ready. The restored version
  is not automatically installed. The separate timeline branch is untouched.
