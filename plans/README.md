# Implementation Plans

Round 1 (plans 001–014) generated 2026-08-02 against commit `3343e77`; all
merged. Round 2 (plans 015–025) generated 2026-08-02 against commit
`83d0b46`. Execute in the order below unless dependencies say otherwise.
Each executor: read the plan fully before starting, honor its STOP
conditions, and update your row when done.

Reconcile pass 2026-08-03 at commit `999913b`: no source changes since the
round-2 plans were written (`83d0b46` + plans commit only), so all eleven
TODO plans are drift-free and executable as written. Round 1 re-verified:
`swift test` 79/79 green.

## Round 2 — execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|------|-------|----------|--------|------------|--------|
| 015  | Make store load failures non-destructive (sweep gate + backups) | P1 | S | — | DONE (merged 2026-08-03, verified on main: 81/81) |
| 016  | Stop merge from destroying unmoved donor attachments | P1 | S | 015 (soft) | DONE (merged 2026-08-03) |
| 017  | Keep failed attachment copies staged in the composer | P1 | S–M | 016 (soft) | DONE (merged 2026-08-03) |
| 018  | Surface note-save failures in the panel | P2 | M | 017 (soft) | TODO |
| 019  | Bound how long the save debounce can defer a write | P2 | S | 018 (soft) | TODO |
| 020  | Make case-only section renames work | P1 | S | 019 (soft) | TODO |
| 021  | Replace off-main-thread NSFontManager with descriptor traits | P1 | S | — | DONE (merged 2026-08-03) |
| 022  | Harden the captured-HTML sanitizer (charset + SVG/background) | P2 | S–M | 021 (soft) | DONE (merged 2026-08-03) |
| 023  | Search matches attachment filenames | P2 | S | — | DONE (merged 2026-08-03) |
| 024  | Cut per-row/per-render O(N) rebuilds in the note list | P2 | M | 023 (soft) | DONE (merged 2026-08-03) |
| 025  | Update check: honest no-releases case + tested comparator | P3 | S | — | DONE (merged 2026-08-03) |

All "soft" dependencies are file-conflict ordering, not logical
prerequisites: 015→020 all touch `NoteStore.swift` (015/016 different
functions than 017–020), 021→022 both touch `MarkdownConverter.swift`,
023→024 both touch `SelectionModel.swift`/its callers. Executing in
numerical order avoids all merge conflicts. Three independent tracks can
run in parallel: {015–020}, {021–022}, {023–024}; 025 is fully independent.

## Round 2 — surfaced but not planned this round

Re-raise in a future round; recorded so they aren't re-audited from scratch:

- **Hotkey monitor doesn't recover from mid-session Accessibility
  revocation** (`AppDelegate.swift:45-67` trust poll self-invalidates;
  `HotkeyMonitor.stop()` has no caller). S–M, MED confidence.
- **Testable-logic extraction batch**: `PasteboardWriter` text building,
  `FloatingPanel.clampToVisibleScreen` rect math, `HotkeyMonitor`
  double-tap state machine. Each S–M; natural bundle with the PanelView
  split round.
