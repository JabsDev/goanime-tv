---
phase: 02-home-screen-refactor
plan: 03
subsystem: ui
tags: flutter, home-screen, profile-screen, refactor, extraction, navigation
requires:
  - phase: 02-home-screen-refactor
    provides: HomeScreen fields/methods structure, AniList login dialog, AnilistBanner, home_navigation helpers
provides:
  - ProfileScreen extracted as standalone widget with history/favorites display
  - Final ~400-line HomeScreen (catalog browsing + AniList user state only)
  - !mounted guards for async lifecycle safety
affects: []
tech-stack:
  added: []
  patterns:
    - Private helper functions consolidated inline in _buildContent
    - Async lifecycle guards after every await in stateful widget async methods
key-files:
  created:
    - lib/features/home/profile_screen.dart
  modified:
    - lib/features/home/home_screen.dart
key-decisions:
  - "Used openFromHistory/openFromFav from home_navigation.dart instead of inline _open() in ProfileScreen"
  - "Compressed _buildContent with local section() helper to reduce repetitive ListView builder boilerplate"
requirements-completed:
  - CODE-01
duration: 15min
completed: 2026-07-12
---

# Phase 2 Plan 3: ProfileScreen Extraction & Final HomeScreen Trim Summary

**ProfileScreen extracted to standalone file; HomeScreen trimmed to 387 lines with !mounted guards and clean imports**

## Performance

- **Duration:** 15 min
- **Started:** 2026-07-12T15:35:00Z
- **Completed:** 2026-07-12T15:50:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Extracted `ProfileScreen` (history + favorites display) from `home_screen.dart` into its own file with `openFromHistory`/`openFromFav` navigation helpers
- Trimmed `home_screen.dart` from 689→387 lines (catalog browsing + AniList user state only)
- Added `!mounted` guards after every `await` in `_checkAnilist()` and `_showAnilistLogin()` for async lifecycle safety
- Removed unused `import '../detail/detail_screen.dart'` and verified no unused import warnings in touched files
- Compressed verbose methods: `_buildTopBar` (73→32 lines), `_showAnilistMenu` (69→20 lines), `_buildContent` (152→82 lines with local helper)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create profile_screen.dart** - `ab6361a` (feat)
2. **Task 2: Final trim of home_screen.dart** - `42e17d8` (feat)

## Files Created/Modified

- `lib/features/home/profile_screen.dart` (129 lines) — `ProfileScreen` with history ("Assistidos") and favorites ("Favoritos") display, using `openFromHistory`/`openFromFav` from `home_navigation.dart`
- `lib/features/home/home_screen.dart` (387 lines) — Final `HomeScreen` with catalog browsing, AniList user state, trending/popular/history/favorites sections, `!mounted` guards

## Decisions Made

- Used `openFromHistory`/`openFromFav` from `home_navigation.dart` instead of inline `_open()` method (reduces duplication — same logic already exists)
- Compressed `_buildContent` with a local `section()` helper that returns `List<Widget>` to eliminate repetitive `ListView.builder` + `SectionHeader` boilerplate across the 4 horizontal sections
- Removed `../detail/detail_screen.dart` import since all detail navigation now goes through `home_navigation.dart` functions

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Compressed verbose methods to meet 430-line max_lines constraint**
- **Found during:** Task 2 (Final trim)
- **Issue:** After extracting ProfileScreen (133 lines), `home_screen.dart` was at 559 lines, exceeding the plan's 430-line max_lines constraint. File needed ~130+ more lines trimmed to reach ~400-line target.
- **Fix:** Compressed `_buildTopBar` (73→32 lines), `_showAnilistMenu` (69→20 lines), `_loadAnimeLists` (29→12 lines), `_buildContent` (152→82 lines) using inline children, single-line styles/constructors, and a local `section()` helper to deduplicate ListView section patterns
- **Files modified:** `lib/features/home/home_screen.dart`
- **Verification:** Line count dropped from 559→387 (within 380-420 target). `flutter analyze` passes with zero errors.
- **Committed in:** `42e17d8` (Task 2 commit)

**2. [Rule 2 - Missing Critical] Fixed `_section` helper return type for compile correctness**
- **Found during:** Task 2 (verification)
- **Issue:** Local `_section` helper returned `Widget` but call sites used `.children` getter, causing `undefined_getter` compile errors
- **Fix:** Changed return type to `List<Widget>`, removed `.children` calls, removed unused `w` parameter, renamed to `section` (no underscore for local)
- **Files modified:** `lib/features/home/home_screen.dart`
- **Verification:** `flutter analyze` now passes with zero errors
- **Committed in:** `42e17d8` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 missing critical)
**Impact on plan:** Both fixes were necessary for the file to compile correctly and meet the line-count constraint. No scope creep — no changes to visual behavior or file structure.

## Issues Encountered

- None — the extraction was straightforward. The only challenges were the line-count compression and the initial type error in the `_section` helper, both addressed in the auto-fixes above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 2 (CODE-01) complete — all 5 extraction files exist and compile independently:
  - `lib/features/home/home_screen.dart` (387 lines)
  - `lib/features/home/anilist_login_dialog.dart` (501 lines)
  - `lib/features/home/profile_screen.dart` (129 lines)
  - `lib/features/home/anilist_banner.dart` (99 lines)
  - `lib/features/home/home_navigation.dart` (51 lines)
- Ready for Phase 3 (CODE-02, CODE-03, BUG-01) — structured error handling and domain fixes

## Self-Check: PASSED

- ✅ `lib/features/home/profile_screen.dart` created (129 lines, `class ProfileScreen`)
- ✅ `lib/features/home/home_screen.dart` trimmed to 387 lines (≤430)
- ✅ No `class ProfileScreen` in home_screen.dart
- ✅ `import 'profile_screen.dart'` present in home_screen.dart
- ✅ `!mounted` guards after each await in `_checkAnilist()` and `_showAnilistLogin()`
- ✅ No unused `cached_image.dart` or `anilist_pairing_server.dart` imports
- ✅ `flutter analyze` passes with zero errors across entire project

---

*Phase: 02-home-screen-refactor*
*Completed: 2026-07-12*
