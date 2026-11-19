# How Claude and Codex work together on AI Runs

Two agents, one repo, one person deciding.

Since round 5, Codex owns day-to-day implementation until Alex says otherwise.
The current brief overrides earlier ownership assignments.

| | Claude (cloud) | Codex (on the Mac) |
|---|---|---|
| Sees | the repo, CI, the design canvas | the real Mac: `~/.claude`, `~/.codex`, `~/Library`, running apps, the menu bar |
| Owns | proposals or reviews when requested | `Sources/`, `Tests/`, `Scripts/`, docs, and verification on the Mac |
| Brings | a plan | its own ideas, especially ones that disagree with the plan |

Alex (the owner) decides when we disagree. Decisions go in `DECISIONS.md`.

## Channel

All communication is files in `collab/rounds/`, one note per agent per round:

```
collab/rounds/01-claude.md       Claude's note for round 1
collab/rounds/01-codex.md        Codex's note for round 1
collab/rounds/01-claude-ideas.md sealed: read only after writing your own ideas
```

Every note uses the same five headings, so either side can skim it:

1. **Did** — what you did, in a few lines.
2. **Found** — facts, each with its evidence: a path, a field name, a command and its output trimmed to the relevant lines.
3. **Ideas** — your own proposals. Be bold; say where you think the other agent is wrong.
4. **Asks** — questions for the other agent.
5. **Needs from Alex** — decisions or permissions only Alex can give.

Codex works on branch `codex/round-NN`. Alex approves GitHub submission, merges
to `main`, releases, hook changes, and visible product changes.

## Ground rules

- **The repo is public.** Never commit conversation content, prompts, thread titles, file contents from `~/.claude` or `~/.codex`, tokens, or personal paths beyond `~`. Describe formats with field names and made-up sample values.
- **Read-only outside the repo by default.** The current brief authorizes scoped local signing and installation. Probes may read private metadata, but must not change hooks or rewrite `~/.airuns` data directly.
- **Don't edit `Sources/` in a round unless the brief says so**, so we never fight over the same file. Prototype in `Scripts/probe/` instead.
- **Evidence over guesses.** If you couldn't verify something, write "unverified" next to it.
- **Write ideas before reading the other side's ideas.** Sealed files are marked `-ideas`.
