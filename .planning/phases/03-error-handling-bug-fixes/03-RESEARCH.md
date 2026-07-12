# Phase 3: Error Handling & Bug Fixes - Research

**Researched:** 2026-07-12
**Domain:** Scraper error handling, sealed class design, Cloudflare detection, episode sorting
**Confidence:** HIGH

## Summary

This phase replaces the blanket `catch (e) { return []; }` pattern across all 4 adapters and the orchestrator with a typed sealed-class error hierarchy (`ScraperResult<T>` / `ScraperError`), fixes two concrete bugs (SuperFlix domain inconsistency, episode sorting sentinel), and hardens Cloudflare challenge detection. Dart 3.9.2 provides native sealed class support — no codegen libraries needed. The migration is a one-shot interface change across all adapters; the Android TV UI surface is unaffected (errors stay internal to the scraper layer).

**Primary recommendation:** Use raw Dart 3 sealed classes (no freezed/nio), one-shot migration of `AnimeSourceAdapter` interface, inline retry for timeouts, and `double.infinity` sentinel for episode sorting.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Error type definition | Core (`lib/core/scraper/scraper_result.dart`) | — | Sealed class hierarchy lives in core; consumed by adapters and orchestrator |
| Error production | Adapters (`lib/core/sources/`) | — | Each adapter's try/catch becomes a typed `Failure(...)` return |
| Error recovery/fallback | Orchestrator (`lib/core/scraper/anime_scraper.dart`) | Repository (`lib/data/repositories/anime_repository.dart`) | Orchestrator fans out + recovers; repo has its own fallback (unchanged) |
| Error consumption (log only) | Orchestrator | — | Per D-09, errors stay in log layer; UI sees empty states |
| Cloudflare detection | Adapters (SuperFlix, AllAnime) | — | Detection happens at scrape time, before parsing |
| Episode sorting | Adapters (all 4) | — | Each adapter owns its episode list sort |
| SuperFlix domain | Feature (`superflix_web_screen.dart`) | Constants (`app_constants.dart`) | Single source of truth already exists; WebView reads from it |

## Standard Stack

### Core: Dart 3 Sealed Classes (no external package)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Dart `sealed` class | 3.9.2+ | `ScraperResult<T>`, `ScraperError` hierarchy | Native Dart 3 feature; no codegen, no deps, fully exhaustive |
| Dart `switch` expression | 3.9.2+ | Pattern matching on sealed variants | Compiler-enforced exhaustiveness; destructuring in cases |
| Dart `records` (optional) | 3.9.2+ | Lightweight grouped returns | Available if needed for internal helpers |

### No Additional Packages Needed

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Raw sealed class | `freezed` + codegen | Freezed requires `build_runner`, adds build tax, generates `.when()`/`.map()` that are now redundant with Dart 3 pattern matching. Raw sealed classes have zero dependencies and no generation step. |
| Inline retry | `nio` or `async_retry` package | Requirement is "retry once" — a 5-line inline pattern is simpler and has zero dependency cost. |
| Hand-rolled error types | `either` or `dartz` package | Introduces FP type plumbing unfamiliar to the rest of the codebase. Sealed classes are idiomatic Dart 3. |

### Installation

```bash
# No new packages needed. This phase uses only: sdk: ^3.9.2 features
```

## Package Legitimacy Audit

> **No external packages required for this phase.** All work uses built-in Dart 3 features and existing project dependencies. No new `pubspec.yaml` entries are needed.

## Architecture Patterns

### One-Shot Interface Migration Pattern

**What:** Change `AnimeSourceAdapter` return types from `Future<List<Anime>>` / `Future<EpisodesResult>` / `Future<List<VideoSource>>` to `Future<ScraperResult<List<Anime>>>` / `Future<ScraperResult<EpisodesResult>>` / `Future<ScraperResult<List<VideoSource>>>` in a single atomic change across all 4 adapters.

**When to use:** Breaking interface changes with multiple implementations — gradual migration requires a bridge/adapter wrapper that doubles complexity.

**Why one-shot:** Changing `AnimeSourceAdapter` means every implementation (`AnimeFireAdapter`, `GoyabuAdapter`, `SuperFlixAdapter`, `AllAnimeAdapter`) must update simultaneously. An intermediate bridge class (`LegacyAdapter implements AnimeSourceAdapter`) that wraps new return types back to old ones adds no value — you'd need a mirror class on the consumer side too.

