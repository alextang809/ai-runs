# Round 6 — native glass UI

## Did

- Drafted a shared native glass surface for the menu, floating capsule/card,
  flyouts, toast, and settings. Tool colors and state labels remain intact.
- Used macOS 26 Liquid Glass with compiler/runtime guards and a macOS 14/15
  visual-effect fallback. Reduce Transparency selects an opaque system surface;
  Increased Contrast adds a stronger neutral edge.
- Added larger header hit areas, softer row corners, menu action symbols, and
  a bounded scrollable settings window. Floating-panel persistence is untouched.
- Rendered real-size light/dark native previews with fictitious sessions using
  only the preview process's own window. No AppModel was initialized.
  The renderer is reproducible with `Scripts/probe/glass-preview.swift`.

## Found

- NSView bitmap caching omits the native glass compositor effect; current-process
  ScreenCaptureKit capture correctly renders the dedicated synthetic window.
- Material-policy regressions passed after their initial RED result. The final
  integration run passed 183 Swift tests. A real native-panel probe
  passed button clicks and text-field focus through the glass layer; the probe is
  saved as `Scripts/probe/glass-interaction.swift`. A synchronous NSEvent XCTest
  harness was discarded because AppKit mouse tracking was unreliable under XCTest;
  no hanging or flaky test was retained. The final optimized Release build passed.
- Swift 6.1/macOS 15 compatibility is guarded in source; hosted dual-platform
  CI has not been run for this unsubmitted UI draft.

## Ideas

- Use regular glass for text-rich outer surfaces and avoid glass per row.
- Keep semantic foreground colors, opaque accessibility fallback, and existing
  tool/state distinctions instead of adding decorative colors.

## Asks

- Native glass preview selected for local installation after review; GitHub submission is a separate step.

## Needs from Alex

- None for local installation: Alex selected the rendered native glass proposal.
  The preview checkpoint from the round-five brief has been satisfied.
