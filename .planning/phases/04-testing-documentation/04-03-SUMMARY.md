---
phase: 04-testing-documentation
plan: 03
subsystem: testing
tags: flutter, integration-test, mocktail, docs

# Dependency graph
requires:
  - phase: 04-testing-documentation
    provides: 04-01 unit test infrastructure, scraper smoke test probe pattern
provides:
  - Search → detail → playback end-to-end integration test
  - AGENTS.md Testing section documenting unit and integration test commands
affects: release phase (CI/CD integration test setup), future developer onboarding

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Probe-pattern integration tests: single AnimeRepository, debugPrint logging, assertions at each stage"
    - "AGENTS.md Testing section: four-command reference (unit, single file, single integration test, all)"

key-files:
  created:
    - integration_test/search_detail_playback_test.dart
  modified:
    - AGENTS.md

key-decisions:
  - "Inserted Testing section between Project Structure and Workflow (preserves logical grouping: project overview → testing → workflow → architecture)"
  - "Integration test searches 'naruto' as the canonical probe query (same as scraper_smoke_test.dart e2e probes)"
  - "Used simplified section headers (===== SEARCH =====) instead of PROBE-prefixed headers for tighter run-log grouping"

patterns-established:
  - "Integration test probe pattern: global AnimeRepository, single testWidgets with 5-min timeout, debugPrint section headers, non-empty assertions at each stage"
  - "AGENTS.md section placement: Build & Run → Project Structure → Testing → Workflow → Architecture Notes"

requirements-completed: [CODE-04, TEST-02]

# Metrics
duration: 5min
completed: 2026-07-13
---

# Phase 4 Plan 3: Integration Test & Docs Update Summary

**Search → detail → playback integration test and AGENTS.md Testing section**

## Performance

- **Duration:** 5 min
- **Started:** 2026-07-13T20:18:00Z
- **Completed:** 2026-07-13T20:23:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Created `integration_test/search_detail_playback_test.dart` covering the full user flow: search ('naruto'), episode listing, and video source resolution — following the established probe pattern from `scraper_smoke_test.dart`
- Added `## Testing` section to `AGENTS.md` documenting unit test commands, integration test commands (single file, all), and `mocktail` mocking dependency
- All 72 existing unit tests pass with zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Create search_detail_playback_test.dart** - `b079640` (test)
2. **Task 2: Append Testing section to AGENTS.md** - `4f12885` (docs)

**Plan metadata:** pending final commit

## Files Created/Modified
- `integration_test/search_detail_playback_test.dart` - On-device integration test: search 'naruto' → episode listing → video source resolution with assertions at each stage and 5-minute timeout
- `AGENTS.md` - Added ## Testing section (unit test + integration test commands, mocktail reference). 93 lines total, well within 100-line limit. All original sections preserved.

## Decisions Made
- Inserted Testing section between Project Structure and Workflow (natural flow: what's in the project → how to test it → how to work on it → architecture details)
- Used 'naruto' as probe query (consistency with scraper_smoke_test.dart e2e probe block)
- Used simplified `===== SEARCH =====` / `===== EPISODES =====` / `===== PLAYBACK =====` section headers for tight, readable test run logs

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. The integration test requires a connected Android device or emulator (same as existing integration tests in the project).

## Next Phase Readiness

- Integration test coverage expanded with search → detail → playback end-to-end flow
- AGENTS.md now documents testing commands for developer orientation
- Ready for Phase 5 (release) planning

---

*Phase: 04-testing-documentation*
*Completed: 2026-07-13*
