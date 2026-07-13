---
phase: 03-error-handling-bug-fixes
plan: 02
subsystem: scraper/error-handling
tags: sealed-class, scraper-result, error-handling, cloudflare-detection, timeout-retry

# Dependency graph
requires:
  - phase: 03-error-handling-bug-fixes
    plan: 01
    provides: episode sort sentinel fix, SuperFlix domain source-of-truth
provides:
  - ScraperResult<T> sealed class with Loading/Success/Failure variants
  - ScraperError sealed class with 5 typed error variants
  - Migrated adapter interface (all 3 methods return ScraperResult)
  - Per-future error isolation in AnimeScraper orchestrator
  - Multi-pattern Cloudflare detection (D-08)
  - Timeout retry (D-04) and typed error propagation
affects:
  - Future plans needing typed error consumption in UI

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "sealed class ScraperResult<T> with factory constructors .success() and .failure()"
    - "exhaustive switch matching on ScraperResult variants (Loading, Success, Failure)"
    - "per-adapter-future error isolation via individual try/catch before Future.wait"
    - "nested try/catch for TimeoutException retry-once pattern"
    - "multi-pattern Cloudflare detection via isCloudflareChallenge() top-level function"

key-files:
  created:
    - lib/core/scraper/scraper_result.dart
  modified:
    - lib/core/sources/anime_source_adapter.dart
    - lib/core/sources/anime_fire_adapter.dart
    - lib/core/sources/goyabu_adapter.dart
    - lib/core/sources/super_flix_adapter.dart
    - lib/core/sources/all_anime_adapter.dart
    - lib/core/scraper/anime_scraper.dart
    - lib/data/repositories/anime_repository.dart
    - integration_test/scraper_smoke_test.dart
    - integration_test/superflix_webview_test.dart

key-decisions:
  - "D-01: Sealed class ScraperResult<T> with 3 variants (D-01 adhered)"
  - "D-02: ScraperError sealed class with 5 variants (D-02 adhered)"
  - "D-03: Each error carries message, AnimeSource, operationDuration (D-03 adhered)"
  - "D-04: Timeout retry once then Failure(TimeoutError) — implemented via nested try/catch"
  - "D-05: Parse failure → Failure(ParseFailureError) with snippet, no retry"
  - "D-07: Empty results → Failure(EmptyResultError) instead of silent []"
  - "D-08: Multi-pattern Cloudflare detection via isCloudflareChallenge()"
  - "D-09: Typed errors stay in log layer — public Scraper methods retain original return types"

requirements-completed:
  - CODE-02

# Metrics
duration: 8min
completed: 2026-07-13
---

# Phase 3 Plan 2: Structured Error Handling with ScraperResult Sealed Classes

**Replaced blanket `catch (e) { return []; }` pattern across all adapters and orchestrator with exhaustively-matchable `ScraperResult<T>`/`ScraperError` sealed classes, multi-pattern Cloudflare detection, timeout retry, and per-future error isolation.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-13T00:45:45Z
- **Completed:** 2026-07-13T00:54:04Z
- **Tasks:** 3
- **Files modified:** 10 (1 created, 9 modified)

## Accomplishments

- **Task 1 — Sealed class hierarchy:** Created `lib/core/scraper/scraper_result.dart` with `ScraperResult<T>` sealed class (Loading, Success, Failure variants), `ScraperError` sealed class with 5 typed variants (TimeoutError, ParseFailureError, CloudflareError, EmptyResultError, UnknownError), and top-level `isCloudflareChallenge()` multi-pattern detection function.
- **Task 2 — Adapter migration:** Updated `AnimeSourceAdapter` interface with `ScraperResult` return types and migrated all 4 adapters (AnimeFire, Goyabu, SuperFlix, AllAnime). Each adapter's 3 public methods now return typed `ScraperResult` with `Stopwatch`-based timing. Timeout retry (D-04) implemented via nested try/catch. Cloudflare detection uses `isCloudflareChallenge()` and precedes status-200 guard in SuperFlix. AllAnime maps `AA_CRYPTO_MISSING`/`NEED_CAPTCHA` to `CloudflareError`.
- **Task 3 — Orchestrator isolation:** Updated `AnimeScraper` with per-future error isolation (individual try/catch per adapter future before `Future.wait`), exhaustive switch matching on `ScraperResult` variants in `searchAnime()`, `getEpisodes()`, and `_findBySource()`. Outer catch blocks remain as last-resort safety nets. Updated `AnimeRepository` and integration tests to unwrap `ScraperResult`.

## Task Commits

Each task was committed atomically:

1. **Task 1: Create sealed class hierarchy** - `06f3303` (feat)
2. **Task 2: Migrate adapter interface and all 4 adapters** - `56c15c9` (feat)
3. **Task 3: Update AnimeScraper orchestrator** - `d639321` (feat)

## Files Created/Modified

