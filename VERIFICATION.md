# Verification session against a real Dyalog interpreter

The test suite runs against a fake server that encodes our *reading*
of the protocol.  This runbook walks every path where that reading is
not yet backed by real-interpreter evidence.  Budget: 45–60 minutes.

Ground rules:

- Fresh scratch workspace; nothing you mind losing.  Use a throwaway
  directory for Link phases: `mkdir -p /tmp/vtest/src`.
- After **every** phase — pass or fail — run
  `M-x ride-apl-transcript-save RET /tmp/vtest/PHASE.eld RET`.
  Passing captures become replay fixtures; failing captures are the
  bug report.  Review for private paths before committing any.
- When a phase fails, note the symptom and move on; phases are
  independent unless marked.
- One code location to adjust is named per phase — divergence should
  be a one-function fix, not archaeology.

Start the interpreter:

 `DYALOG_LINEEDITOR_MODE=1 RIDE_INIT=SERVE:127.0.0.1:4502 dyalog`

and note the exact Dyalog and Link versions (`]VERSION` once
connected) at the top of your notes.

## Phase A — connect and log backfill

`M-x ride-apl-connect`.  Then disconnect, do a few evaluations plus
one error in a second client or restart later, and reconnect so the
log has real history.

Verify: banner and history render **one line per line** — no
everything-on-one-line (the pre-fix symptom), and no doubled blank
lines (which would mean this interpreter *does* embed newlines in
some `ReplyGetLog` entries, contradicting RIDE's client-side `\n`
adding).  Check the log's own shape in `*ride-apl-log:...*`: are
entries strings or `{text,type,group}` objects?

Adjust on divergence: `ride-apl-session--log-entry-effect` /
`--trim-log`.  Capture: `a-connect.eld` (this one is wanted even on
success — we have no real capture of the object form).

## Phase B — multiline session input (LineEditor mode)

In a `dyalog-mode` buffer with `ride-apl-eval-minor-mode`:

    mean ← {        ⍝ Arithmetic mean
        (+⌿⍵)÷≢⍵
    }
    mean 3 1 4 1 5

Select all four lines, `C-c C-c`.

Verify: no `Unpaired brace`; REPL shows the collected definition and
`2.8`; the final line gets a ` ⇒ 2.8` overlay; **no** "unhandled
message" for `SetSessionLineGroup`; the REPL prompt ends up normal
(type 1, six spaces).  Watch the log for the prompt-type dance — we
expect `SetPromptType 3` per collected line; note the actual types
and whether continuation echoes arrive as type 11 or 14 (our capture
skips both, but rendering differences would show as doubled or
missing echo lines).

