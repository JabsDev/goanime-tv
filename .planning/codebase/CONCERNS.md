# Codebase Concerns

**Date:** 2026-07-11  
**Scope:** Full project audit for technical debt, security, performance, and fragility.

---

## Security

### [CRITICAL] Hardcoded AniList OAuth client secret
`lib/core/constants/app_constants.dart:13` — `anilistClientSecret` is committed in plaintext (`9JIiqT5UFM9YxG7RlaRiSatrOTjEqHJ3E0WaKpGD`). For a public native app this is somewhat expected (native apps cannot truly hide secrets), but it should be documented as a public secret and ideally handled server-side or via PKCE.

### [HIGH] OAuth token transmitted in plaintext over LAN
`lib/core/anilist/anilist_pairing_server.dart` — The pairing server runs on HTTP (no TLS). The AniList access token is POSTed from the phone to the TV in cleartext over the local network. Any device on the same LAN can intercept it.

### [HIGH] Local pairing server binds to 0.0.0.0 with no auth
`lib/core/anilist/anilist_pairing_server.dart:43` — `HttpServer.bind(InternetAddress.anyIPv4, port)` listens on all interfaces. There is no authentication or CSRF protection; any device on the LAN can POST arbitrary tokens or inject data.

### [MEDIUM] Hardcoded encryption key for AllAnime
`lib/core/sources/all_anime_adapter.dart:18` — AES-256-CTR key phrase `Xot36i3lK3:v1` is hardcoded. If the upstream provider rotates this key, stream resolution breaks silently.

### [MEDIUM] Hardcoded persistent query hash
`lib/core/sources/all_anime_adapter.dart:17` — SHA-256 hash `d405d0edd690624b...` is a magic value with no documentation on how to regenerate it.

### [MEDIUM] `webview_flutter` with unrestricted JavaScript
`lib/features/superflix/superflix_web_screen.dart:74` — `JavaScriptMode.unrestricted` allows arbitrary JS execution in the WebView. Injected JS (`_extractionJs`) performs credentialed fetch calls against the upstream origin.

### [MEDIUM] TLS fingerprint spoofing in Go bridge
`go_superflix/superflix_bridge.go:45-46` — Uses `utls` library with `HelloChrome_Auto` to bypass Cloudflare TLS fingerprint checks. This is inherently fragile and could be considered a violation of the upstream's ToS.

### [LOW] Hardcoded credentials in `.env`-less constants
`lib/core/constants/app_constants.dart:12` — AniList client ID (`44217`) is hardcoded alongside the secret. No environment-based config mechanism exists.

---

## Technical Debt

### [HIGH] `home_screen.dart` is 1320 lines
`lib/features/home/home_screen.dart` — Contains `HomeScreen`, `_AnilistLoginDialog` (with WebView + pairing logic), `_FocusableAnilistBanner`, and `ProfileScreen`. Should be split into separate files:
- `lib/features/home/home_screen.dart` (keep ~400 lines)
- `lib/features/home/anilist_login_dialog.dart`
- `lib/features/home/profile_screen.dart`

### [MEDIUM] `superflix_bridge.go` is 932 lines
`go_superflix/superflix_bridge.go` — One file contains HTTP client setup, search, episode parsing, stream resolution, redirect resolution, subtitle extraction, and C exports. Should be split:
- `client.go` (HTTP setup)
- `search.go`
- `episodes.go`
- `stream.go`
- `bridge.go` (C exports)

### [MEDIUM] Duplicated stream resolution logic between Dart and Go
`lib/core/sources/super_flix_adapter.dart:239-362` and `go_superflix/superflix_bridge.go:748-930` — The entire SuperFlix stream resolution (bootstrap → source → redirect → getVideo) is implemented twice: once in Go (native FFI) and once in Dart (HTTP fallback). Any bug fix or upstream change must be ported to both.

### [MEDIUM] Two different storage access patterns
`lib/core/anilist/anilist_service.dart` accesses `SharedPreferences` directly, while all other storage goes through `LocalStorage` (`lib/core/storage/local_storage.dart`). This bypasses the abstraction and makes future storage migrations harder.

### [MEDIUM] `Anime` model is fully mutable
`lib/data/models/anime.dart:2-14` — All fields are mutable (`String name`, `String url`, `AnimeSource source`, etc.). Mutation is used for enrichment (`anilist_service.dart:288-298`) but makes it harder to reason about state changes and introduces aliasing bugs.

### [MEDIUM] TtlCache "recency refresh" is O(n)
`lib/core/cache/ttl_cache.dart:24-25` — `_store.remove(key); _store[key] = entry;` on Dart's default `LinkedHashMap` is O(1) for remove+put, but the eviction strategy (`_store.remove(_store.keys.first)`) is fragile and does not implement true LRU.

### [LOW] No `AGENTS.md` or architecture ADRs
No architectural decision records exist. Key decisions (FFI vs HTTP-only, source priority, pairing protocol) are undocumented.

### [LOW] `withValues(alpha:)` replaces deprecated `withOpacity()`
Used throughout. This is correct for the SDK version (`^3.9.2`), but leftover `withOpacity()` calls were found in code history.

---

## Bugs & Fragile Areas

