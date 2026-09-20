# ride-apl.el — Plan & Status

Tracks implementation against `ride-apl-el-architecture-2.md`. Legend:
[x] done · [~] partial · [ ] not started.

## Milestones

### M1 — Transport + identity: [x] COMPLETE
- [x] Frame codec, byte-exact, mid-glyph splits (AD-4, AD-15)
- [x] Handshake both orders, `Identify`/`Connect`, `ReplyIdentify`
- [x] `Disconnect`, `SysError`, `UnknownCommand`, `InternalError`,
      `UpdateDisplayName`, `UpdateSessionCaption` (`text` key verified
      against Dyalog 20; caption stored in session)
- [x] Exit criteria: handshake timeout + protocol mismatch die cleanly;
      transcript save/replay round-trips a connect sequence; codec
      tests split inside multi-byte glyphs

### M2 — REPL: [~] core done, corners open
- [x] `Execute` (trace 0), `GetLog`, `SetPW`, both interrupts
- [x] `AppendSessionOutput` with per-type faces; `SetPromptType`
      gating; `HadError` clears queue
- [x] Log backfill: strict log-then-queue, `ride-apl-log-timeout` fallback
- [x] Multi-line queue: one Execute at a time (AD-8)
- [x] Interrupts bypass the queue
- [x] Batched inserts + `ride-apl-repl-max-size` truncation (AD-22)
- [x] Input history ring, `M-p`/`M-n`
- [x] SetSessionLineGroup consumed (retroactive multiline group tags;
      block metadata unused until session block re-editing exists)
- [x] ReplyGetLog entries are newline-less on real interpreters (both
      string and object forms; trailing empty string entry dropped) —
      the fake server had encoded our wrong assumption with embedded
      newlines; fixed there too
- [~] Prompt type 3: queue drains through multiline collection
      (Dyalog_LineEditor_Mode=1) with unprefixed lines, fake-server
      emulated + tested; "Unpaired brace" failures hint at the flag.
      Interpreter-driven rewriting of the REPL input region (true line
      editor / editing collected groups) still open
- [ ] Prompt type 4 (⍞): prompt text as part of the pending line
- [ ] Type-11/14 log backfill into the history ring
- [~] `Execute` trace flags 1/2: flag 1 done (`ride-apl-trace`,
      `ride-apl-trace-line` on `C-c C-t`); flag 2 still open

### M3 — Editor windows: [x] COMPLETE (entityType rendering basic)
- [x] `Edit` (with `unsaved` map from modified buffers), `SaveChanges`,
      `CloseWindow` request/echo handshake
- [x] `OpenWindow`/`UpdateWindow` (same-shape handling), window table
      keyed by `token`, `ReplySaveChanges` err handling, `GotoWindow`,
      `WindowTypeChanged`
- [x] `M-x ride-apl-edit` command; `C-c C-c` fix, `C-c C-q` close in
      editor buffers; dyalog-mode when installed (prog-mode fallback)
- [x] `CloseAllWindows` (`M-x ride-apl-close-all-windows`)
- [x] Dialogs: `OptionsDialog`/`TaskDialog`/`StringDialog` prompt in
      the minibuffer (deferred out of the process filter), replies
      carry index/value/token; `NotificationMessage` -> info notify;
      dismissal (quit) replies -1 / null
- [x] `Edit` pos from point: `C-c C-e` sends the current line and
      cursor column, RIDE-style
- [ ] entityType-aware rendering beyond plain text (arrays, ⎕OR
      objects render as plain lines for now)
- [ ] Dialog shapes unverified against a real interpreter — capture a
      fix-time error transcript when one occurs

### M4 — Tracer: [~] minimal tracer working
- [x] Stepping: `StepInto`/`RunCurrentLine`/`Continue`/`ContinueTrace`/
      `Cutback` on single keys (i/o/c/u/k) in tracer buffers
- [x] `M-x ride-apl-trace` — Execute with trace:1, gated like input
      (warns when busy rather than queueing)
- [x] `SetHighlightLine` -> :highlight-line effect -> moving overlay,
      point follows; 0-based conversion at the UI boundary only
- [x] `SetLineAttributes` both directions; `b` toggles a stop and
      waits for the interpreter's echo before rendering
- [ ] `TraceForward`/`TraceBackward`/`TracePrimitive`,
      `RestartThreads`, `ClearTraceStopMonitor`
- [ ] Stops in the fringe (currently whole-line face); highlight
      column ranges (start_col/end_col honored as whole-line only)
- [ ] Multi-thread tracer windows and focus policy (AD-23)

### M5 — Stack, threads, status: [ ] not started

### Optional/later (autocomplete, ShowHTML, explorer): [~] value tips done
- [x] `GetValueTip`/`ValueTip` with token pairing (first AD-5 token
      user); latest-wins callback slot on the conn