**Migration order:**
1. Create `ScraperResult<T>` and `ScraperError` sealed classes in `lib/core/scraper/scraper_result.dart`
2. Update `AnimeSourceAdapter` interface (return types change)
3. Update each adapter's 3 methods (search, getEpisodes, getVideoSources) — convert each `catch (e) { debugPrint(...); return []; }` to typed error returns
4. Update `AnimeScraper` to destructure `ScraperResult` variants
5. Apply episode sort fix, Cloudflare detection fix, domain fix alongside

### Error Recovery in Fan-Out Pattern

**What:** Replace the current `Future.wait(SourceRegistry.adapters.map((a) => a.search(animeName)))` with individual error-handled futures.

**Current code (anime_scraper.dart:22-24):**
```dart
final results = await Future.wait(
  SourceRegistry.adapters.map((a) => a.search(animeName)),
);
```

**Problem:** `Future.wait` fails fast — if ONE adapter throws, ALL results are lost. Even after migration to `ScraperResult`, an unhandled exception in one adapter's future still propagates through `Future.wait`.

**Recommended pattern:**
```dart
final futures = SourceRegistry.adapters.map((a) async {
  try {
    return await a.search(animeName);
  } catch (e) {
    debugPrint('[AnimeScraper] Unhandled exception from ${a.source}: $e');
    return ScraperResult.failure(...);
  }
});
final results = await Future.wait(futures);
```

This ensures each adapter's failure is isolated. The outer `try/catch` in the orchestrator becomes a safety net for genuinely unexpected errors rather than the primary error handler.

### Retry-Once Pattern for Timeouts

**What:** Simple inline retry for timeout errors.

```dart
Future<ScraperResult<List<Anime>>> search(String animeName) async {
  try {
    return ScraperResult.success(await _doSearch(animeName));
  } on TimeoutException catch (e) {
    debugPrint('[Adapter] Timeout on first attempt, retrying...');
    try {
      return ScraperResult.success(await _doSearch(animeName));
    } on TimeoutException {
      return ScraperResult.failure(ScraperError.timeout(
        message: 'Search timed out after retry',
        source: source,
        timeoutValue: AppConstants.requestTimeout,
        operationDuration: ...,
      ));
    }
  } on FormatException catch (e) {
    return ScraperResult.failure(ScraperError.parseFailure(
      message: 'Failed to parse response',
      source: source,
      snippet: e.source?.substring(0, 200),
      operationDuration: ...,
    ));
  }
}
```

### Anti-Patterns to Avoid