### [HIGH] Scraper error handling swallows all exceptions
Every adapter catches all exceptions with `catch (e) { debugPrint(...); return []; }`. This makes it impossible to distinguish between:
- Network timeout (should retry)
- HTML structure change (should alert developer)
- Cloudflare challenge (should fall back differently)
- Actual empty results (valid state)

### [MEDIUM] Cloudflare challenge detection is fragile
`lib/core/sources/super_flix_adapter.dart:158-162` and `go_superflix/superflix_bridge.go` — Detection relies on checking for the Portuguese string `'Verificação'` (`Verificação`). If Cloudflare changes its challenge page template or locale, the check fails silently.

### [MEDIUM] `apiClient.get` caches 200 responses only, but returns cached 200 for redirects
`lib/core/network/api_client.dart:33-35` — Only HTTP 200 responses are cached. Redirects (301/302) are not cached, so every request to a redirecting URL goes to the network. This may cause extra round-trips for sources that have moved.

### [MEDIUM] Episode sorting uses `parse` which silently defaults to 0
`lib/core/sources/anime_fire_adapter.dart:89-91`, `goyabu_adapter.dart:157-159` — `int.tryParse(a.number) ?? 0` means any unparseable episode number sorts to position 0, potentially mis-ordering special episodes.

### [MEDIUM] SuperFlix adapter uses `.pro` domain in WebView but `.best` everywhere else
`lib/features/superflix/superflix_web_screen.dart:67` — Hardcoded `superflixapi.pro` while `lib/core/constants/app_constants.dart:7` defines `superflixapi.best`. If `.pro` goes offline while `.best` is active, the WebView fallback breaks independently.

### [LOW] Home screen timeout exception log is unhelpful
`lib/features/home/home_screen.dart:62` — `catch (_) { }` — Timeout errors are swallowed with no debug log, making it hard to diagnose slow startup.

### [LOW] `_openAnilistDetail` creates Anime with empty URL
`lib/features/home/home_screen.dart:563-568` — `Anime(url: '')` means the detail screen cannot resolve episodes from the originating source. Relies entirely on name-based cross-provider search.

---

## Performance

### [MEDIUM] No response streaming — all bodies read into memory
`go_superflix/superflix_bridge.go:185-189` and all Dart scrapers — Response bodies are fully read into memory (`io.ReadAll`, `res.body`). For video pages or search result pages (which can be large), this adds allocation pressure on low-end Android TV devices.

### [MEDIUM] `Future.wait` on all sources for search floods the network
`lib/core/scraper/anime_scraper.dart:22-24` — Kicks off searches to all 4 providers in parallel. On a slow connection or when multiple sources are down, this amplifies latency. Consider a race pattern (first result wins) or staggered timeouts.

### [LOW] No image disk cache warmup
`lib/shared/widgets/cached_image.dart` — Uses `cached_network_image` which caches to disk, but there is no pre-warm for rows that are scrolled into view (e.g., the next batch of trending or search results).

### [LOW] TTL cache eviction is not size-aware per-entry
`lib/core/cache/ttl_cache.dart:30-32` — Eviction removes the first key regardless of entry size. A 5MB HTML page and a 100-byte search result are treated equally.

---

## Maintainability

### [MEDIUM] Hardcoded upstream URLs in multiple places
`lib/core/constants/app_constants.dart` defines base URLs, but `superflix_web_screen.dart:67` hardcodes `superflixapi.pro`. The Go bridge (`go_superflix/superflix_bridge.go:26`) hardcodes `superflixapi.best` independently.

### [MEDIUM] Magic numbers and undocumented constants
- `lib/core/sources/all_anime_adapter.dart:17` — Persisted query SHA hash (no explanation of how it's derived)
- `lib/core/sources/all_anime_adapter.dart:18` — Key phrase `Xot36i3lK3:v1`
- `lib/core/anilist/anilist_pairing_server.dart:41` — Port list `[8090, 8091, 8092, 8093, 8099]`
- `lib/core/anilist/anilist_pairing_server.dart:186-190` — Private IP heuristic (`192.168.`, `10.`, `172.`)

### [LOW] Export name `SearchSuperFlix` does not follow Go convention
`go_superflix/superflix_bridge.go:110` — `//export SearchSuperFlix` uses PascalCase. While required by CGo, the function name exported to Dart should be documented.

### [LOW] `main()` in Go bridge is empty
`go_superflix/superflix_bridge.go:932` — Required for `package main` but provides no CLI entry point. This is normal for a C-shared library but could be confusing.

---

## Summary

| Category | Count |
|---|---|
| Security (CRITICAL/HIGH) | 3 |
| Security (MEDIUM/LOW) | 4 |
| Technical Debt (HIGH) | 1 |
| Technical Debt (MEDIUM) | 4 |
| Bugs & Fragile (HIGH) | 1 |
| Bugs & Fragile (MEDIUM) | 4 |
| Performance (MEDIUM) | 2 |
| Maintainability (MEDIUM) | 2 |

**Top 3 priorities:**
1. Remove hardcoded AniList client secret or document it as public-insecure
2. Split `home_screen.dart` (1320 lines) into focused components
3. Add structured error handling to scraper layer instead of blanket `catch => return []`
