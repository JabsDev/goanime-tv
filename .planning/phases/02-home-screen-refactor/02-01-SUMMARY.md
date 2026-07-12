---
phase: 02-home-screen-refactor
plan: 01
subsystem: ui
tags: refactor, extraction, flutter, widget

requires:
  - phase: 01-security-hardening
    provides: SEC-01, SEC-02, SEC-03 (infastructure for refactor safety)

provides:
  - AnilistBanner widget extracted to dedicated file
  - Navigation helpers (openDetail, openFromHistory, openFromFav, openAnilistDetail) as top-level functions
  - Reduced home_screen.dart from 1320 to 1184 lines

affects:
  - plan 02 (extract AnilistLoginDialog)
  - plan 03 (extract ProfileScreen)

tech-stack:
  added: []
  patterns:
    - Feature-private single-consumer widgets stay in `lib/features/home/`
    - Navigation helpers as top-level functions with explicit BuildContext parameter

key-files:
  created:
    - lib/features/home/anilist_banner.dart
    - lib/features/home/home_navigation.dart
  modified:
    - lib/features/home/home_screen.dart

key-decisions:
  - "AnilistBanner stays in lib/features/home/ (feature-private, only used by HomeScreen)"
  - "Navigation helpers are top-level functions (not static methods) for simplicity"
  - "Each function takes BuildContext as first parameter per D-04"

requirements-completed:
  - CODE-01

duration: 2min
completed: 2026-07-12
---

# Phase 2: Home Screen Refactor Summary

**Extract AnilistBanner widget and four navigation helpers from home_screen.dart into dedicated files, reducing the monolith from 1320 to 1184 lines**

## Performance

- **Duration:** 2 min
- **Started:** 2026-07-12T15:36:19Z
- **Completed:** 2026-07-12T15:38:41Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Created `lib/features/home/anilist_banner.dart` — public `AnilistBanner` widget (was `_FocusableAnilistBanner`) with identical gradient, focus animation, and PT-BR copy
- Created `lib/features/home/home_navigation.dart` — four top-level navigation helpers (`openDetail`, `openFromHistory`, `openFromFav`, `openAnilistDetail`) with explicit `BuildContext` parameter
- Updated `lib/features/home/home_screen.dart` to import both new files and use extracted components
- Removed `_FocusableAnilistBanner` class and four `_open*` method definitions
- `flutter analyze` passes with zero errors (zero errors added by this plan)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create anilist_banner.dart + home_navigation.dart** - `aa6b805` (feat)
2. **Task 2: Update home_screen.dart** — replace banner + navigation with imported equivalents - `def80ed` (feat)

## Files Created/Modified

- `lib/features/home/anilist_banner.dart` - AnilistBanner widget (public, was `_FocusableAnilistBanner`), focus-aware gradient banner with "Conectar com AniList" copy
- `lib/features/home/home_navigation.dart` - Shared navigation helpers: `openDetail`, `openFromHistory`, `openFromFav`, `openAnilistDetail`
- `lib/features/home/home_screen.dart` - Updated to import both new files, use `AnilistBanner(onTap:...)` and `open*(context, ...)` at all call sites, removed extracted methods/classes

## Decisions Made

- Followed D-04 from CONTEXT.md: navigation helpers extracted as top-level functions with `BuildContext` as first parameter
- AnilistBanner kept in `lib/features/home/` as feature-private widget (only HomeScreen uses it)
- All function bodies copied verbatim from original `_open*` methods — zero behavior change
- `detail_screen.dart` import retained in home_screen.dart (ProfileScreen still uses `DetailScreen` directly)

## Deviations from Plan

None - plan executed exactly as written.

### Auto-fixed Issues

**1. [Rule 1 - Bug] ProfileScreen reference to DetailScreen broken by import removal**
- **Found during:** Task 2 (Update home_screen.dart)
- **Issue:** Removing `import '../detail/detail_screen.dart'` broke ProfileScreen's `_open` method which still uses `DetailScreen`
- **Fix:** Restored the `detail_screen.dart` import alongside the new imports
- **Files modified:** lib/features/home/home_screen.dart
- **Verification:** `flutter analyze` passes with zero errors
- **Committed in:** def80ed (Task 2 commit)

**2. [Rule 1 - Bug] Missed _openDetail call site for _recent list**
- **Found during:** Task 2 (Update home_screen.dart)
- **Issue:** `replaceAll` only matched `_openDetail(_trending[i])` but not `_openDetail(_recent[i])` (different parameter)
- **Fix:** Applied separate edit for the second call site
- **Files modified:** lib/features/home/home_screen.dart
- **Verification:** All 5 navigation call sites verified with grep
- **Committed in:** def80ed (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both auto-fixes necessary for compilation. No scope creep.

## Issues Encountered

None - execution was straightforward.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Ready for Plan 02-02 (extract `_AnilistLoginDialog` → `AnilistLoginDialog`)
- HomeScreen line count can be further reduced by extracting `_AnilistLoginDialog` (490 lines) and `ProfileScreen` (130 lines)
- PKCE WebView fix (D-03) remains deferred to a separate commit

## Self-Check: PASSED

- Created files: anilist_banner.dart ✓, home_navigation.dart ✓, SUMMARY.md ✓
- Commits: aa6b805 (Task 1) ✓, def80ed (Task 2) ✓, c26befd (SUMMARY) ✓
- flutter analyze errors: 0 ✓
- Acceptance criteria: all verified ✓
- HomeScreen line count: 1320 → 1184 ✓

---

*Phase: 02-home-screen-refactor*
*Completed: 2026-07-12*
