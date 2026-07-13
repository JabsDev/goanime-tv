---
phase: 04-testing-documentation
plan: 04
subsystem: testing
tags: [flutter, mocktail, fixture-testing, http-client]
requires:
  - phase: 04-01
    provides: TextUtils, TtlCache, AniList model unit tests
  - phase: 04-02
    provides: AnimeScraper, Cloudflare unit tests
provides:
  - AnimeFireAdapter optional http.Client? constructor param for mock injection
  - Fixture-based search() parsing test with captured real AnimeFire HTML
affects:
  - Phase 5: AniList integration — adapter test pattern reusable for other sources
tech-stack:
  added: []
  patterns:
    - Adapter fixture test with mocktail http.Client mock
    - http.Response.bytes() for non-Latin-1 fixture bodies
key-files:
  created:
    - test/core/sources/anime_fire_adapter_test.dart
    - test/fixtures/anime_fire/search_naruto.html
  modified:
    - lib/core/sources/anime_fire_adapter.dart
key-decisions:
  - "Use http.Response.bytes(utf8.encode(body)) instead of http.Response(body) when fixture contains non-Latin-1 characters (e.g. Japanese text in AnimeFire HTML)"
  - "registerFallbackValue(Uri()) must be called once in setUpAll for mocktail any() matcher"
requirements-completed: [TEST-01]
duration: 12min
completed: 2026-07-13
---

# Phase 04 Plan 04: AnimeFireAdapter Fixture Test Summary

**Optional http.Client? constructor injection on AnimeFireAdapter + 5 fixture-based search parsing tests with captured real AnimeFire HTML**

## Performance

- **Duration:** 12 min (17:38–17:50 BRT)
- **Started:** 2026-07-13T20:38:56Z
- **Completed:** 2026-07-13T20:50:00Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Added `final http.Client? _client` field and `{http.Client? client}` constructor param to `AnimeFireAdapter` for mock injection in tests (backward compatible — no-arg constructor still works)
- Created `_httpGet()` dispatching method routing calls to injected client or global `apiClient` fallback
- Replaced all 5 `apiClient.get()` call sites with `_httpGet()` across `search()`, `_fetchEpisodes()`, `_extractFromAnimeFire()`, and `_resolveVideoApi()`
- Captured live AnimeFire search HTML fixture at `test/fixtures/anime_fire/search_naruto.html` (42KB, 23 lines)
- Created 5 adapter parsing tests: happy path, empty results, non-200, retry on timeout, double-timeout failure
- Fixed mocktail Latin-1 encoding issue: `http.Response.bytes(utf8.encode(body))` for non-ASCII fixture content

## Task Commits

Each task was committed atomically:

1. **Task 1: Add optional http.Client? client constructor param** — `d316546` (feat)
2. **Task 2: Capture fixture HTML and create adapter parsing tests** — `d298b77` (feat)

## Files Created/Modified

### Created

- `test/core/sources/anime_fire_adapter_test.dart` — 5 fixture-based search() parsing tests using mocktail
- `test/fixtures/anime_fire/search_naruto.html` — Captured real AnimeFire search HTML for "naruto" (42KB)

### Modified

- `lib/core/sources/anime_fire_adapter.dart` — Added `http.Client?` field + constructor param + `_httpGet` dispatching method; replaced 5 `apiClient.get()` calls with `_httpGet()`

## Decisions Made

- **http.Response.bytes() for non-Latin-1 fixtures:** The `http.Response(String body, int statusCode)` constructor internally calls `latin1.encode(body)` which throws `ArgumentError` for characters outside Latin-1 (e.g., Japanese ツ). Using `http.Response.bytes(utf8.encode(body), statusCode)` bypasses this encoding check.
- **Fixture captured with real User-Agent:** CURL with the app's own User-Agent header to get representative HTML structure.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Mocktail throws ArgumentError with non-Latin-1 fixture HTML**
- **Found during:** Task 2 (Create adapter parsing tests)
- **Issue:** `http.Response(fixtureHtml, 200)` constructor throws `ArgumentError: Invalid argument (string): Contains invalid characters.` because it calls `latin1.encode(body)` internally, and the animefire.io HTML contains characters outside Latin-1 (e.g., `ツ` U+30C4 in "Oie ツ")
- **Fix:** Changed mock `thenAnswer` to use `http.Response.bytes(utf8.encode(fixtureHtml), 200)` which bypasses the Latin-1 encoding validation
- **Files modified:** `test/core/sources/anime_fire_adapter_test.dart`
- **Verification:** All 5 tests pass, full test suite (77 tests) passes
- **Committed in:** `d298b77` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Minor — the Latin-1 encoding issue is a known gotcha in the http package. The fix uses the correct constructor for fixture test data.

## Issues Encountered

- **Mocktail `registerFallbackValue` placement:** `registerFallbackValue(Uri())` must be called once in `setUpAll()` (not `setUp()` or test body) to register the fallback for mocktail's `any()` matcher on the `Uri` type. Re-registering per test is harmless but unnecessary.
- **`Failure` generic type parameter:** The `Failure<T>` class inherits its type parameter `T` from the enclosing `ScraperResult<T>` of the method return type. Test assertions should use `isA<Failure<List<Anime>>>()` not `isA<Failure<EmptyResultError>>()` — the error type is checked via `.error isA<EmptyResultError>`.

## Next Phase Readiness

- AnimeFireAdapter can now be tested without live network access
- Test pattern (MockHttpClient + fixture HTML) is reusable for other adapters (Goyabu, SuperFlix, AllAnime)
- No remaining known issues — all 77 unit tests pass
- Ready for Phase 5 (AniList integration) when planned

---

*Phase: 04-testing-documentation*
*Completed: 2026-07-13*
