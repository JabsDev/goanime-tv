# Phase 3: Error Handling & Bug Fixes - Context

**Gathered:** 2026-07-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Improve scraper robustness and fix known bugs in the source adapter layer. Three requirements: CODE-02 (structured error handling distinguishing timeout, parse failure, Cloudflare, empty results), CODE-03 (SuperFlix domain inconsistency), BUG-01 (episode sorting for unparseable numbers). Also includes hardening the Cloudflare challenge detection check.

All existing search, episode listing, and playback flows must continue to work. Error handling changes are internal to the adapter/scraper layer — the UI should see no behavioral regression.

</domain>

<decisions>
## Implementation Decisions

### Error Type Design
- **D-01:** Use a sealed class `ScraperResult<T>` with three variants: `Loading`, `Success(T)`, `Failure(ScraperError)`. This replaces the blanket `catch (e) { return []; }` pattern with type-safe, exhaustively-matchable results.
- **D-02:** `ScraperError` is a sealed class with five variants: `timeout`, `parseFailure`, `cloudflare`, `emptyResult`, `unknown`. Each is a distinct type so callers can handle each case individually.
- **D-03:** Every error variant carries a human-readable `message`, the `AnimeSource` that failed, and an `operationDuration` Duration. `timeout` carries the configured timeout value. `parseFailure` carries a snippet of what failed to parse. `cloudflare` carries the detection pattern that matched.

### Error Recovery Strategy
- **D-04 (Timeout):** Retry once with the same timeout, then return `Failure(timeout)`. If both attempts fail, the orchestrator falls through to other sources.
- **D-05 (Parse failure):** Return `Failure(parseFailure)` with debug info. No retry — parsing the same response again won't produce a different result. Log the parsing error with contextual snippet.
- **D-06 (Cloudflare):** Return `Failure(cloudflare)`. The orchestrator can try other sources. For SuperFlix, the existing three-tier bypass (FFI → HTTP → WebView) already exists at the adapter level.
- **D-07 (Empty results):** Return `Failure(emptyResult)` — keep it explicit. Distinguishes "no matches found" from "failed to search". The orchestrator and UI can differentiate empty results from failures.

### Cloudflare Detection Robustness
- **D-08:** Replace the single `html.contains('Verificação')` check with a multi-pattern approach: check for `'Verificação'`, `'cf-browser-verification'`, `'cf-challenge'`, HTTP status 403/503, and response headers containing `CF-Ray`/`CF-Challenge`. This is included as part of CODE-02.

### Error Propagation to UI
- **D-09:** Typed errors stay in the log layer. The UI continues to see empty states only. The internal error distinction enables future work (retry buttons, error banners) without changing the adapter layer.

### SuperFlix Domain Fix (CODE-03)
- **D-10:** Use `AppConstants.superFlixBase` as the single source of truth. Replace the hardcoded `'https://superflixapi.pro'` in `superflix_web_screen.dart` with `AppConstants.superFlixBase`. Single change, single point of configuration.

### Episode Sorting Fix (BUG-01)
- **D-11:** Use `double.infinity` / `int.maxValue` as the sort sentinel for unparseable episode numbers, so OVA/Special/special episodes sort to the end of the list instead of position 0. Fix all 5 sort call sites across AnimeFire, Goyabu, SuperFlix, and AllAnime adapters.

### the agent's Discretion
- The exact sealed class file location (e.g., `lib/core/scraper/scraper_result.dart`) is at the planner's discretion
- Whether to convert all adapter methods to return `ScraperResult` or wrap at the orchestrator level — planner decides based on implementation cost vs benefit
- Whether the episode sorting fix should use a shared utility function or inline sentinel values
- The specific list of Cloudflare detection patterns — multi-pattern set can be tuned during planning

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope & requirements
- `.planning/ROADMAP.md` — Phase 3 definition, goal, success criteria, CODE-02/CODE-03/BUG-01 requirement mapping
- `.planning/REQUIREMENTS.md` — CODE-02 (structured error handling), CODE-03 (SuperFlix domain), BUG-01 (episode sorting)

### Codebase analysis
- `.planning/codebase/CONCERNS.md` — [HIGH] scraper error handling (blanket catch), [MEDIUM] Cloudflare detection fragility, [MEDIUM] episode sorting bug, [MEDIUM] SuperFlix domain inconsistency
- `.planning/codebase/ARCHITECTURE.md` — Adapter layer, scraper orchestrator, data flow, source priority
- `.planning/codebase/STRUCTURE.md` — File layout