- `lib/core/scraper/scraper_result.dart` — NEW: ScraperResult<T> sealed class (Loading, Success, Failure), ScraperError sealed class with 5 variants, isCloudflareChallenge() function
- `lib/core/sources/anime_source_adapter.dart` — Interface updated to ScraperResult return types
- `lib/core/sources/anime_fire_adapter.dart` — All 3 public methods return ScraperResult with stopwatch timing, timeout retry
- `lib/core/sources/goyabu_adapter.dart` — All 3 public methods return ScraperResult
- `lib/core/sources/super_flix_adapter.dart` — Cloudflare detection via isCloudflareChallenge(), ScraperResult returns
- `lib/core/sources/all_anime_adapter.dart` — Map AA_CRYPTO_MISSING/NEED_CAPTCHA to CloudflareError, all returns as ScraperResult
- `lib/core/scraper/anime_scraper.dart` — Per-future isolation, switch matching on ScraperResult
- `lib/data/repositories/anime_repository.dart` — Unwrap ScraperResult from adapter calls
- `integration_test/scraper_smoke_test.dart` — _unwrap() helper for ScraperResult
- `integration_test/superflix_webview_test.dart` — Unwrap ScraperResult from search call

## Decisions Made

- **D-01 through D-09 followed as specified** in 03-CONTEXT.md. ScraperResult<T> uses factory constructors `.success()` and `.failure()` for ergonomic construction while maintaining exhaustive pattern matching.
- **Cloudflare detection placed before status guard** in SuperFlix adapter HTTP paths, as Cloudflare can return 200 with a challenge page (content-based detection catches this via `isCloudflareChallenge`).
- **Retained private helper internal returns** — private methods like `_fetchEpisodes`, `_extractFromAnimeFire`, `_decodeBloggerToken` keep `List<T>` returns; public methods wrap results in `ScraperResult`.
- **Repository keeps its own error handling** — `tryAdapter` and `_contextForSource` unwrap `ScraperResult` but keep their own catch blocks for unexpected exceptions.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing factory constructors on ScraperResult<T>**
- **Found during:** Task 2 (analyze after migration)
- **Issue:** The sealed class definition omitted `ScraperResult.success()` and `ScraperResult.failure()` factory constructors that the plan's code examples used. All 4 adapters and the orchestrator referenced these nonexistent constructors.
- **Fix:** Added `factory ScraperResult.success(T data) = Success<T>;` and `factory ScraperResult.failure(ScraperError error) = Failure<T>;` to the sealed class definition.
- **Files modified:** `lib/core/scraper/scraper_result.dart`
- **Verification:** `flutter analyze` passes with zero errors
- **Committed in:** `56c15c9` (Task 2 commit, amended by adding factory constructors)

**2. [Rule 3 - Blocking] Downstream consumers need ScraperResult unwrapping**
- **Found during:** Full-project analyze after Task 3
- **Issue:** `AnimeRepository` and both integration test files used old return types directly (e.g., `for (r in results)` where `results` was now `ScraperResult`).
- **Fix:** Updated `AnimeRepository.tryAdapter`, `_contextForSource`, and `_superFlixContext` with switch unwrapping. Added `_unwrap<T>()` and `_unwrapEpisodes()` helpers to the test files.
- **Files modified:** `lib/data/repositories/anime_repository.dart`, `integration_test/scraper_smoke_test.dart`, `integration_test/superflix_webview_test.dart`
- **Verification:** `flutter analyze` passes with zero errors across the full project
- **Committed in:** `d639321` (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (2 Rule 3 - blocking)
**Impact on plan:** Both auto-fixes necessary for compilation correctness. No scope creep.

## Verification Results

- ✅ `flutter analyze` passes with zero errors (0 errors, 3 pre-existing warnings)
- ✅ All 3 methods in `AnimeSourceAdapter` return `Future<ScraperResult<...>>`
- ✅ All 4 adapters' public methods return `ScraperResult` with typed error variants
- ✅ No blanket `return []` or `return EpisodesResult([], {})` in any adapter public method
- ✅ `AnimeScraper` has per-future error isolation (individual try/catch per adapter)
- ✅ `AnimeScraper` uses `switch` on `ScraperResult` variants (Loading, Success, Failure)
- ✅ `isCloudflareChallenge()` used in SuperFlix adapter (replaces inline `html.contains('Verificação')`)
- ✅ Cloudflare check precedes status guard in SuperFlix HTTP paths
- ✅ AllAnime maps `AA_CRYPTO_MISSING`/`NEED_CAPTCHA` to `CloudflareError`
- ✅ All errors logged via `debugPrint` — no error types leak to return type
- ✅ Plan 01 bug fixes (episode sort sentinel, SuperFlix domain) remain intact
- ✅ Stopwatch-based `operationDuration` in all adapter methods

## Known Stubs

None — all adapter methods now return typed `ScraperResult` with proper error variants.

## Threat Flags

None — no new security-relevant surface introduced. All error types stay in the log layer per D-09.

## Next Phase Readiness

All CODE-02 requirements complete. Ready for Phase 3 Plan 3 (testing) or next planned phase.

## Self-Check: PASSED

- ✅ SUMMARY.md exists on disk at `.planning/phases/03-error-handling-bug-fixes/03-02-SUMMARY.md`
- ✅ All 3 feat commits present in git log (`06f3303`, `56c15c9`, `d639321`)
- ✅ `lib/core/scraper/scraper_result.dart` exists with sealed classes
- ✅ `flutter analyze` passes with zero errors
- ✅ No blanket `catch (e) { return []; }` remains in any adapter public method

---

*Phase: 03-error-handling-bug-fixes*
*Completed: 2026-07-13*
