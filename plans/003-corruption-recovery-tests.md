# Plan 003: Test the NoteStore corruption-recovery and legacy-migration paths

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/`
> If `NoteStore.swift` changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

"Defensive persistence… corruption recovery" is a README selling point, but
the recovery code paths have zero tests: only the happy-path round-trip is
covered. If `moveCorruptFileAside` regresses (loses the user's original file
instead of backing it up, or fails on a pre-existing `.bak`), real users lose
data and nothing catches it. These are pure-logic paths with an injectable
file URL — cheap to lock down.

## Current state

- `Sources/Nickel/Store/NoteStore.swift` — the store. Key excerpts as of the
  planned-at commit:
  - `NoteStore.init(fileURL: URL? = nil)` (line 36) accepts an injectable
    file URL; tests already use this.
  - `load(from:)` (lines 501-530): missing file → empty store; unreadable
    data → `moveCorruptFileAside(url)` + empty store; then tries the
    version-2 `StoredEnvelope` decode, then a legacy bare `[Note]` array
    decode (migrating sections via `distinctListNames`), and only if both
    fail → `moveCorruptFileAside(url)` + empty store.
  - `moveCorruptFileAside(_:)` (lines 559-570): moves the file to
    `notes.json.bak` in the same directory, removing any existing `.bak`
    first.
  - `repaired(notes:sections:activeSection:)` (lines 548-557): appends any
    note's `listName` missing from `sections`, and nils an `activeSection`
    that names an unknown section.
- `Tests/NickelTests/NoteStoreTests.swift` — the exemplar. Its `setUp`
  creates a temp dir + `NoteStore(fileURL:)`; follow that pattern exactly
  (see lines 9-23). Existing persistence tests: `testPersistenceRoundTrips`
  (line 284) and `testDecodingNoteWithoutAttachmentsKeyIsBackwardCompatible`
  (line 298).
- Encoder/decoder use `.iso8601` dates; envelope fields are
  `version`, `sections`, `activeSection`, `notes` (see `StoredEnvelope`,
  lines 488-493).

## Commands you will need

| Purpose | Command      | Expected on success       |
|---------|--------------|---------------------------|
| Build   | `swift build`| exit 0                    |
| Tests   | `swift test` | all pass (26 existing + new) |

## Scope

**In scope**:
- `Tests/NickelTests/NoteStoreTests.swift` (add tests only)

**Out of scope**:
- `Sources/Nickel/Store/NoteStore.swift` — this plan adds tests for current
  behavior; if a test reveals a bug, STOP and report rather than changing
  production code.

## Git workflow

- Branch: `advisor/003-corruption-recovery-tests`
- One commit, imperative message (e.g. "Add corruption-recovery and legacy-migration tests").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add corruption tests

In `NoteStoreTests.swift` under a new `// MARK: - Corruption recovery`
section, add:

1. `testCorruptFileIsMovedAsideAndStoreStartsEmpty` — write garbage bytes
   (e.g. `Data([0xFF, 0x00, 0x12])`) to `fileURL`, construct
   `NoteStore(fileURL: fileURL)`, assert `notes`/`sections` are empty,
   `notes.json.bak` exists in `tempDirectory`, and the original `fileURL` no
   longer exists.
2. `testCorruptFileOverwritesExistingBackup` — pre-create
   `notes.json.bak` with known content, write invalid JSON (e.g.
   `"{not json"`) to `fileURL`, construct the store, assert `.bak` now holds
   the invalid JSON (the newer corpse), not the old backup content.
3. `testUnparseableJSONObjectIsTreatedAsCorrupt` — write valid JSON that is
   neither an envelope nor a `[Note]` (e.g. `"[1, 2, 3]"`), construct the
   store, assert empty store + `.bak` created.

**Verify**: `swift test --filter NoteStoreTests` → all pass.

### Step 2: Add legacy-migration and repair tests

1. `testLegacyBareArrayMigratesSectionsInFirstAppearanceOrder` — write a JSON
   array of two note objects (use the JSON shape from
   `testDecodingNoteWithoutAttachmentsKeyIsBackwardCompatible`, line 299,
   giving them `"listName": "B"` then `"listName": "A"`), construct the
   store, assert `sections == ["B", "A"]` and `activeSection == nil`.
2. `testEnvelopeWithUnknownActiveSectionResetsToNil` — save a store, then
   rewrite the file's JSON replacing `activeSection` with a name not in
   `sections` (or hand-write a version-2 envelope JSON), reload, assert
   `activeSection == nil`.
3. `testEnvelopeWithNoteInUnlistedSectionAppendsSection` — hand-write a
   version-2 envelope where a note's `listName` is absent from `sections`,
   reload, assert the section was appended.

**Verify**: `swift test` → all pass, total test count ≥ 32.

## Test plan

The steps above are the test plan. Model structure and naming after the
existing `NoteStoreTests.swift` (plain XCTest, temp-dir fixtures, one
behavior per test).

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0 with ≥ 6 new tests covering both corruption and
      migration/repair paths
- [ ] `git status` shows only `Tests/NickelTests/NoteStoreTests.swift`
      modified (plus the plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any new test fails because production behavior differs from the "Current
  state" description (e.g. `.bak` not created, original notes lost) — that is
  a real bug; report it, do not change `NoteStore.swift`.
- The `load(from:)` / `moveCorruptFileAside` code no longer matches the
  excerpts.

## Maintenance notes

- Plans 007 (background save) and any future storage-format change must keep
  these tests green — they are the contract for the recovery behavior.
- Reviewer: check tests assert on *files on disk* (`.bak` existence/content),
  not just in-memory state.
