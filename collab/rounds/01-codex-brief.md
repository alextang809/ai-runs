# Round 1 brief for Codex: make AI Runs match what's really running

## The problem

AI Runs is meant to mirror the AI threads Alex has open. Today it doesn't:

- Since the hooks were installed, AI Runs received events from exactly **one** Claude Code session
  (run inside the Claude desktop app). It got **zero** events from Codex.
- That one session shows under a different name than the one the Claude app's sidebar shows, because
  AI Runs names it from its latest reply. The sidebar name is what Alex recognises.
- Most prompts in that session are wrapped (`<relay from="coordinator">`, `<wake>`,
  `<task-notification>`), so "first prompt" is a weak naming signal too.
- The Claude app shows a step checklist with progress; AI Runs only says "Working 11m".
- The menu bar icon can't be placed in Bartender's shown section.

How it works today: `Sources/airuns-hook` appends hook payloads to `~/.airuns/events.jsonl`;
the app folds them into `~/.airuns/sessions.json` (`Sources/AIRunsCore/SessionStore.swift`).
Only sessions that fire a hook after install ever appear.

## Part A — find out (evidence, not guesses)

These are a floor, not a ceiling. Follow anything interesting.

1. **Menu bar.** macOS version (`sw_vers`), Bartender version, whether AI Runs is in
   System Settings › Menu Bar › Allow in the Menu Bar (and whether it's listed twice),
   and the `NSStatusItem …` keys in `defaults read io.github.alextang809.airuns`.
2. **Claude thread names.** Where does the Claude desktop app store the sidebar title of a
   Claude Code thread, and how does it map to the Claude Code `session_id`? Also check the
   transcript `.jsonl` for any title/summary entries. Field names and file formats only.
3. **Codex threads.** Where do the Codex CLI and the Codex app keep their thread list and
   thread names? How can a reader tell a thread is active, idle, or waiting for approval?
4. **Why Codex sends nothing.** Look at `~/.codex/hooks.json`, `~/.codex/config.toml`, and the
   Codex version. Run one tiny Codex task and check whether a line lands in `~/.airuns/events.jsonl`.
   What exactly would make it work?
5. **Progress.** Where does a step checklist (plan / todo progress) live for Claude Code and for
   Codex, in transcripts or hook payloads, so AI Runs could show "step 2 of 8"?
6. **Other agents.** `~/.copilot`, `~/.github-copilot-cli`, `~/.gemini` exist. Is there anything
   there worth tracking, and how would we read it?

## Part B — your own ideas (write before reading `01-claude-ideas.md`)

If you designed how AI Runs should mirror Alex's threads, what would you do? We want at least one
idea Claude wouldn't have thought of. Anything is fair game: what a "thread" even is, what to show,
what to drop, how to discover threads, how to handle threads driven by other agents.

## Part C — optional prototype

`Scripts/probe/list_threads` (any language that runs on a stock Mac): print the threads you can
find on disk right now, one per line — tool, the name the tool shows, project folder, state, last
activity. No conversation content in the output. If it's good, Claude will port it into the app.

## Deliver

- Branch `codex/round-01`, pushed to `origin`.
- `collab/rounds/01-codex.md` with the five headings from `collab/README.md`.
- Any probe under `Scripts/probe/`.
