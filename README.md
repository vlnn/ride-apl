# ride-apl.el

An Emacs client for Dyalog APL using the RIDE protocol: a session
REPL, evaluation from source buffers with inline results, eldoc backed
by live workspace values, interpreter-resolved navigation, editor and
tracer windows, and first-class support for the Link workflow (source
code as text files under git).

Architecture decisions (AD-*) and the milestone plan live in
`PLAN.md`.

## Install

Not on MELPA (yet).  From a checkout:

    (add-to-list 'load-path "/path/to/ride")
    (require 'ride-apl)

or with use-package (Emacs 29+):

    (use-package ride-apl
      :vc (:url "https://github.com/vlnn/ride-apl"))

`dyalog-mode` is recommended but optional (soft dependency).

## Quick start

Start an interpreter that serves RIDE:

    DYALOG_LINEEDITOR_MODE=1 RIDE_INIT=SERVE:127.0.0.1:4502 dyalog -tty

(`Dyalog_LineEditor_Mode=1` enables multi-line session input — without
it a dfn evaluated line by line dies with `SYNTAX ERROR: Unpaired
brace`, in RIDE proper too.  Everything else works without it.)

In Emacs:

    (require 'ride-apl)
    (add-hook 'dyalog-mode-hook #'ride-apl-eval-minor-mode)
    (ride-apl-link-setup-file-modes)   ; .aplf/.aplo/.apln/... -> dyalog-mode

then `M-x ride-apl-connect`.  You get a `*ride-apl:HOST:PORT*` session buffer:
log backfill, prompt gating, one Execute at a time (the queue clears
on error), interrupts on `C-c C-c` / `C-c C-k`, history on `M-p` /
`M-n`, `M-x ride-apl-set-width` for ⎕PW.  Raw protocol traffic stays
visible in `*ride-apl-log:HOST:PORT*`.

Everything below assumes a connected session and
`ride-apl-eval-minor-mode` in your APL buffers.

## Happy path 1: one file

A kata, an experiment, a scratch script — `scratch.apl`, no Link.

Write and poke at code directly:

    range ← {(⌊/⍵)(⌈/⍵)}
    range 3 1 4 1 5

`C-c C-c` evaluates the current line or region through the session.
Results come back as ` ⇒ value` overlays on the evaluated lines
(errors in red), cleared on your next edit; the full untruncated
output is always in the REPL (`C-c C-z` jumps there).  Multi-line
dfns evaluate line by line thanks to `Dyalog_LineEditor_Mode=1`.

When the file grows into a set of definitions, stop evaluating it
piecemeal: `C-c C-l` fixes the whole file with `2⎕FIX'file://...'`
(saving first if modified).  From then on the interpreter knows the
file backs those names, so `M-.` on `range` anywhere — including the
REPL — lands back in *your file* at the definition, and `M-,`
returns.  Eldoc shows the live value of the name at point once it
exists in the workspace.

Iteration loop: edit → `C-c C-l` → rerun the call in the REPL (or
keep a test expression in the buffer and `C-c C-c` it).

## Happy path 2: a directory of files

A real project: `~/proj/src/`, one function per file, git underneath.

    M-x ride-apl-link-create RET # RET ~/proj/src RET

This sends `]LINK.Create # ~/proj/src` (output visible in the REPL)
and registers the directory as a linked root — equivalently, put in
your init or `.dir-locals.el`:

    (setq ride-apl-link-roots '("~/proj/src"))

Now the loop is *save-driven*.  Create `mean.aplf`:

    r←mean x
    r←(+⌿x)÷≢x

Saving it sends `⎕SE.Link.Notify` through the queue and the workspace
picks the change up — no reliance on Link's .NET file watcher (only
dependable on Windows).  Every subsequent save re-fixes the function.
File name = function name; `.aplf` functions, `.aplo` operators,
`.apln` namespace scripts.

Working the loop:

- Run calls in the REPL; `mean 3 1 4` there gets eldoc and history.
- `M-.` on any name jumps into its `.aplf` (the interpreter resolves
  the name, honoring scope; the redirect drops you in the real,
  git-tracked file).  `M-,` back.
- `C-c C-c` still evaluates *expressions* anywhere — handy in a
  scratch buffer next to the sources.  Don't line-eval a function
  file's body; saving is what fixes it.
- Trace with `M-x ride-apl-trace mean 3 1 4`: stepping happens in a
  `*ride-apl-trace:mean*` protocol buffer (`i`/`o`/`u` step, `c`
  continue, `k` cut back, `b` toggle a stop); fixes you make there
  flow back to the file via Link.
- After `git pull`/`checkout`, run `M-x ride-apl-link-resync` — the
  watcher (if any) misses bulk changes.
- If a definition and its file ever diverge, `M-.` warns
  ("workspace copy differs...") instead of letting you edit stale
  source silently.

`C-c C-l` inside a linked root deliberately notifies instead of
`2⎕FIX`-ing — mixing `⎕FIX` into a link corrupts Link's bookkeeping.

## Happy path 3: a directory of directories

An application: the directory tree *is* the namespace tree.

    ~/app/src/
      boot.aplf            -> #.boot
      db/
        connect.aplf       -> #.db.connect
        query.aplf         -> #.db.query
      ui/
        render.aplf        -> #.ui.render

One link at the top covers everything:

    M-x ride-apl-link-create RET # RET ~/app/src RET

Everything from happy path 2 applies per file; what changes is
namespace awareness:

- New namespace = `mkdir` + first saved file.  Saving
  `src/db/pool.aplf` creates `#.db.pool`.
- The REPL follows the interpreter's current namespace: `)CS #.db`
  and unqualified `query` calls work; eldoc and `M-.` resolve
  *through the interpreter*, so they honor `)CS` and scoping rather
  than guessing textually.  From `#.ui`, `M-.` on `#.db.query` still
  lands in `src/db/query.aplf`.
- Cross-namespace search is just search: `project.el`, `rgrep`,
  `magit` over `src/` — one function per file keeps diffs and blame
  meaningful.
- Branch switches touch many files: `M-x ride-apl-link-resync` after,
  always.

Session-defined helpers (typed straight into the REPL) and traced
stack frames have no file; those open as `*ride-apl-edit:NAME*` /
`*ride-apl-trace:NAME*` protocol buffers where `C-c C-c` fixes back and
killing the buffer closes the window cleanly.  That's also the
fallback when you disable the redirect (`ride-apl-edit-visit-files`).

## Knobs

    ride-apl-eval-result-display      overlay (default) / echo / nil
    ride-apl-eval-result-max-length   inline truncation, default 120
    ride-apl-link-notify-on-save      t by default
    ride-apl-link-roots               linked directories (or dir-local
                                  ride-apl-link-root)
    ride-apl-edit-visit-files         file redirect for OpenWindow, default t

Eldoc needs the Emacs 28+ eldoc API.  When no session is connected,
ride-apl's eldoc steps aside so other providers (e.g. gnu-apl-mode's
static docs) take over; a legacy buffer-local
`eldoc-documentation-function` is demoted into the modern hook so it
survives as fallback.

## Verification status

Tested end-to-end against an in-process fake server; the protocol
subset used by the REPL, editor windows, tracer stepping and dialogs
was shaped against captures from a real interpreter (see
`test/fixtures/`).  Two spots still encode documentation rather than
transcripts: the `⎕SE.Link.Notify` argument shape (isolated in
`ride-apl-link--notify-expression`) and `]LINK.Resync`/`]LINK.Create`
argument quoting.  `M-x ride-apl-transcript-save` exports a session for
turning into a replay fixture — captures of one Link save cycle and
one `GetValueTip` on a function are the most valuable ones missing.

## Layout (AD-3)

    ride-apl.el            connect/disconnect, transcript export
    ride-apl-repl.el       session buffer UI
    ride-apl-eval.el       eval-from-source commands + inline results
    ride-apl-eldoc.el      eldoc via GetValueTip
    ride-apl-link.el       linked-directory sync (Notify on save)
    ride-apl-edit.el       editor windows, file redirect, M-.
    ride-apl-tracer.el     tracer UI (dialogs live in the repl layer)
    ride-apl-session.el    pure reducer + effect interpreter (shell)
    ride-apl-proto.el      message constructors/parser (pure)
    ride-apl-transport.el  frame codec (pure) + TCP glue
    test/              ERT suites per layer, fake server, replay driver
    test/fixtures/     .eld transcript fixtures (AD-18)

## Development

    make test       all ERT suites (batch), incl. socket tests against
                    the in-process fake RIDE server
    make compile    byte-compile with warnings as errors

Emacs 28.1+.  Tests are data-table parametrized;
assertions carry "X should Y" context via `ert-info`.

Security note: RIDE is unauthenticated plaintext TCP.  Bind to
loopback; use an SSH tunnel for remote interpreters.

## Contributing

`make test` and `make compile` must stay green; `make lint` is
advisory (checkdoc + package-lint).  The codebase is a pure
reducer/effect core under an imperative shell — new protocol behavior
starts with a pure reducer test, UI behavior with an e2e test against
`test/ride-apl-test-server.el`.  The most valuable contribution needs no
Elisp: run the flagged unverified paths (see "Verification status")
against your real interpreter and attach a `M-x ride-apl-transcript-save`
export — `VERIFICATION.md` is the step-by-step runbook for exactly
that session.  Fixtures recorded against real workspaces should be reviewed
for private data before committing.
