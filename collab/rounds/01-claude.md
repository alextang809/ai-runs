# Round 1 — Claude

## Did
Read `~/.airuns` on Alex's Mac (events, sessions, pins) and compared it with a screenshot of the
Claude desktop app. Researched how menu bar managers work on macOS 26 and 27. Wrote the brief.

## Found
- `events.jsonl`: 196 events since install, one `session_id`, tool `claude-code`,
  `env.__CFBundleIdentifier = com.anthropic.claudefordesktop`. Event mix: 176 `PostToolUse`,
  11 `UserPromptSubmit`, 8 `Stop`, 1 `SessionEnd`. No Codex events at all.
- `PostToolUse` tool names seen: `Bash`, `Read`, `Write`, `ToolSearch`, an MCP `send_message`.
  No `TodoWrite`/`Task*` events, even though the app showed a step checklist. So progress comes
  from somewhere hooks don't see, or that tool isn't matched — unverified.
- All 11 prompts start with a wrapper tag (`<relay …>`, `<wake …>`, `<task-notification>`).
- The session's title in AI Runs came from its previous reply, so it lags one turn behind and
  never matches the sidebar.
- The status item has no `autosaveName`, so macOS calls it `Item-0`. Menu bar managers and macOS
  store placement per app + item name (`NSStatusItem Preferred Position Item-0`).
- macOS 26 draws one window per status item; macOS 27 draws the whole menu bar as one window,
  which broke older Bartender. Bartender 6 targets macOS 26, Bartender 7 targets macOS 27. Both
  macOS versions also have a per-app switch in System Settings › Menu Bar › Allow in the Menu Bar.

## Ideas
Sealed in `01-claude-ideas.md` — read it after writing yours.

## Asks
See `01-codex-brief.md`, Part A.

## Needs from Alex
Nothing yet. Codex's findings decide what Claude builds next.

## Update — while Codex investigates (commit cd0873a)
Built the parts that don't depend on Part A, all in `Sources/`:
- `AIRunsCore/Activity.swift`: tool calls → words ("Building", "Editing X.swift"); step lists from
  `TodoWrite` and Codex `update_plan` → `RunProgress`. If Part A finds the checklist elsewhere, say
  where and Claude will read it from there too.
- Names are chosen once instead of following each reply. The tool's own title still wins when
  `TranscriptReader.toolTitle` finds one, so Part A question 2 plugs straight in there.
- `SessionStore.toolLastSeen` and a panel/Settings warning when a tool's hooks are set up but
  silent. Note: Codex's "Review hooks" dialog was the reason Codex sent nothing; Alex approved it.
- `statusItem.autosaveName = "AIRunsStatusItem"`.
Codex: please pull `main` before touching `Scripts/probe/` so your branch builds on this.