- **PanelView split (941 lines) + NSTextField wrapper consolidation**
  (SearchField/HeaderRenameField/ComposerField share ~60% boilerplate;
  NoteRow's inline editor is SwiftUI, not a fourth wrapper). Deferral
  reason (no tests) is gone; seams documented in the 2026-08-02 audit:
  VisualEffectBackground, composer command parser + attachment staging,
  topBar, composer card. L overall.
- **Shortcut definitions drift across three files** despite
  `PanelShortcuts` existing to prevent it (`FloatingPanel.swift:288-355`
  hand-matches ⌘K/⌘F/⌘N/…, `ShortcutsOverlay.swift:41-56` hardcodes display
  strings, `AppDelegate.swift:216-247` re-declares menu equivalents). S–M.
- **Overlay toggling via NotificationCenter round-trip** where
  `SelectionModel.presentedOverlay` already exists for direct writes. S.
- **Deprecated `NSApp.activate(ignoringOtherApps:)` at 5 sites** + stale
  `FloatingPanel.swift:428` / `PanelView.swift:695` comments claiming the
  panel is `.nonactivatingPanel` (contradicted by `FloatingPanel.swift:33`).
  S, needs manual activation testing.
- **CI gaps**: no release-config build / `.app` assembly leg, single
  `macos-14` toolchain, no concurrency cancellation. S.
- **Swift 6 language-mode migration** (tools 5.9 today; mutable statics in
  CaptureHUD/HotkeyMonitor/PanelSettings would need `@MainActor` work). L —
  plan when the platform forces it, not before.
- **UTF-16 offset mix in `MarkdownConverter.rangeAfterListMarker`**
  (`:192-201`, Character distance applied to NSRange). S; only misfires on
  non-BMP list markers.
- **Direction options surfaced 2026-08-02**: Undo for destructive note
  operations (Edit menu already advertises ⌘Z; would subsume a trash-based
  attachment model that also closes plans 015/016's residual loss windows);
  show recorded-but-never-rendered `sourceApp`/`createdAt` provenance in
  NoteRow; document the attachments/Markdown/`# Name` surface (README + ⌘/
  card). Maintainer to pick.

## Round 1 — status (all merged)

All 14 plans merged into `main` and verified there on 2026-08-02 at commit
`83d0b46` (reconcile pass: `swift test` 79/79 green, `ci.yml` present,
CLAUDE.md present; advisor branches deleted after merge).

| Plan | Title | Priority | Effort | Depends on | Status |
|------|-------|----------|--------|------------|--------|
| 001  | Add CLAUDE.md for agent sessions | P2 | S | — | DONE (merged, verified) |
| 002  | Add CI workflow (swift build + test) | P2 | S | — | DONE (merged, verified) |
| 003  | Corruption-recovery & migration tests | P1 | S | — | DONE (merged, verified) |
| 004  | MarkdownConverter test suite | P1 | M | — | DONE (merged, verified) |
| 005  | SelectionModel & PanelActions tests | P2 | M | — | DONE (merged, verified) |
| 006  | Fix ⌘C-fallback clipboard-clobber race | P1 | M | — | DONE (merged, verified; manual GUI pasteboard check from plan Step 3 still owed) |
| 007  | Move debounced save off the main thread | P2 | S | 003 | DONE (merged, verified) |
| 008  | Cache inline Markdown for expanded blocks | P2 | S | — | DONE (merged, verified) |
| 009  | Clean up temp Image.png staging dirs | P2 | S | — | DONE (merged, verified) |
| 010  | Single-pass grouped note filtering | P3 | S | 005 | DONE (merged, verified) |
| 011  | Dedupe NoteRow/PanelActions edit commit | P3 | S | 005 | DONE (merged, verified) |
| 012  | Owner-only permissions on notes.json | P2 | S | 007 | DONE (merged, verified) |
| 013  | Strip remote resources from captured HTML | P2 | M | 004 | DONE (merged, verified) |
| 014  | Validate release URL before opening | P3 | S | — | DONE (merged, verified) |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (with one-line reason) |
REJECTED (with one-line rationale).

## Round 1 dependency notes

- 007 requires 003: the corruption/persistence tests are the safety net for
  restructuring the save path.
- 012 requires 007: both edit the same save function; landing 012 first
  creates guaranteed merge conflicts and re-verification work.
- 010 and 011 require 005: the SelectionModel/PanelActions suites pin the
  behavior those refactors must preserve.
- 013 requires 004 (hard STOP condition in the plan): the converter tests
  are the regression net for changing its HTML input.
- 001/002 are independent but cheap and multiply the value of everything
  after them — do them first.

## Findings considered and rejected

Round 2 additions (2026-08-02, commit `83d0b46`):

- **Lint/format tooling + warning gate** (re-raised by audit): prior
  rejection stands — single-maintainer repo, large mechanical first diff.
  The deprecation warnings that motivated the re-raise are covered by the
  activation-API item in "surfaced but not planned".
- **`Attachments/` subdirectory 0755 window**: parent directory is
  re-chmodded 0700 on every save; sub-second exposure inside `~/Library`.
  Not worth doing.
- **Attachment filename path traversal**: only writable by someone who
  already owns the Application Support directory. Not worth doing.
- **Configurable capture hotkey**: double-Shift is the product identity per
  README; parameterizing is churn without a user pulling for it.
- **Load-time dedupe of duplicate note IDs**: the trap is removed in plan
  024 via a duplicate-tolerant dictionary; store-level dedupe deferred
  until there's evidence of real files with duplicates.

Round 1:

- **Force-cast "crash" in `CaptureEngine.swift:42`**: CF types don't
  participate in Swift's checked casting, so the `as!` cannot trap; no
  observed failure. Not worth doing.
- **Hardened runtime / entitlements in `build-app.sh`**: personal-use,
  locally built app; notarization doesn't apply and hardened runtime adds
  Accessibility re-grant friction per rebuild. Not worth doing now; revisit
  if the app is ever distributed.
- **At-rest encryption of notes.json**: disproportionate for a local
  single-user scratchpad; owner-only permissions (plan 012) is the right
  size.
- **Cloud sync (Copper parity)**: README explicitly positions local-only
  storage as a feature. Settled decision.
- **Lint/format tooling**: one large reformat diff on a single-maintainer
  repo; low value. Revisit if contributors appear.
- **Apple-API deprecation debt**: none found (modern `SMAppService`,
  no deprecated APIs); keep a per-macOS-release manual smoke test of
  capture + hotkeys instead.
- **PanelView split (921-line file) and NSTextField-wrapper consolidation**:
  real debt, MED-risk refactors; deliberately not planned this round —
  selected scope was findings #1–#14. Re-raise after the test suites land.
- **Direction items (Export/Import, attachment Quick Look/remove)**:
  surfaced to the maintainer 2026-08-02; not selected for planning this
  round.
