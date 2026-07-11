# Testing: GoAnime TV

**Date:** 2026-07-11

## Test Framework

- **Flutter SDK** testing stack:
  - `flutter_test` (SDK) — unit tests, widget tests
  - `integration_test` (SDK) — device-level integration / E2E tests
- **No third-party testing libraries** (no `mockito`, `mocktail`, `bloc_test`).
- **No Go tests** — the Go bridge (`go_superflix/`) has no test files.
- **Linting:** `flutter_lints ^6.0.0` with default rules minus two `prefer_const_*` overrides (`analysis_options.yaml`).

## Test Locations

| Directory | Type | Files |
|-----------|------|-------|
| `integration_test/` | Integration (device-level) | 4 files |
| `build/unit_test_assets/` | Assets for unit test runner | Fonts, shaders, asset bundle (auto-generated) |

There are **no unit tests** for any `lib/` file. All tests are integration tests that run on a real device or emulator.

## Integration Tests

### File: `integration_test/scraper_smoke_test.dart`
- **Purpose:** End-to-end smoke test for every scraper provider.
- **Tests:**
  - `registry has 5 adapters` — verifies `SourceRegistry.adapters.length == 5`
  - `AnimeFire: episodes + qualities` — searches "naruto", lists episodes, resolves sources
  - `SuperFlix: direct search + episodes + multi-server stream` — searches "the boys", notes Cloudflare gating
  - `AnimeFire: real series episodes + multi-quality stream` — searches "kimetsu no yaiba", prefers full-series page, asserts sources non-empty
  - `Goyabu: PT-BR search + episodes + multi-quality stream` — searches "one piece", finds a series with episodes, resolves multi-quality
  - `End-to-end probes` — runs `probe()` for "one piece", "naruto", "the boys"
- **Timeout:** 3–5 minutes per test (real network + scraping).
- **Helper:** `Future<void> probe(String query)` encapsulates the full search → episodes → sources pipeline with debug logging.

### File: `integration_test/anilist_catalog_test.dart`
- **Purpose:** Verifies AniList catalog discovery trend → episode resolution by title.
- **Tests:**
  - `AniList catalog + episode resolution by title` — fetches trending + seasonal, asserts non-empty, resolves episodes for top 6 via `AnimeRepository`
- **Timeout:** 5 minutes.
- **Assertions:** `expect(trending.isNotEmpty, true)`, `expect(resolved > 0, true)`.

### File: `integration_test/pairing_server_test.dart`
- **Purpose:** Verifies the LAN pairing server boots and serves pages.
- **Tests:**
  - `Pairing server serves pages + rejects bad token` — starts server, fetches landing page (checks for `authorize`, `redirect_uri`), fetches callback page (checks for `access_token`), POSTs invalid token (expects 400)
- **Timeout:** 1 minute.

### File: `integration_test/superflix_webview_test.dart`
- **Purpose:** Verifies the SuperFlix WebView Turnstile bypass on a real device.
- **Tests:**
  - `SuperFlix WebView resolves a stream` — searches "the boys", opens WebView resolver, polls for sources up to 60 seconds
- **Timeout:** 3 minutes.

## Test Structure

All integration tests follow the same pattern:

```dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('description', (tester) async {
    // 1. Execute real service/adapter calls
    // 2. Assert results with expect()
    // 3. Log intermediate state with debugPrint
  }, timeout: const Timeout(Duration(minutes: N)));
}
```

- `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` is called once per file (`pairing_server_test.dart:11`).
- Tests use `tester` only for pump calls in the WebView test; most tests are pure logic (no widget rendering).
- Heavy use of `debugPrint()` for diagnostic output — these tests serve as both assertions and run logs.

## Mocking Approach

**No mocking is used anywhere in the test suite.** All tests hit real network endpoints:
- AniList GraphQL API (live)
- AnimeFire, Goyabu, SuperFlix, AllAnime (live scraping)
- Real HTTP server binding (pairing server test)

This is intentional — the codebase scrapes live websites where HTML structure changes frequently; mock-based tests would pass while the real app breaks.

## Test Coverage Patterns

- **No code coverage tooling configured.** There are no coverage thresholds, no `lcov`, no Codecov/Coveralls integration.
- **Unit test coverage for `lib/` is 0%** — no file under `lib/` has a corresponding `test/` file.
- **Coverage is entirely manual** through integration tests that exercise the full search → episodes → sources pipeline for each provider.
- The `scraper_smoke_test.dart` probe function is the closest thing to a coverage target: it touches `AnimeRepository`, `AnimeScraper`, `SourceRegistry`, every adapter, and the `Anime`/`Episode`/`VideoSource` data models.

## CI Configuration

- **No CI configuration exists.** There is no `.github/` directory, no `ci.yaml`, no `Jenkinsfile`, no `Dockerfile`.
- No `.gitlab-ci.yml`, `bitbucket-pipelines.yml`, or `circleci/config.yml`.
- The `build/` directory contains local build artifacts only (`.cxx/`, `.transforms/`, `.dex` files, etc.).
- The existing `.planning/` directory contains only codebase documentation and phase planning — no CI scripts.

## Running Tests

```bash
# Integration test on Android emulator
flutter test integration_test/scraper_smoke_test.dart -d emulator-5554

# All integration tests
flutter test integration_test/ -d emulator-5554
```

There are no unit test invocations (`flutter test test/` runs nothing since `test/` does not exist).

## Gaps & Recommendations

1. **Unit tests are entirely missing.** `TtlCache`, `TextUtils`, `AniListMediaDetail.fromJson`, and `AnimeScraper._bestMatch` are pure-logic methods that would benefit from fast unit tests.
2. **No mock/stub layer.** Adding `mocktail` or a hand-rolled `FakeApiClient` would enable unit-testing of scraper adapters without hitting live sites.
3. **No coverage tooling.** Integrating `flutter test --coverage` with a minimum coverage threshold would catch regressions.
4. **The `integration_test/` tests are fragile** — they depend on live websites whose HTML structure can change independently of the app code.
5. **No CI pipeline.** Adding GitHub Actions (or equivalent) with `flutter test` and `flutter build apk` would prevent regressions.