### Source files to modify
- `lib/core/scraper/anime_scraper.dart` — Orchestrator with blanket catch pattern (lines 55-58, 175-178, 202-205)
- `lib/core/sources/anime_source_adapter.dart` — Adapter interface (may need ScraperResult return types)
- `lib/core/sources/anime_fire_adapter.dart` — Episode sorting bug (line 89) + blanket catch pattern
- `lib/core/sources/goyabu_adapter.dart` — Episode sorting bug (lines 157-158) + blanket catch pattern
- `lib/core/sources/super_flix_adapter.dart` — Cloudflare detection (lines 158-161, 256-258), episode sorting (lines 139, 190), blanket catch
- `lib/core/sources/all_anime_adapter.dart` — Episode sorting (line 155), blanket catch, Cloudflare detection (line 205)
- `lib/features/superflix/superflix_web_screen.dart` — Hardcoded `.pro` domain (line 67)
- `lib/core/constants/app_constants.dart` — `superFlixBase` (line 7) — already correct, used as source of truth

### Prior decisions (Phase 1 & 2 carryforward)
- `.planning/phases/01-security-hardening/01-CONTEXT.md` — Not directly relevant (security concerns were in pairing server)
- `.planning/phases/02-home-screen-refactor/02-CONTEXT.md` — D-03: PKCE WebView fix is a separate deferred step (access_token → code= interception still pending in home_screen.dart)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AppCaches` (`lib/core/cache/app_caches.dart`) — TTL cache pattern can be reused for retry-rate-limiting state if needed
- `AnimeSource` enum (`lib/core/sources/source_registry.dart` or `anime_source_adapter.dart`) — Source identification, needed in error variants
- `debugPrint` pattern — All adapters already use debugPrint for logging; error data can follow the same convention

### Established Patterns
- All adapters implement `AnimeSourceAdapter` interface with `search()`, `getEpisodes()`, `getVideoSources()`
- Every adapter wraps its methods in `try/catch` with `debugPrint` + `return []` — the pattern to replace
- Sorting uses `int.tryParse` / `double.tryParse` with `?? 0` fallback — the bug pattern to fix
- Cloudflare detection uses `html.contains('Verificação')` — the fragile pattern to harden
- `AnimeScraper` orchestrator fans out to all adapters via `Future.wait` and aggregates results

### Integration Points
- `AnimeScraper.searchAnime()` — calls `adapter.search()` for each source; catches errors at line 55
- `AnimeScraper.getEpisodes()` — calls per-source adapters; catches errors at line 175
- `AnimeScraper._findBySource()` — per-source search fallback; catches errors at line 202
- `AnimeRepository` — consumes `AnimeScraper` results; no changes needed if error handling stays in the scraper layer
- `Episode.number` is a `String` — all 5 sort call sites parse it with tryParse

</code_context>

<specifics>
## Specific Ideas

### Error Handling Migration Strategy
1. Create `ScraperResult<T>` and `ScraperError` sealed classes in a new `lib/core/scraper/` file
2. Update `AnimeSourceAdapter` interface return types from `Future<List<Anime>>` to `Future<ScraperResult<List<Anime>>>`
3. Update each adapter's `search()`, `getEpisodes()`, `getVideoSources()` to return typed errors
4. Update `AnimeScraper` to match on error variants and handle fallback
5. Apply episode sorting fix (sentinel pattern) at all 5 sort call sites
6. Apply Cloudflare detection hardening (multi-pattern check) at existing detection points
7. Fix SuperFlix domain in `superflix_web_screen.dart` (`.pro` → `AppConstants.superFlixBase`)

### What NOT to Touch
- Do not change the UI layer — errors stay internal to scraper/adapter
- Do not change AniList OAuth/PKCE code — separate deferred item
- Do not add new source adapters or change scraper fan-out strategy
- Do not introduce a new routing or state management library
- Do not modify shared widgets (`FocusableCard`, `SectionHeader`, etc.)

</specifics>

<deferred>
## Deferred Ideas

### PKCE WebView Fix (from Phase 2 D-03)
The Phase 2 deferred PKCE fix (`access_token=` fragment interception → `code=` query-param interception in home_screen.dart's WebView) is NOT included in Phase 3. It remains a separate deferred item.

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 3-Error Handling & Bug Fixes*
*Context gathered: 2026-07-12*
