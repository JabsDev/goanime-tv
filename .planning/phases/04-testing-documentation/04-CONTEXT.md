# Phase 4: Testing & Documentation - Context

**Gathered:** 2026-07-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish test coverage and developer documentation for the GoAnime TV project. Three requirements: CODE-04 (add AGENTS.md with workflow and build instructions), TEST-01 (add unit tests for core scraper and adapter logic), TEST-02 (expand integration test coverage for search, detail, and playback flows).

The codebase currently has zero unit tests, four live-network integration tests, no CI pipeline, no coverage tooling, and no AGENTS.md. The existing integration tests must remain functional.

</domain>

<decisions>
## Implementation Decisions

### Mocking & Test Framework
- **D-01:** Add `mocktail` as the mocking library for unit tests. Lightweight, zero boilerplate, no code generation — consistent with the project's minimal-dependency approach.
- **D-02:** Use HTML fixture files for adapter parsing tests. Capture real HTML responses from each provider as fixture files; mock the HTTP layer with mocktail but test against real HTML. This catches parser regressions when sites change without requiring live network access.
- **D-03:** Test fixtures live in `test/fixtures/{adapter_name}/` — organized per adapter/provider for easy maintenance.

### Test Scope & Priority
- **D-04** (Priority 1): Core utilities first — `TtlCache`, `TextUtils`, `AniListMediaDetail.fromJson`. Pure logic, minimal mocking needed, highest ROI per line of test code.
- **D-05** (Priority 2): Scraper orchestration — `AnimeScraper._bestMatch`, search/episode merging, cross-source dedup. Complex business logic requiring mocktail for adapter mocks.
- **D-06** (Priority 3): Adapter parsing — each adapter's `search()`, `getEpisodes()`, `getVideoSources()` using fixture files and mocktail.
- **D-07:** Test directory mirrors `lib/` structure — `test/core/cache/ttl_cache_test.dart`, `test/core/utils/text_utils_test.dart`, etc.

### Integration Test Expansion
- **D-08:** Add one new integration test covering the full search → detail → playback flow (matches success criterion directly).
- **D-09:** Keep existing four integration tests as-is — no refactoring of `scraper_smoke_test.dart`, `anilist_catalog_test.dart`, `pairing_server_test.dart`, or `superflix_webview_test.dart`.

### AGENTS.md Documentation
- **D-10:** Concise format (~50-80 lines) — enough for quick developer orientation.
- **D-11:** Sections: Build & Run commands (flutter, Go FFI bridge, test commands) + Project Structure overview (directory layout with key file roles).

### the agent's Discretion
- Exact set of core utility files to test beyond TtlCache/TextUtils/AniListMediaDetail — planner can expand based on what's pure-logic
- Whether TtlCache should remain no-dependency or mocktail is used for cache tests (TtlCache is pure Map logic — may not need mocking at all)
- Specific fixture file format and naming convention
- Exact AGENTS.md file location (convention is project root: `./AGENTS.md`)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope & requirements
- `.planning/ROADMAP.md` — Phase 4 definition, goal, success criteria, CODE-04/TEST-01/TEST-02 requirement mapping
- `.planning/REQUIREMENTS.md` — CODE-04 (AGENTS.md), TEST-01 (unit tests), TEST-02 (integration test expansion)

### Codebase analysis (testing & conventions)
- `.planning/codebase/TESTING.md` — Current testing state (0 unit tests, 4 integration tests, no CI, no coverage), gaps & recommendations
- `.planning/codebase/CONVENTIONS.md` — Dart code style, naming conventions, import organization, established patterns
- `.planning/codebase/STRUCTURE.md` — File layout, module organization, key file locations by feature
- `.planning/codebase/CONCERNS.md` — Known concerns relevant to testing and documentation

### Project context
- `.planning/PROJECT.md` — Project overview, core value, validated requirements, key decisions
- `.planning/STATE.md` — Current project phase state and traceability

### Prior decisions (Phase 1–3 carryforward)
- `.planning/phases/03-error-handling-bug-fixes/03-CONTEXT.md` — ScraperResult/ScraperError sealed classes being added; typed errors stay in log layer
- `.planning/phases/02-home-screen-refactor/02-CONTEXT.md` — snake_case.dart naming, navigation patterns, file structure conventions
- `.planning/phases/01-security-hardening/01-CONTEXT.md` — LocalStorage token persistence, pairing server patterns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Existing integration tests (`integration_test/scraper_smoke_test.dart`, `anilist_catalog_test.dart`, `pairing_server_test.dart`, `superflix_webview_test.dart`) — probe pattern can be reused for new E2E test
- `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` pattern — already established in all integration tests
- `debugPrint` diagnostic logging — existing convention used across all tests and production code

### Established Patterns
- No mocking anywhere — all tests hit live network endpoints (intentional: sites change frequently)
- `testWidgets` + `Timeout(Duration(minutes: N))` pattern for all integration tests
- Heavy `debugPrint()` usage for run-log diagnostics
- Adapter pattern (`AnimeSourceAdapter` interface) — each adapter has `search()`, `getEpisodes()`, `getVideoSources()`
- Pure-logic classes (`TtlCache`, `TextUtils`) with no Flutter dependency — easy to unit test
- `flutter_lints ^6.0.0` with two `prefer_const_*` overrides

### Integration Points
- `test/` directory does not exist — must be created from scratch
- `pubspec.yaml` must add `mocktail` dev dependency
- `lib/core/cache/ttl_cache.dart` — pure Map<String, _CacheEntry> with per-entry TTL — no I/O, no Flutter dependency
- `lib/core/utils/text_utils.dart` — string normalization, URL parsing — pure Dart
- `lib/core/scraper/anime_scraper.dart` — complex orchestration with _bestMatch, merge/dedup logic
- `lib/core/sources/*_adapter.dart` — each adapter's HTTP parsing needs fixture files
- `lib/data/models/anilist_models.dart` — AniListMediaDetail.fromJson — pure JSON deserialization

</code_context>

<specifics>
## Specific Ideas

### Test File Structure (projected)
```
test/
├── core/
│   ├── cache/
│   │   └── ttl_cache_test.dart
│   ├── utils/
│   │   └── text_utils_test.dart
│   └── scraper/
│       └── anime_scraper_test.dart
├── data/
│   └── models/
│       └── anilist_models_test.dart
├── fixtures/
│   ├── anime_fire/
│   ├── all_anime/
│   ├── super_flix/
│   └── goyabu/
└── integration/
    └── search_detail_playback_test.dart
```

### AGENTS.md Sections (projected)
1. Build & Run — `flutter pub get`, `flutter run -d android`, `flutter build apk`, Go FFI bridge rebuild
2. Project Structure — top-level directory layout with key file roles
3. Testing — `flutter test`, `flutter test integration_test/`, mocktail usage

### What NOT to Touch
- Do not refactor existing integration tests
- Do not add new source adapters
- Do not change UI or scraper behavior
- Do not add code coverage tooling (deferred — not in current scope)

</specifics>

<deferred>
## Deferred Ideas

### Coverage Tooling
Adding `flutter test --coverage` with minimum thresholds or Codecov integration is a natural extension but is not in the current phase scope. Worth considering for a future phase.

### CI Pipeline Setup
Success criterion says "Tests pass on CI" but CI setup (GitHub Actions) is explicitly part of Phase 5 (Release Configuration). Phase 4 produces the tests — Phase 5 wires them into CI.

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 4-Testing & Documentation*
*Context gathered: 2026-07-13*
