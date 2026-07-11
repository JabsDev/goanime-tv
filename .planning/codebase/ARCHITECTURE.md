# Architecture: GoAnime TV

**Date:** 2026-07-11
**Last updated:** 2026-07-11

## Architectural Pattern

The app follows a **layered architecture with feature-based organisation** on top of Flutter. It is not pure Clean Architecture (no use-case layer), but the boundaries are:

```
UI Layer (features/)
  |
  v
Repository Layer (data/repositories/)
  |
  v
Core / Domain (core/)
  |
  v
External (network, FFI, scrapers, storage)
```

The orchestrator (`AnimeScraper`) sits in `core/scraper/` and acts as a **mediator** between the source adapters and the AniList enrichment service, merging multi-provider results into a single response. Data flows **down** (UI → repo → scraper → adapters → network) and results flow **up** (adapters → scraper → repo → UI widgets).

## Layers and Boundaries

### 1. UI Layer (`lib/features/`)
Flutter `StatefulWidget` / `StatelessWidget` screens. Each subdirectory is a **feature** containing its own screen(s) and tightly-coupled private widgets. No business logic lives here — screens call `AnimeRepository` and set state.

| Feature | Entry point | Responsibility |
|---------|------------|----------------|
| `home/` | `HomeScreen` | Catalog rows (AniList trending/seasonal, history, favorites); AniList login dialog; `ProfileScreen` |
| `search/` | `SearchScreen` | Query input, grid results, navigation to detail |
| `detail/` | `DetailScreen` | Anime metadata display, episode grid, source selector, quality picker dialog |
| `player/` | `PlayerScreen` | Video playback via `media_kit`, controls overlay, auto-next overlay, progress saving |
| `superflix/` | `SuperFlixWebScreen` | Cloudflare Turnstile bypass via WebView; resolves SuperFlix video URLs |

### 2. Repository Layer (`lib/data/repositories/`)
`AnimeRepository` wraps the scraper with fallback logic. It adds **cross-source video resolution fallback**: if the primary source fails, it tries every other adapter. It also resolves per-source context (TMDB id, AllAnime id) needed for fallback providers.

### 3. Data Models (`lib/data/models/`)
Plain Dart value objects without behaviour:
- `Anime` — title, URLs per provider, AniList enrichment fields
- `Episode` — number, URL, tagged source + owner
- `VideoSource` — URL, quality label, HTTP headers
- `EpisodesResult` — flat episode list + multi-source grouped map
- `AniListUser`, `AniListMedia`, `AniListEntry`, `AniListCoverImage`, `AniListMediaDetail`, `AniListGroup`, `AniListGraphQLResponse`

### 4. Core / Domain (`lib/core/`)

| Sub-layer | Files | Role |
|-----------|-------|------|
| `sources/` | `anime_source_adapter.dart`, `anime_fire_adapter.dart`, `all_anime_adapter.dart`, `super_flix_adapter.dart`, `goyabu_adapter.dart`, `source_registry.dart` | **Port/Adapter pattern**: `AnimeSourceAdapter` defines the contract; four concrete adapters implement search/list-episodes/get-video-sources. `SourceRegistry` holds the ordered list and provides lookup. |
| `scraper/` | `anime_scraper.dart` | **Orchestrator**: fans out search across all adapters, deduplicates, enriches with AniList, merges episode lists from multiple providers, applies caching. |
| `anilist/` | `anilist_service.dart`, `anilist_pairing_server.dart` | AniList GraphQL client (catalog, enrichment, user lists, OAuth token management). Pairing server is a local HTTP server for QR-code-based login. |
| `cache/` | `ttl_cache.dart`, `app_caches.dart` | In-memory TTL cache with per-entry expiry and LRU-ish eviction. Four named caches with tuned TTLs. |
| `network/` | `api_client.dart` | Thin `http` wrapper with transparent GET response caching. |
| `ffi/` | `superflix_bridge.dart` | Dart FFI bindings to the Go shared library (`libsuperflix.so`). |
| `storage/` | `local_storage.dart` | `SharedPreferences` wrapper for watch progress, history, favorites, AniList token. |
| `constants/` | `app_constants.dart`, `theme_constants.dart` | URLs, user-agent, timeouts; color palette and spacing constants. |
| `utils/` | `text_utils.dart` | Title normalization, URL parsing helpers. |

### 5. Shared (`lib/shared/`)

| Sub-layer | Files | Role |
|-----------|-------|------|
| `theme/` | `app_theme.dart` | `ThemeData` construction using `ThemeConstants`. |
| `widgets/` | `focusable_card.dart`, `focusable_banner_card.dart`, `cached_image.dart`, `section_header.dart`, `tv_button.dart`, `play_icon.dart` | Reusable TV-focused widgets with focus animations, image caching, and consistent styling. |

### 6. Native / Go (`go_superflix/`)
`superflix_bridge.go` — a standalone Go program compiled via cgo into a shared library. Provides `SearchSuperFlix`, `GetSuperFlixEpisodes`, `GetSuperFlixStream`, `GetSuperFlixServers`. Uses `utls` (TLS fingerprinting library) and HTTP/2 transport to bypass Cloudflare on SuperFlix.

## Data Flow

