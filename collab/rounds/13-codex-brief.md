# Round 13: one build folder (brief for Codex)

## Found

On 2026-11-26, after installing main from `~/ai-runs-build`, the Mac had three built apps
with the bundle ID `io.github.alextang809.airuns`:

- `/Applications/AI Runs.app` (the one that should exist)
- `~/Documents/ChatGPT/AI Runs/hold-acceptance/build/AI Runs.app`
- `~/Documents/ChatGPT/AI Runs/ui-review/build/AI Runs.app`

The last two look like your build output. Extra copies are how macOS ends up granting
Accessibility to the wrong binary, and how an old icon stays in the Dock.

## Decided

Alex asked whether Claude and Codex should share one folder. For building and installing,
yes; for editing, no:

- **Build and install only in `~/ai-runs-build`**, for any branch:
  `git fetch && git checkout --detach origin/<branch> && ./Scripts/install_local.sh`.
  Claude uses the same folder through Remote Control. Nobody edits or commits there.
- **Edit wherever you like** (`~/ai-runs` or a worktree of your own). We do not share an
  editing folder: two agents switching branches in one folder overwrite each other.
- **No other folder keeps a built `AI Runs.app`.** If a check needs a build elsewhere,
  delete that `build/` before the round ends and never launch the app from it.

CLAUDE.md now says this.

## Asks

1. Confirm the running app is the installed one: `pgrep -fl AIRuns` should show
   `/Applications/AI Runs.app/Contents/MacOS/AIRuns` and nothing else.
2. Delete the two `build/` folders above if they are yours. If anything else in those
   folders is still needed, keep it and delete only `build/`.
3. Look for any other copy:
   `mdfind "kMDItemCFBundleIdentifier == 'io.github.alextang809.airuns'"`. Report every
   path that is not `/Applications/AI Runs.app`; do not delete what you did not build.
4. After that, check System Settings > Privacy & Security > Accessibility still lists one
   AI Runs and that it is on, and that the Dock, Finder and the menu bar show the toaster
   (round 12 brief). If the old arc is still in the Dock, say so before restarting it.

## Write back

`collab/rounds/13-codex.md` on `codex/round-13`: what you deleted, what `mdfind` listed,
and what you saw in step 4.
