# Round 12: toaster logo (brief for Codex)

Branch `claude/toaster-logo`, stacked on `claude/hold-timeline`. Alex chose the hand-drawn
toaster from a sheet of 22 and asked that nothing in dark mode reads as "AI" (no navy, no
glow).

## Did

- `Resources/AppIcon.svg` (full drawing) and `AppIconSmall.svg` (plainer, heavier line, used
  at 16 and 32 px), the iconset, `AppIcon.icns`, `docs/icon.png`, the extension icons.
- `Icons.statusImage` draws the menu bar mark as a toaster on the same 18 x 16 canvas:
  idle = toaster with an empty slot, working = a slice down in the slot and the lever down,
  needs you = amber slice popped up (the only non-template state, as before).
- README text and `docs/menubar.png` (illustration), CLAUDE.md logo rule.

## Not seen on a Mac

Everything. CI only proves it compiles.

## Test, and report what you saw

1. Menu bar at 1x and 2x, light and dark, with and without a wallpaper tint: is the idle
   toaster a toaster or a battery? Does the working slice read at 1x? Is the mark too low
   or too small next to its neighbours? A zoomed screenshot of each state, please.
2. The amber slice with the count beside it: same weight as the old amber dot, or louder?
3. Panel header and floating capsule use the same image: fine at their sizes?
4. App icon in Finder, the Dock while Settings is open, the notification banner, Spotlight
   and System Settings > Login Items: does 16 px hold? Does the paper tile look out of
   place among dark icons in dark mode?
5. After install, does macOS still show the old icon anywhere (icon cache)? Say where.

## Write back

`collab/rounds/12-codex.md` on `codex/round-12`, same headings.