### Search flow
```
User types query
  -> SearchScreen calls AnimeRepository.searchAnime()
    -> AnimeScraper.searchAnime() [cached]
      -> SourceRegistry.adapters.map(a => a.search())  [parallel fan-out]
        -> AnimeFireAdapter.search()       HTML scrape
        -> GoyabuAdapter.search()          WP REST API + HTML
        -> SuperFlixAdapter.search()       FFI bridge + HTML
        -> AllAnimeAdapter.search()        GraphQL API
      -> Filter invalid results
      -> AniListService.enrich() per anime [deduped by cleaned title]
      -> Sort by source priority (PT-BR first)
      -> Cache result (30 min TTL)
    <- List<Anime>
```

### Episode resolution flow
```
User taps anime card
  -> DetailScreen calls AnimeRepository.getEpisodes()
    -> AnimeScraper.getEpisodes() [cached]
      -> Identify the anime's own source
      -> Search each remaining source to find match by name
      -> Fan-out episode fetches to all adapters that found a match
      -> Tag each Episode with its source + owner Anime
      -> Group by source (for multi-source selector)
      -> Cache (1 h TTL)
    <- EpisodesResult(episodes, sourceOptions)
```

### Video playback flow
```
User taps episode -> quality picker dialog
  -> AnimeRepository.getVideoSources()
    -> Try primary source's adapter.getVideoSources()
    -> If empty, try every other adapter as fallback
    -> Deduplicate by URL
    -> For SuperFlix: try FFI, then HTTP, then WebView bypass
  -> PlayerScreen opens media_kit Player with selected source
    -> Streams position, duration, completion
    -> Saves watch progress to LocalStorage
    -> Auto-next overlay triggers after 80% completion
```

### AniList enrichment flow
```
AnimeScraper calls AniListService.enrich(anime)
  -> Title cleaned via TextUtils.cleanTitle()
  -> Check AppCaches.enrichment (24 h TTL)
  -> Deduplicate in-flight requests by cleaned title
  -> GraphQL query: Media(search, type: ANIME)
  -> Apply returned metadata (banner, description, score, genres, status) onto Anime object
```

## Key Abstractions

| Abstraction | File | Purpose |
|------------|------|---------|
| `AnimeSourceAdapter` interface | `lib/core/sources/anime_source_adapter.dart:14` | Port for any anime provider. Three methods: `search`, `getEpisodes`, `getVideoSources`. |
| `SourceRegistry` | `lib/core/sources/source_registry.dart:9` | Global registry of source adapters with lookup by `AnimeSource` enum. |
| `AnimeScraper` (static methods) | `lib/core/scraper/anime_scraper.dart:14` | Orchestrator that fans out to adapters, deduplicates, enriches, caches. |
| `AnimeRepository` | `lib/data/repositories/anime_repository.dart:8` | Thin wrapper with fallback cascading for video source resolution. |
| `AppCaches` (static caches) | `lib/core/cache/app_caches.dart:10` | Four `TtlCache` instances with different TTLs (search, episodes, enrichment, http). |
| `ApiClient` (const singleton) | `lib/core/network/api_client.dart:10` | HTTP client with transparent GET caching. |
| `LocalStorage` (static) | `lib/core/storage/local_storage.dart:5` | SharedPreferences wrapper for persistent state. |
| `SuperFlixFFI` (singleton) | `lib/core/ffi/superflix_bridge.dart:18` | Lazy-loaded Dart FFI bindings to Go shared library. |
| `AniListPairingServer` | `lib/core/anilist/anilist_pairing_server.dart:21` | Local HTTP server for QR-based OAuth pairing. |
| `AppTheme` | `lib/shared/theme/app_theme.dart:4` | Constructs dark `ThemeData` from `ThemeConstants`. |

## Entry Points

| File | Role |
|------|------|
| `lib/main.dart` | App bootstrap: initialises `MediaKit`, `LocalStorage`, then runs `GoAnimeTVApp`. Error fallback renders a minimal MaterialApp. |
| `lib/app.dart` | `GoAnimeTVApp` StatelessWidget: creates `MaterialApp` with dark theme, home set to `HomeScreen`. |
| `android/app/src/main/kotlin/com/goanime/tv/MainActivity.kt` | Android `FlutterActivity` entry point. |
| `go_superflix/superflix_bridge.go` | Go `main()` function (compiled via cgo); exports C-accessible functions. |

## Cross-cutting Concerns

- **Caching**: All major data paths go through `TtlCache` with feature-appropriate TTLs. HTTP GET responses are also cached for 5 min via `ApiClient`. In-flight request deduplication is done for AniList enrichment.
- **Error handling**: Every scraper/adapter method catches exceptions and returns empty results. The UI checks for empty lists and shows appropriate empty/error states.
- **Source priority**: PT-BR sources (AnimeFire → Goyabu → SuperFlix) are ranked before AllAnime. This influences sort order in search results and episode source selection.
- **Cloudflare bypass**: Three-tier strategy for SuperFlix: (1) Go FFI bridge with `utls` and HTTP/2, (2) pure Dart HTTP fallback following the same API flow, (3) WebView-based Turnstile bypass in `SuperFlixWebScreen`.
