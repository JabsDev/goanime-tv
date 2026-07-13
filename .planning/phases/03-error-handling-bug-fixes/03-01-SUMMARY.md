---
phase: 03-error-handling-bug-fixes
plan: 01
subsystem: scraper/bug-fix
tags: episode-sorting, sentinel, superflix-domain, double-infinity

# Dependency graph
requires:
  - phase: 02-home-screen-refactor
    provides: AGENTS.md, project structure conventions
provides:
  - Episode sort sentinel fix across all 4 adapters (BUG-01)
  - SuperFlix domain source-of-truth unification (CODE-03)
affects:
  - 03-error-handling-bug-fixes (future plans in this phase)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "double.infinity as sort sentinel for unparseable episode numbers"
    - "AppConstants.superFlixBase as single domain source of truth"

key-files:
  created: []
  modified:
    - lib/core/sources/anime_fire_adapter.dart
    - lib/core/sources/goyabu_adapter.dart
    - lib/core/sources/super_flix_adapter.dart
    - lib/core/sources/all_anime_adapter.dart
    - lib/features/superflix/superflix_web_screen.dart

key-decisions:
  - "D-11: double.infinity as single sentinel value (Pitfall 2 avoidance)"

requirements-completed:
  - CODE-03
  - BUG-01

# Metrics
duration: 6min
completed: 2026-07-12
---

# Phase 3 Plan 1: Episode Sort Sentinel + SuperFlix Domain Fix

**Replaced `?? 0` sort sentinel with `double.infinity`/`double.infinity.toInt()` at all 5 sort call sites across 4 adapters; unified SuperFlix WebView domain via `AppConstants.superFlixBase`**

## Performance

- **Duration:** 6 min
- **Started:** 2026-07-12T20:30:00Z
- **Completed:** 2026-07-12T20:36:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- **BUG-01 fixed:** All 5 episode sort call sites now use `double.infinity` sentinel, causing unparseable episode numbers (OVA/Special/specials) to sort to end of list instead of position 0
- **CODE-03 fixed:** SuperFlix WebView `_playerUrl` getter now uses `AppConstants.superFlixBase` instead of hardcoded `'https://superflixapi.pro'`
- Per RESEARCH.md Pitfall 2 guidance, standardized on `double.infinity` as single sentinel value across both int-based and double-based sort sites
- No interface changes — all adapters retain existing return types

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix episode sort sentinel at all 5 sort call sites** - `bd3676a` (fix)
2. **Task 2: Fix SuperFlix WebView domain to use AppConstants.superFlixBase** - `650276c` (fix)

## Files Created/Modified

- `lib/core/sources/anime_fire_adapter.dart` - `?? 0` → `?? double.infinity.toInt()` at sort comparator (lines 89-90)
- `lib/core/sources/goyabu_adapter.dart` - `?? 0` → `?? double.infinity.toInt()` at sort comparator (lines 157-158)
- `lib/core/sources/super_flix_adapter.dart` - `?? 0` → `?? double.infinity` at both sort comparators (FFI path line 139, HTTP path line 190)
- `lib/core/sources/all_anime_adapter.dart` - `?? 0` → `?? double.infinity` at sort comparator (line 155)
- `lib/features/superflix/superflix_web_screen.dart` - Added `app_constants.dart` import; `_playerUrl` uses `AppConstants.superFlixBase`

## Decisions Made

- **D-11:** Used `double.infinity` as the single sentinel value across all adapters, as recommended by RESEARCH.md Pitfall 2. For int-based adapters (AnimeFire, Goyabu), used `double.infinity.toInt()`. For double-based adapters (SuperFlix FFI, SuperFlix HTTP, AllAnime), used `double.infinity` directly.

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

- ✅ `flutter analyze` passes with zero errors (only pre-existing info/warnings)
- ✅ Zero occurrences of `superflixapi.pro` remain in codebase
- ✅ Zero occurrences of `?? 0` remain in sort comparators across all 4 adapters
- ✅ `double.infinity` present at all 5 sort call sites (7 occurrences across 4 files)
- ✅ `AppConstants.superFlixBase` used in `superflix_web_screen.dart` `_playerUrl`

## Issues Encountered

None

## Next Phase Readiness

Ready for Phase 3 Plan 2 (structured error handling with ScraperResult sealed class).

---

*Phase: 03-error-handling-bug-fixes*
*Completed: 2026-07-12*