- **Double-error-handling**: Don't both return `ScraperResult` AND have a surrounding try/catch that returns empty lists. Only one pattern at each boundary.
- **Error propagation to UI**: Per D-09, errors stop at the log layer. Don't surface `ScraperError` variants in UI widgets — convert to empty states.
- **Retry on parse failures**: D-05 explicitly says no retry for parse failures (same response won't change).
- **Catch-all before typed errors**: After migration, the outer `catch (e) { return []; }` in AnimeScraper should remain only as a last-resort safety net that returns `Failure(unknown)`, not an empty list.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Error type hierarchy | Error codes enum with manual matching | Dart 3 `sealed class` | Exhaustiveness checking at compile time; destructuring in switch cases |
| Retry logic | Retry library/utility | Inline `try/catch` retry | Requirement is "retry once" only; a 5-line pattern beats a dependency |
| Cloudflare detection | Complex ML-based detection | String/content-based heuristics (D-08) | Existing code already uses simple checks; the fix is to expand the pattern set, not rewrite the approach |
| Episode sorting utility | Shared `sortEpisodes()` function | Inline sentinel at each call site (D-11) | Only 5 call sites; the fix is a one-character change (`?? 0` → `?? double.infinity`). A shared utility adds indirection without value. |

**Key insight:** Every "don't hand-roll" item in this phase is about replacing code that's already hand-rolled (blanket catch, fragile detection, sentinel bug). The replacement is a small, targeted improvement — not a new subsystem.

## Common Pitfalls

### Pitfall 1: Future.wait eats individual adapter errors
**What goes wrong:** `Future.wait` on 4 adapters produces a single error that kills all results, even after migration to `ScraperResult`. An unhandled exception in one adapter (e.g., null pointer in parsing) still propagates through `Future.wait` as an uncaught exception.
**Why it happens:** `Future.wait` has no "per-future error isolation" — it fails on the first rejected future.
**How to avoid:** Wrap each adapter's future in an individual try/catch before passing to `Future.wait` (see Architecture Patterns above).
**Warning signs:** One adapter crashing silently takes down all search results.

### Pitfall 2: Episode number sentinel inconsistency
**What goes wrong:** Using `int.maxValue` for int-based sorting but `double.infinity` for double-based sorting at different call sites, causing mixed-type comparison errors.
**Why it happens:** Five sort call sites — two use `int.tryParse` (AnimeFire, Goyabu), two use `double.tryParse` (SuperFlix FFI, SuperFlix HTTP), one uses `double.tryParse` (AllAnime).
**How to avoid:** Standardize on `double.infinity` as the single sentinel value, since two adapters already use `double.tryParse`. For the two `int.tryParse` sites, cast `double.infinity.toInt()` or change to `double.tryParse`.
**Warning signs:** OVA/Special episodes appearing at position 0 in some adapters but at the end in others.

### Pitfall 3: Neglecting the WebView Cloudflare detection path
**What goes wrong:** The Cloudflare detection hardening (D-08) is applied to HTTP-scraped HTML, but the WebView path in `superflix_web_screen.dart` also has a Cloudflare check (`document.title.indexOf('Verifica') === -1`) that's not updated.
**Why it happens:** The two detection paths (Dart HTTP vs WebView JS) are in different files maintained by different developers.
**How to avoid:** Update the WebView JS check to match the expanded pattern set from D-08. Alternatively, the `readyStr` check in `_tryExtract` (line 105) already covers this by checking both CSRF_TOKEN presence AND the absence of 'Verifica' in the title — this is actually already multi-pattern at the JS level.
**Warning signs:** WebView still using only `'Verifica'` after HTTP path is hardened.

### Pitfall 4: AnimeRepository also has blanket catches
**What goes wrong:** The `AnimeRepository` has its own catch-all patterns (lines 35-39, 86, 102) that swallow errors. If adapters return ScraperResult but the repository still catches exceptions and returns `[]`, the typed errors never reach consumers.
**Why it happens:** The repository uses try/catch as a fallback mechanism for cross-source video resolution.
**How to avoid:** Keep repository-level catches as-is — they serve a different purpose (fallback cascading across sources). The repository consumes scraper outputs; it doesn't need to distinguish error types for its fallback logic.
**Warning signs:** Typed errors created in adapters are re-swallowed in the repository before reaching any consumer.

## Runtime State Inventory

> **Skip:** This phase is code-only — no rename/refactor/migration of runtime state. All changes are internal to the adapter/scraper layer. The SuperFlix domain fix (CODE-03) changes which constant a WebView reads at widget build time, not any stored or registered state.

## Code Examples

### Sealed Class Hierarchy

```dart
// Source: [CITED: dart.dev/language/class-modifiers] — Dart 3 sealed class syntax
// lib/core/scraper/scraper_result.dart

import '../sources/anime_source_adapter.dart' show AnimeSource;

/// Typed result from any scraper/adapter operation.
/// Replaces the blanket `catch (e) { return []; }` pattern.
sealed class ScraperResult<T> {
  const ScraperResult();
}

final class Loading<T> extends ScraperResult<T> {
  const Loading();
}

final class Success<T> extends ScraperResult<T> {
  final T data;
  const Success(this.data);
}

final class Failure<T> extends ScraperResult<T> {
  final ScraperError error;
  const Failure(this.error);
}

/// Typed error variants for scraper operations.
sealed class ScraperError {
  final String message;
  final AnimeSource source;
  final Duration operationDuration;

  const ScraperError({
    required this.message,
    required this.source,
    required this.operationDuration,
  });
}

final class TimeoutError extends ScraperError {
  final Duration timeoutValue;
  const TimeoutError({
    required super.message,
    required super.source,
    required super.operationDuration,
    required this.timeoutValue,
  });
}

final class ParseFailureError extends ScraperError {
  final String snippet;
  const ParseFailureError({
    required super.message,
    required super.source,
    required super.operationDuration,
    required this.snippet,
  });
}

final class CloudflareError extends ScraperError {
  final String detectionPattern;
  const CloudflareError({
    required super.message,
    required super.source,
    required super.operationDuration,
    required this.detectionPattern,
  });
}

final class EmptyResultError extends ScraperError {
  const EmptyResultError({
    required super.message,
    required super.source,
    required super.operationDuration,
  });
}

final class UnknownError extends ScraperError {
  final Object? originalError;
  const UnknownError({
    required super.message,
    required super.source,
    required super.operationDuration,
    this.originalError,
  });
}
```

### Adapter Method with Typed Errors

```dart
// Source: Derived from adapter interface + D-01/D-02 decisions
// Pattern for conversion of current catch-all methods

@override
Future<ScraperResult<List<Anime>>> search(String animeName) async {
  final stopwatch = Stopwatch()..start();
  try {
    final url = '${AppConstants.baseSiteUrl}/pesquisar/${TextUtils.treatName(animeName)}';
    final res = await apiClient
        .get(Uri.parse(url), headers: {'User-Agent': AppConstants.userAgent})
        .timeout(AppConstants.requestTimeout);
    if (res.statusCode != 200) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Non-200 status: ${res.statusCode}',
        source: source,
        operationDuration: stopwatch.elapsed,
      ));
    }
    // ... parse HTML into List<Anime> ...
    if (parsed.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'No results found',
        source: source,
        operationDuration: stopwatch.elapsed,
      ));
    }
    return ScraperResult.success(parsed);
  } on TimeoutException catch (e) {
    // D-04: Retry once
    try {
      return await _doSearch(animeName, stopwatch);
    } on TimeoutException {
      return ScraperResult.failure(TimeoutError(
        message: 'Search timed out after retry',
        source: source,
        operationDuration: stopwatch.elapsed,
        timeoutValue: AppConstants.requestTimeout,
      ));
    }
  } on FormatException catch (e) {
    return ScraperResult.failure(ParseFailureError(
      message: 'HTML parse failure',
      source: source,
      operationDuration: stopwatch.elapsed,
      snippet: e.source?.substring(0, 200) ?? 'unknown',
    ));
  } catch (e) {
    return ScraperResult.failure(UnknownError(
      message: 'Unexpected error: $e',
      source: source,
      operationDuration: stopwatch.elapsed,
      originalError: e,
    ));
  }
}
```

### Orchestrator Consuming ScraperResult

```dart
// Source: Derived from pattern matching + D-01/D-02 decisions
// Pattern for anime_scraper.dart fan-out

static Future<List<Anime>> searchAnime(String animeName) async {
  final cacheKey = animeName.trim().toLowerCase();
  final cached = AppCaches.search.get<List<Anime>>(cacheKey);
  if (cached != null) return cached;

  debugPrint('[AnimeScraper] Searching: $animeName');

  // Each adapter's future is individually guarded so one failure
  // doesn't kill the entire fan-out via Future.wait.
  final futures = SourceRegistry.adapters.map((a) async {
    try {
      return await a.search(animeName);
    } catch (e) {
      debugPrint('[AnimeScraper] Unhandled exception from ${a.source}: $e');
      return ScraperResult<List<Anime>>.failure(UnknownError(
        message: 'Unhandled: $e',
        source: a.source,
        operationDuration: Duration.zero,
      ));
    }
  });

  final results = await Future.wait(futures);

  final allAnimes = <Anime>[];
  for (final result in results) {
    switch (result) {
      case Success(data: final animes):
        allAnimes.addAll(animes);
      case Failure(
          error: CloudflareError(source: var src, detectionPattern: var pattern)
        ):
        debugPrint('[AnimeScraper] $src blocked by Cloudflare ($pattern)');
      case Failure(error: var err):
        debugPrint('[AnimeScraper] ${err.source} failed: ${err.message}');
      case Loading():
        // Not possible at this point; included for exhaustiveness
        break;
    }
  }
  // ... rest of enrichment + caching unchanged ...
}
```

### Multi-Pattern Cloudflare Detection

```dart
// Source: D-08 decision — expanded from single 'Verificação' check

bool _isCloudflareChallenge(String html, Map<String, String> headers) {
  // Content-based patterns
  if (html.contains('Verificação')) return true;
  if (html.contains('cf-browser-verification')) return true;
  if (html.contains('cf-challenge')) return true;

  // Status-based (caller checks statusCode before calling this)
  // Header-based
  for (final key in headers.keys) {
    if (key.startsWith('CF-Ray') || key.startsWith('CF-Challenge')) {
      return true;
    }
  }

  return false;
}
```

### Episode Sorting Sentinel Fix

```dart
// Source: D-11 decision — sentinel values at all 5 call sites

// AnimeFire (int-based, line 89): change ?? 0 to ?? double.infinity.toInt()
final na = int.tryParse(a.number) ?? double.infinity.toInt();

// SuperFlix (double-based, lines 139, 190): change ?? 0 to ?? double.infinity
final na = double.tryParse(a.number) ?? double.infinity;
final nb = double.tryParse(b.number) ?? double.infinity;

// AllAnime (double-based, line 155): change ?? 0 to ?? double.infinity
sorted.sort((a, b) => (double.tryParse(a) ?? double.infinity)
    .compareTo(double.tryParse(b) ?? double.infinity));

// Goyabu (int-based, line 157): note special regex + int parsing
// Current: int.tryParse(RegExp(r'\d+').firstMatch(a.number)?.group(0) ?? '0') ?? 0;
// Fixed: int.tryParse(...) ?? double.infinity.toInt();
```

### SuperFlix Domain Fix

```dart
// Source: D-10 decision — replace hardcoded .pro with AppConstants.superFlixBase

// In lib/features/superflix/superflix_web_screen.dart (line 67)
// Before:
return 'https://superflixapi.pro/serie/$_tmdbId/$season/${widget.episode.number}';
// After:
return '${AppConstants.superFlixBase}/serie/$_tmdbId/$season/${widget.episode.number}';
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `catch (e) { return []; }` everywhere | `ScraperResult<T>` with typed errors | Phase 3 | Devs can distinguish timeout vs parse vs Cloudflare vs empty; compiler enforces exhaustiveness |
| `?? 0` sort sentinel | `?? double.infinity` sentinel | Phase 3 | OVA/Special episodes correctly sort to end instead of position 0 |
| Single pattern `'Verificação'` check | Multi-pattern Cloudflare detection | Phase 3 | Lower false-negative rate; adapts to challenge page changes |
| Hardcoded `.pro` in WebView | `AppConstants.superFlixBase` | Phase 3 | Single source of truth for domain config |

**Deprecated/outdated:**
- Blanket `catch (e) { return []; }` pattern across all adapters — replaced by typed error returns

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | All adapters implement `AnimeSourceAdapter` with exactly 3 methods | Architecture Patterns | Confirmed by reading all 4 adapter files — correct |
| A2 | Each adapter has exactly one `getEpisodes` sort call site | Common Pitfalls | AnimeFire=1, Goyabu=1, SuperFlix=2 (FFI + HTTP), AllAnime=1 — confirmed by reading source |
| A3 | The existing `apiClient.get` does not already handle TimeoutException | Code Examples | `apiClient` is a thin `http` wrapper; `http` package throws `TimeoutException` on timeout |
| A4 | The `AnimeRepository` blanket catches should remain unchanged | Common Pitfalls | Repository's catches serve a different purpose (fallback cascading). Risk is low — if repository SHOULD propagate errors, this is a future concern |

## Open Questions

1. **How to extract `operationDuration` in adapter methods?**
   - What we know: Every error variant requires `operationDuration`. Adapter methods currently don't track this.
   - Recommendation: Use `Stopwatch()..start()` at method entry, capture `stopwatch.elapsed` at exit/error. Add a timing helper utility if code reuse across 4 adapters × 3 methods = 12 call sites justifies it.

2. **AllAnime Cloudflare detection — currently a text-based check for `'AA_CRYPTO_MISSING'` and `'NEED_CAPTCHA'` — should this map to `CloudflareError` or `UnknownError`?**
   - What we know: AllAnime uses a different mechanism (CAPTCHA gating via GraphQL API). The string matches in `_extractFromAllAnime` (line 205) detect "API is Cloudflare/captcha gated."
   - Recommendation: Map to `CloudflareError` with appropriate detection pattern string for consistency. The planner should decide.

3. **Should the `Loading` variant in `ScraperResult` be included?**
   - What we know: D-01 specifies 3 variants: `Loading`, `Success(T)`, `Failure(ScraperError)`. However, `Loading` is never produced by any adapter method in this phase — all returns are synchronous result construction.
   - Recommendation: Include `Loading` for future use (e.g., a loading state in UI) but note that Phase 3 adapters never return `Loading`. The planner may defer this to a later phase.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK | Sealed classes, pattern matching | ✓ | ^3.9.2 | — |
| Flutter | Run/analyze | ✓ | (with SDK) | — |
| `flutter analyze` | Static checking | ✓ | — | — |
| `flutter test` | Unit tests | ✓ | — | — |

**Missing dependencies with no fallback:** None

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | `flutter_test` (sdk) + `test` ^1.25.0 |
| Config file | None — default flutter_test config |
| Quick run command | `flutter test test/scraper/` (once tests created) |
| Full suite command | `flutter test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CODE-02 | ScraperResult sealed class exhaustiveness — all variants handled in switch | unit | `flutter test test/scraper/scraper_result_test.dart` | ❌ Wave 0 |
| CODE-02 | Adapter returns typed errors instead of empty lists | unit | `flutter test test/scraper/adapter_error_test.dart` | ❌ Wave 0 |
| CODE-02 | Orchestrator fallback on Failure continues to other sources | unit | `flutter test test/scraper/orchestrator_fallback_test.dart` | ❌ Wave 0 |
| CODE-02 | Cloudflare detection matches multiple patterns | unit | `flutter test test/scraper/cloudflare_detection_test.dart` | ❌ Wave 0 |
| CODE-03 | SuperFlix WebView uses AppConstants.superFlixBase | unit | `flutter test test/superflix/domain_constants_test.dart` | ❌ Wave 0 |
| BUG-01 | Unparseable episode numbers sort to end (not position 0) | unit | `flutter test test/scraper/episode_sorting_test.dart` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `flutter analyze` (no test command yet)
- **Per wave merge:** `flutter analyze && flutter test test/scraper/`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `test/scraper/scraper_result_test.dart` — covers CODE-02 sealed class exhaustiveness
- [ ] `test/scraper/adapter_error_test.dart` — covers CODE-02 per-adapter error types
- [ ] `test/scraper/orchestrator_fallback_test.dart` — covers CODE-02 fan-out error recovery
- [ ] `test/scraper/cloudflare_detection_test.dart` — covers CODE-02 multi-pattern detection
- [ ] `test/scraper/episode_sorting_test.dart` — covers BUG-01 sentinel sorting
- [ ] `test/superflix/domain_constants_test.dart` — covers CODE-03
- [ ] `test/scraper/` directory — needs creation
- [ ] `test/superflix/` directory — needs creation

## Security Domain

> **Skip:** This phase has no security enforcement surface. CODE-02/CODE-03/BUG-01 are error handling, domain configuration, and sorting fixes. No authentication, session management, access control, input validation, or cryptography changes. Cloudflare detection is a scraping reliability concern, not a security control.

## Sources

### Primary (HIGH confidence)
- [CITED: dart.dev/language/class-modifiers] — Dart 3 sealed class syntax, exhaustive switch, class modifiers. Confirmed `sealed` modifier + `switch` expression pattern.
- [CITED: dart.dev/language/branches] — Exhaustiveness checking with switch expressions.
- [CITED: dart.dev/language/patterns] — Pattern matching, destructuring with `:` syntax.
- [VERIFIED: codebase grep] — All 4 adapter files, anime_scraper.dart, anime_source_adapter.dart, superflix_web_screen.dart, app_constants.dart — read and confirmed all structural claims.
- [VERIFIED: pubspec.yaml] — SDK constraint `^3.9.2` confirmed Dart 3 sealed class support.

### Secondary (MEDIUM confidence)
- [ASSUMED] — `http` package throws `TimeoutException` on timeout (common knowledge, verified by multiple Dart HTTP resources).
- [ASSUMED] — `Future.wait` fails fast behavior (Dart documentation, well-known).

### Tertiary (LOW confidence)
- None — all claims verified against codebase or official Dart documentation.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Dart 3 sealed classes are a verified language feature used correctly per official docs
- Architecture: HIGH — All patterns derived from reading the actual codebase files
- Pitfalls: HIGH — Each pitfall identified from the source code's actual behavior
- Implementation guidance: HIGH — Actionable steps mapped to specific line numbers in verified source files

**Research date:** 2026-07-12
**Valid until:** 2026-08-12 (stable Dart/Flutter release cycle — no breaking changes expected in sealed class semantics)
