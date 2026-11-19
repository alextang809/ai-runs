# Round 7 — recorded token usage and managed accounts

## Did

- Added Codex and Claude Code token totals with a rolling 24-hour default, local
  Today and rolling seven-day options, provider details and a usage dashboard.
  Cache reads/writes belong to input; reasoning belongs to output. Unknown usage
  is unavailable or partial rather than a synthetic zero.
- Added a separate background scanner and usage-only atomic cache. Sources stay
  read-only; directory discovery is throttled, reads are budgeted, nested links
  cannot escape selected history roots, and retained events have a global cap.
  Complete-line checkpoints never persist raw transcript fragments.
- Reconciled canonical Codex responses with legacy cumulative mirrors, maintained
  monotonic legacy watermarks, and deduplicated copied parent/child histories.
  Claude cumulative chunks use stable request/message identity and finality.
- Added isolated, named Codex and claude.ai account sign-ins using provider CLIs.
  Each app account has its own private profile; credentials are not imported from
  native homes or browser cookies. Account metadata is separate from local usage.
  Codex plan windows are available; Claude's documented sign-in commands do not
  independently expose quota, so the UI explicitly shows it unavailable.
- Added cancel/reconnect/disconnect/rename and stale-quota handling. New sign-ins
  never inherit old limits. Quitting terminates only registered child processes.
- Added a usage home when no sessions are active, with real account/dashboard
  actions. Unknown conversations stay visible; completed/ignored rows remain in
  Recent Sessions. Active sessions retain the selected typography and layout.
- Updated both READMEs, privacy guidance and fictional native screenshots.

## Found

- Final local Swift regressions passed; exact total and hosted CI are recorded in
  the PR. Optimized Release build and 59 signing-script checks passed.
- New accounting/auth logic has greater than 80% combined line coverage. Tests
  cover duplicate/replayed histories, counter regressions, missing baselines,
  partial lines, file rotation, path isolation, cache limits, time zones, login
  cancellation and metadata-write races. Fake CLI tests validate actual child
  process termination without touching unrelated processes.
- Actual native views with synthetic models passed light/dark, 400-point menu
  budgets including permission notices, multi-account quota separation, and
  bounded dashboard/details checks. No real AppModel was initialized in probes.
- Bounded read-only smoke checks found usable records from both local providers
  and verified 0600 temporary caches. No private records, identifiers or source
  paths are committed; no real sign-in or native credentials were accessed.
- Code/security review findings were fixed and rereviewed. Live provider login
  still requires the user to sign in from Add Account after installation.

## Ideas

- Keep provider-defined account allowance separate from recorded local tokens.
  Connecting an account does not establish ownership of ambient log history.
- Add further providers and documented Claude quota collection as separate work;
  do not infer missing cloud/browser history, spend or quota from token counts.

## Asks

- The user requested a GitHub push and PR for review, explicitly without merging.
  Do not merge this feature until the user asks.

## Needs from Alex

- Review the PR and perform real provider sign-in from the installed app when
  ready. Local installation remains manual; no release tag is created here.
