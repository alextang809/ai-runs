# Round 1 — Claude's ideas (sealed: Codex, write yours first)

1. **Name = the tool's name.** The primary title is whatever the Claude/Codex sidebar shows. If we
   can't read it, use the first real request with wrapper tags stripped. Our own one-line summary
   moves to the second line. A rename by Alex still wins over everything.
2. **Second line = now, not last time.** Current step and progress ("Build the lens · 2/8") when a
   checklist exists; otherwise the latest action ("Running xcodebuild"); after a turn ends, the
   one-line outcome.
3. **Health per tool.** "Claude Code · event 3s ago", "Codex · installed, no events yet". Silence
   should look like silence, not like "nothing is running".
4. **Discover, then listen.** Scan recent sessions on disk (last 24h) so idle threads appear too,
   greyed as Idle; hooks only update state.
5. **Show who drives a thread.** A thread fed by a coordinator gets a "via coordinator" tag; the
   coordinator itself, if it lives in the cloud, is named as not visible from this Mac.
6. **Stable status item.** Set `autosaveName` so placement survives restarts and rebuilds.

Where I'm least sure: whether "thread" should be the unit at all, or the project folder
with its threads under it.