- [x] Eldoc: `ride-apl-eldoc-function` on `eldoc-documentation-functions`
      (depth -90) in `ride-apl-eval-minor-mode` buffers and the REPL;
      claims eldoc only when a session is live, otherwise yields to
      other providers (e.g. gnu-apl-mode's static docs); a buffer-local
      legacy `eldoc-documentation-function` is demoted into the new
      hook so it survives as fallback. Requires the Emacs 28 eldoc
      API; no-op on older eldoc
- [ ] Tip shapes unverified against real Dyalog (capture a transcript)
- [ ] Autocomplete (same token machinery, ReplyGetAutocomplete)

## Architectural decisions

- AD-1 connect-first: [x]; `ride-apl-start` spawns `ride-apl-program`
  with RIDE_INIT=SERVE on a free loopback port and connects when it
  accepts (retry loop, dies cleanly when the process exits or times out)
- AD-2 functional core / imperative shell: [x] `ride-apl-session-step` pure;
  effects executed by registry-based interpreter
- AD-3 layered files: [x] as specified; REPL registers effect handlers
  to keep requires acyclic
- AD-4 pure codec: [x] exhaustively split-tested
- AD-5 reducer keyed on name, no reply pairing: [x] value tips are the
  first token user; pairing lives in the shell (conn slot), reducer
  stays pairing-free
- AD-6 multi-session: [~] conn list + `ride-apl-current-conn`; editor
  buffers carry their conn buffer-locally; REPL-side resolver still
  simplistic
- AD-7 window table in session: [x] records keyed by win-id with
  status/type/text/stops/tid; buffer handles in a shell-side table
- AD-8 no comint: [x] marker-managed plain buffer
- AD-9 reuse dyalog-mode: [~] used when installed; falls back to
  prog-mode with no hard dependency yet (deviation, see below)
- AD-10 async + sync escape hatch: [~] async done; `ride-apl-eval-sync` not yet
- AD-11 interpreter owns windows: [x] Emacs only sends Edit/
  SaveChanges/CloseWindow and reacts; buffers die on the echo
- AD-12 apiVersion isolated in proto: [x] structure in place; no legacy
  (<1) variants recorded yet
- AD-13 testing pyramid: [~] tiers 1–2 running (56 tests: pure tables,
  socket e2e, fixture replay); tier 3 tagged live smoke tests not yet
- AD-14 protocol log always on: [x] structured entries + rendered buffer
- AD-15 binary process, UTF-8 at codec only: [x]
- AD-16 enumerated effects: [x] closed vocabulary, interpreter signals
  on unknown; in use: :send :display-output :set-prompt :focus-repl
  :notify :session-died :open-window :update-window :close-window
  :focus-window :window-saved :show-dialog :eval-result
  :value-tip-reply (plus executor-internal :display-output-batch)
- AD-17 lifecycle/timeouts/teardown: [x] single teardown path,
  handshake+identify timers, tombstone buffers
- AD-18 transcript fixtures: [x] save command, loader, replay driver,
  allowlist filters, state projection; extended with `:event` entries
  so user actions replay deterministically; anonymization deferred (§8).
  Fixtures: `connect-basic.eld` (minimal, shapes verified) and
  `session-m2-real.eld` (real anonymized Dyalog 20.0.53963 capture;
  replay reproduces the recorded outputs byte-identically)
- AD-19 coordinate conversion in one place: [x] records and effects
  carry protocol coordinates; `ride-apl-edit--render` converts currentRow;
  stops pass through untouched (fringe rendering is M4)
- AD-20 buffers die without permission: [x] kill-buffer-hook sends
  CloseWindow, record marked :closing until the echo; raced
  OpenWindow recreates; missing-buffer effects degrade to debug
- AD-21 UpdateWindow vs local edits: [x] interpreter wins; local text
  pushed to kill ring with a warning; Edit carries the unsaved map
- AD-22 output batching/bounding: [x] batching, truncation, SetPW on
  connect + `ride-apl-set-width`; auto-resend on resize deferred (§8)
- AD-24 linked files first: when the interpreter reports a window
  backed by a file, the file is the source of truth: visit it, release
  the protocol window. Protocol buffers serve tracing and file-less
  objects only. Sync file->workspace via explicit Notify rather than
  trusting the .NET watcher
- AD-23 tracer focus/threads: [ ] focus-steal inhibit and tid
  modelines still pending; single-thread tracing works

## Known deviations from the doc

- AD-9 is specified as a hard dyalog-mode dependency; current code
  soft-requires it and falls back to prog-mode so tests run without
  MELPA. Make it hard before first release.

- Effect interpreter uses a handler registry so UI layers register
  handlers at load time (AD-3's file placement kept, requires acyclic).
- Reducer does not emit `(:log ...)` effects; both transcript and
  rendered log are produced at the shell's transport boundary (AD-14
  satisfied, AD-16's `:log` effect unused).
- Fixture `:t` is seconds since session open, not absolute time.
- Fixture format gained `:dir :event` entries (see AD-18 above).
- Real-capture fixtures must be anonymized before commit (Machine and
  User fields in `ReplyIdentify` carry hostname/username).
- The log-backfill timer is cancelled as soon as the backfill
  completes (a real capture showed it firing, harmlessly, seconds
  after `ReplyGetLog`).

### Eval-from-file: [x] done
- [x] `ride-apl-eval-minor-mode` for source buffers: `C-c C-c` line or
      region, `C-c C-b` buffer, `C-c C-l` load via 2⎕FIX file://
      (buffer saved first), `C-c C-z` pop to REPL
- [x] Blank lines skipped; everything flows through the AD-8 queue
- [x] Inline results: origin-tagged pending lines; the reducer captures
      non-echo output between that line's Execute and SetPromptType>0
      (HadError flags :error) and emits :eval-result; UI renders a
      CIDER-style " ⇒ value" overlay at the source line, cleared on
      buffer edit (`ride-apl-eval-result-display`: overlay/echo/nil).
      Full output still lands in the REPL
- [ ] Tradfn (∇) bodies line-by-line — deferred with prompt-type-3
      line-editor work

### Linked-directory workflow (Link): [~] P0+P1 core done
Source of truth for code is a Link'd directory (one function per file);
protocol windows remain for tracing and file-less objects (AD-24).
Workspace->file direction already worked: our SaveChanges path is the
"built-in editor" from Link's point of view.

P0 — file->workspace sync (the .NET watcher is Windows-reliable only):
- [x] `ride-apl-link-after-save` on `after-save-hook` in
      `ride-apl-eval-minor-mode`: files under `ride-apl-link-root` (dir-local)
      or `ride-apl-link-roots` send `⎕SE.Link.Notify` through the queue
      (`ride-apl-link-notify-on-save` to disable)
- [x] `ride-apl-load-file` mechanism-aware: Notify inside a linked root,
      `2⎕FIX'file://...'` outside (mixing ⎕FIX into a link corrupts
      Link's bookkeeping)
- [x] `ride-apl-link-resync` escape hatch (after git pull/checkout, when
      the watcher may have missed changes)
- [x] `ride-apl-link-setup-file-modes`: .aplf/.aplo/.apln/.aplc/.apli/.apla
      -> dyalog-mode (prog-mode fallback)
- [ ] VERIFY against real Dyalog: exact `⎕SE.Link.Notify` argument
      shape (isolated in `ride-apl-link--notify-expression`) and
      `]LINK.Resync` arity; capture a transcript of one save cycle

P1 — navigation:
- [x] File redirect (AD-24): non-tracer `OpenWindow` carrying a
      readable `filename` visits the real file at `currentRow`
      (converted at the UI boundary) and releases the protocol window
      via the normal close handshake; `ride-apl-edit-visit-files` to
      disable; deferred out of the process filter like dialogs
- [x] `ride-apl-goto-definition` on `M-.` in `ride-apl-eval-minor-mode`:
      pushes the xref marker stack (so `M-,` returns) and lets the
      interpreter resolve the name via `Edit`; linked names land in
      their git-tracked file, file-less names in `*ride-apl-edit:*`
- [ ] Full xref backend (definitions sync via `ride-apl-eval-sync`,
      references via file-side search)
- [ ] Namespace listing (`⎕NL` through the queue as a stopgap;
      `TreeList`/`GetAutocomplete` need transcripts first)

P2 (test hygiene fixed alongside: e2e teardown now kills the conn's
editor buffers, so tests no longer leak `*ride-apl-edit:*` buffers):
- [ ] Link status auto-detection (parse `⎕SE.Link.Status` instead of
      configured roots)
- [x] `ride-apl-link-create`: sends ]LINK.Create and registers the root
      (path arg double-quoted when it contains spaces; quoting rule
      unverified against real ]commands)
- [ ] Breakpoints from file buffers via `⎕STOP`
- [x] Staleness guard: redirect compares `OpenWindow` text against
      the file (modulo trailing newline) and warns, suggesting Resync

### Release readiness: [~] mechanical prep done
- [x] Package headers (Version 0.1.0, URL/Author placeholders),
      Package-Requires single-sourced in ride-apl.el, minimum 28.1
      (natnum defcustom types + eldoc API made 27.1 untrue)
- [x] checkdoc: substantive docstring warnings fixed; message-prefix
      capitalization and internal-fn docstrings deliberately kept
- [x] package-lint clean (via make lint, advisory)
- [x] COPYING (GPL-3.0-or-later), .gitignore, GitHub Actions CI
      (28.2 / 29.4 / snapshot)
- [x] Renamed to ride-apl (MELPA's `ride-mode` and Dyalog's RIDE both
      argued against the bare prefix); package-lint clean under the
      new name
- [x] License confirmed GPL-3.0-or-later
- [ ] Fill Author/URL placeholders; tag v0.1.0
- [ ] Run VERIFICATION.md against a real interpreter; turn captures
      into replay fixtures
- [ ] CI workflow is unexercised until first push

## Next candidates

1. Link P0 verification against real Dyalog (Notify shape, Resync)
2. M4 tracer remainder + M5 stack/threads
3. M2 corners: ⍞ and line-editor prompt modes against real Dyalog
4. `ride-apl-eval-sync` (AD-10); tagged live smoke tests (AD-13 tier 3)
