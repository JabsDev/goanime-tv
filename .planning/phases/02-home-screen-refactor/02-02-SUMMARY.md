---
phase: 02-home-screen-refactor
plan: 02
subsystem: ui
tags: flutter, refactor, extraction, anilist, login, dialog

# Dependency graph
requires:
  - phase: 02-home-screen-refactor
    plan: 01
    provides: AnilistBanner widget and navigation helpers (anilist_banner.dart, home_navigation.dart)
provides:
  - AnilistLoginDialog extracted widget (formerly _AnilistLoginDialog)
  - Cleaned home_screen.dart with reduced import surface
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Private-to-public widget extraction (class rename, import addition)"
    - "Unused import cleanup after extraction"

key-files:
  created:
    - lib/features/home/anilist_login_dialog.dart
  modified:
    - lib/features/home/home_screen.dart

key-decisions:
  - "D-03 preserved: access_token= references unchanged in extracted dialog (PKCE fix deferred to separate commit)"
  - "Empty catch (_) {} replaced with debugPrint per D-01 (code quality fix during extraction)"
  - "no new !mounted guards needed — all async paths in dialog already had guards"

requirements-completed:
  - CODE-01

# Metrics
duration: 2min
completed: 2026-07-12
---

# Phase 02 Plan 02: Anilist Login Dialog Extraction

**Extracted `_AnilistLoginDialog` (~490 lines) from home_screen.dart into its own file with debugPrint catch fix and const constructor, removing heavyweight qr_flutter and webview_flutter imports from home_screen.dart**

## Performance

- **Duration:** 2 min
- **Started:** 2026-07-12T15:40:49Z
- **Completed:** 2026-07-12T15:43:01Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Extracted `_AnilistLoginDialog` (≈490 lines, WebView login + QR pairing + manual token entry) to `lib/features/home/anilist_login_dialog.dart` as public `AnilistLoginDialog`
- Applied D-01 fixes: replaced empty `catch (_) {}` with `debugPrint` logging; verified `const` constructors; confirmed all `!mounted` guards already present
- Removed unused imports from home_screen.dart: `qr_flutter`, `webview_flutter`, `anilist_pairing_server`, `cached_image`
- Added `import 'anilist_login_dialog.dart'` with public `const AnilistLoginDialog()` reference
- `flutter analyze` passes with zero errors

## Task Commits

Each task was committed atomically:

1. **Task 1: Create anilist_login_dialog.dart** - `5b12306` (feat) — extracted dialog class with debugPrint fix, const constructor, preserved PT-BR copy
2. **Task 2: Update home_screen.dart** - `e2040f1` (feat) — removed inline dialog, replaced with import, cleaned unused package imports

**Plan metadata:** *(committed below)*

## Files Created/Modified

- `lib/features/home/anilist_login_dialog.dart` — **Created.** Public `AnilistLoginDialog` StatefulWidget with three login modes: WebView, QR pairing, manual token paste. 501 lines.
- `lib/features/home/home_screen.dart` — **Modified.** Removed `_AnilistLoginDialog` class definition (was ~490 lines). Removed 4 unused imports. Added dialog import. Reduced from ~1184 to 689 lines.

## Decisions Made

- **Private-to-public rename:** `_AnilistLoginDialog` → `AnilistLoginDialog({super.key})` — required for cross-file import. State class kept private (`_AnilistLoginDialogState`).
- **PKCE deferral (D-03):** All `access_token=` references preserved verbatim in extracted file. The code= interception fix remains deferred.
- **Catch fix (D-01):** Empty `catch (_) {}` in `_getCurrentUrl` replaced with `catch (e) { debugPrint(...) }` — strictly an improvement, no behavioral change.
- **No mounted-guard gaps found:** All async methods in the dialog already had `if (!mounted) return;` after each `await`.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Ready for Plan 03 (ProfileScreen extraction, final trim of home_screen.dart)
- AnilistLoginDialog compiles independently with zero analysis errors
- HomeScreen references the dialog via import — no behavioral regressions

---

*Phase: 02-home-screen-refactor*
*Completed: 2026-07-12*