Also type the same dfn by hand into the REPL to check interactive
collection, and deliberately enter `}` alone to see the error path
(queue should clear, hint message should *not* fire — it's for
origin-tagged lines only... actually verify it doesn't misfire here).

Adjust: `ride-apl-session--input-prefix` (if type-3 lines need
different prefixing), `ride-apl-testsrv--session-execute` (to match
real echo types).  Capture: `b-multiline.eld` — wanted on success.

## Phase C — value tips (eldoc)

With the workspace from phase B, put point on each of: `mean` (a
dfn), a variable (`v←⍳5` first), a tradfn (create one via `)ED` or a
file in phase D), a system name (`⎕IO`), and an undefined name.  Try
in both a source buffer and the REPL input line.

Verify: eldoc shows value for variables, source for functions,
nothing (and no error) for undefined names; nothing hangs — a
never-answered request should just show nothing.  Note the actual
`ValueTip` reply shape in the log: is `tip` an array of lines, and
are `class`/`startCol`/`endCol` present as we assume?

Adjust: `ride-apl-eldoc--format`, fake server's `GetValueTip`
reaction.  Capture: `c-valuetip.eld` — a tip on a *function* is the
single most wanted capture in this document.

## Phase D — Link save cycle (the headline risk)

This is the phase most likely to fail: `⎕SE.Link.Notify`'s argument
shape is doc-derived.  Sequence matters within this phase.

1. `M-x ride-apl-link-create RET # RET /tmp/vtest/src RET`.  Verify
   the REPL shows Link's confirmation, not an error.  If the path had
   spaces, test that variant too (quoting rule unverified).
2. Create `/tmp/vtest/src/twice.aplf` in Emacs:

       r←twice x
       r←2×x

   Save it.  Verify: echo of the Notify line in the REPL, no `VALUE
   ERROR`/`SYNTAX ERROR`, and `twice 21` in the REPL answers `42`.
3. Edit the file (`2×x` → `3×x`), save, verify `twice 21` → `63`.
4. **If step 2 or 3 errored**: in the REPL run `]LINK.Notify -??`
   and try `⎕SE.Link.Notify` variants interactively until one works
   (candidates: bare path, `'file' path` pair, namespace+path).  The
   working incantation goes into
   `ride-apl-link--notify-expression` — one function, then rerun.
5. `M-x ride-apl-link-resync` — verify `]LINK.Resync` is accepted
   as spelled (arity unverified; `-??` again if not).
6. New-namespace case: `mkdir /tmp/vtest/src/util`, create
   `util/half.aplf`, save, verify `util.half 10` → `5`.

Capture: `d-link.eld` — wanted on success (it becomes the fixture
backing the whole `ride-apl-link.el` layer).

## Phase E — navigation and redirect (needs phase D's workspace)

1. In a scratch buffer type `twice 5`, point on `twice`, `M-.`.
   Verify: you land in `twice.aplf` (the real file, not
   `*ride-apl-edit:*`), on a sensible line; `M-,` returns; the log
   shows the `CloseWindow` handshake completing (no window left in
   the interpreter — check with `)ED twice` from another client if
   available, or just confirm repeated `M-.` keeps working).
2. Check the row: for a `.aplf` tradfn, does `currentRow` land you on
   the header or first body line?  Note off-by-one if any
   (`ride-apl-edit--visit-file`, the `forward-line` call).
3. Staleness: `(setq ride-apl-link-notify-on-save nil)`, edit
   `twice.aplf`, save (workspace now stale), `M-.` on `twice` —
   verify the "workspace copy ... differs" warning fires.  Re-enable
   the custom, save again to heal.
4. File-less object: in the REPL define `g←{⍵}` then `M-x
   ride-apl-edit RET g RET` — verify it opens a protocol buffer, and
   `C-c C-c` there fixes back **and** (since `g` has no file) no
   file appears; then define a function via `)ED` if the interpreter
   offers it, to check an interpreter-initiated `OpenWindow` also
   redirects when it carries a filename.

Adjust: `ride-apl-edit--visit-instead-p` / `--visit-file` /
`--stale-p`.  Capture: `e-edit.eld`.

## Phase F — tracer against linked code (needs phase D)

`M-x ride-apl-trace RET twice 21 RET`.  Verify: `*ride-apl-trace:*`
protocol buffer opens (tracer must **not** redirect to the file);
`i`/`o` step; `b` sets a stop; `c` continues; after editing the
function in the tracer and fixing, confirm the change reached
`twice.aplf` on disk (Link workspace→file direction).

Adjust: the `:tracer` guard in `ride-apl-edit--visit-instead-p`.
Capture: `f-trace.eld`.

While the tracer is open, also exercise the line-pointer and thread
commands: `n`/`p` (TraceForward/TraceBackward — highlight moves
without output), `I` (TracePrimitive — does this interpreter accept
it, and at what granularity?), `r` (RestartThreads — harmless with a
single thread?), and `M-x ride-apl-clear-trace-stop-monitor` after `b`
setting a stop — verify the reply's shape (does
`ReplyClearTraceStopMonitor` carry `traces`/`stops`/`monitors`
counts?).  Adjust: `ride-apl-session--cleared-text`,
`ride-apl-proto-clear-trace-stop-monitor`.  Same capture.

## Phase G — rough handling

- `⍳1e9` in the REPL, then `C-c C-c` (weak interrupt): verify it
  interrupts and the session recovers to a prompt.
- Queue clearing: `C-c C-b` a buffer of `x←1`, `1÷0`, `x+1` — verify
  the third line is *not* executed (HadError policy), the error line
  gets a red overlay, and the message about the cleared queue is
  comprehensible.
- Kill the interpreter process mid-session: verify the death notice
  names a reason and buffers stay inspectable (read-only, not
  vanished).

## Wrap-up

Collect into the repo (after review): passing `*.eld` files under
`test/fixtures/` with a line in PLAN.md's verification list flipped
per phase; failing ones attached to issues.  If phases A–C pass
unchanged, delete the corresponding "unverified" hedges from
README's Verification status section — they will have earned it.
