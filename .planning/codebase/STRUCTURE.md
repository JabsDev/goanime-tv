# Structure: GoAnime TV

**Date:** 2026-07-11
**Last updated:** 2026-07-11

## Top-Level Directory Layout

```
goanime-tv/
├── .planning/                  # Planning & documentation
│   ├── codebase/               # Architecture, stack, integrations docs
│   ├── phases/                 # Development phase plans
│   └── ui-reviews/             # UI review assets
├── android/                    # Android host project (Gradle, manifest, resources)
├── build/                      # Build output (gitignored)
├── go_superflix/               # Go cgo shared library for SuperFlix scraping
├── integration_test/           # Flutter integration tests
├── lib/                        # Dart application source
├── .dart_tool/                 # Dart/Flutter tooling cache (gitignored)
├── pubspec.yaml                # Flutter project config & dependencies
├── pubspec.lock                # Dependency lockfile
├── analysis_options.yaml       # Dart linter rules
├── README.md                   # Project overview
└── .gitignore
```

## Naming Conventions

- **Files**: `snake_case.dart` — e.g. `anime_source_adapter.dart`, `app_caches.dart`
- **Classes**: `PascalCase` — e.g. `AnimeScraper`, `SuperFlixWebScreen`, `AnimeSourceAdapter`
- **Constants**: `camelCase` — e.g. `superFlixBase`, `allAnimeAPI`, `requestTimeout`
- **Static singletons**: `lowercaseCamel` — e.g. `apiClient`, `SourceRegistry._()`
- **Private members**: `_lowercaseCamel` — e.g. `_isFocused`, `_handleToken`
- **Enums**: `PascalCase` with `camelCase` values — e.g. `AnimeSource.animeFire`
- **Directories**: `snake_case/` matching feature or layer name
- **Go exports**: `PascalCase` — e.g. `SearchSuperFlix`, `GetSuperFlixEpisodes`

## Key File Locations by Feature

### Entry points
| File | Purpose |
|------|---------|
| `lib/main.dart` | App bootstrap, `MediaKit.ensureInitialized()`, `LocalStorage.init()` |
| `lib/app.dart` | `GoAnimeTVApp` MaterialApp with dark theme |
| `android/app/src/main/kotlin/com/goanime/tv/MainActivity.kt` | Android Flutter entry |

### Core infrastructure
| File | Purpose |
|------|---------|
| `lib/core/constants/app_constants.dart` | URLs (`baseSiteUrl`, `allAnimeAPI`, `superFlixBase`, `goyabuBase`, `anilistApi`), user agent, timeouts |
| `lib/core/constants/theme_constants.dart` | Color palette (`background`, `surface`, `primary`, `accent`, etc.) |
| `lib/core/network/api_client.dart` | HTTP client singleton with GET response caching |
| `lib/core/cache/ttl_cache.dart` | Generic in-memory TTL cache |
| `lib/core/cache/app_caches.dart` | Named cache instances (search, episodes, enrichment, http) |
| `lib/core/storage/local_storage.dart` | SharedPreferences wrapper for progress, history, favorites, token |
| `lib/core/utils/text_utils.dart` | Title normalization, URL parsing |

### Source adapters (port/adapter pattern)
| File | Provider | Mechanism |
|------|----------|-----------|
| `lib/core/sources/anime_source_adapter.dart` | **Abstract interface** | `search`, `getEpisodes`, `getVideoSources` |
| `lib/core/sources/source_registry.dart` | **Registry** | Ordered list of adapters, lookup by `AnimeSource` |
| `lib/core/sources/anime_fire_adapter.dart` | **AnimeFire** (PT-BR) | HTML scraping, Blogger/Google Video extraction |
| `lib/core/sources/all_anime_adapter.dart` | **AllAnime** (EN) | GraphQL API + AES-256-CTR decryption |
| `lib/core/sources/super_flix_adapter.dart` | **SuperFlix** (PT-BR) | FFI bridge + HTTP/2 fallback |
| `lib/core/sources/goyabu_adapter.dart` | **Goyabu** (PT-BR) | WP REST API + HTML + Blogger decode AJAX |

### Scraper orchestration
| File | Purpose |
|------|---------|
| `lib/core/scraper/anime_scraper.dart` | Fan-out search, merge, dedupe, enrich, cache; cross-source episode merging |

### AniList integration
| File | Purpose |
|------|---------|
| `lib/core/anilist/anilist_service.dart` | GraphQL client for catalog, enrichment, user lists, OAuth token management |
| `lib/core/anilist/anilist_pairing_server.dart` | Local HTTP server for QR-based OAuth pairing flow |

### Native FFI bridge
| File | Purpose |
|------|---------|
| `lib/core/ffi/superflix_bridge.dart` | Dart FFI bindings to Go shared library (search, episodes, stream, servers) |
| `go_superflix/superflix_bridge.go` | Go cgo implementation with `utls` TLS fingerprinting and HTTP/2 transport |
| `go_superflix/superflix.h` | Auto-generated C header for cgo exports |
| `go_superflix/superflix.so` | Compiled shared library (output) |
| `go_superflix/build_android.sh` | Cross-compilation script for Android architectures |
| `android/app/src/main/jniLibs/arm64-v8a/libsuperflix.so` | Bundled ARM64 native library |
| `android/app/src/main/jniLibs/x86_64/libsuperflix.so` | Bundled x86_64 native library |

### Data models
| File | Models |
|------|--------|
| `lib/data/models/anime.dart` | `Anime`, `AnimeSource` enum, `AnimeSourcePriority` extension |
| `lib/data/models/episode.dart` | `Episode`, `VideoSource`, `EpisodesResult` |
| `lib/data/models/anilist_models.dart` | `AniListUser`, `AniListMedia`, `AniListEntry`, `AniListCoverImage`, `AniListMediaDetail`, `AniListGraphQLResponse`, `AniListGroup` |

### Repository
| File | Purpose |
|------|---------|
| `lib/data/repositories/anime_repository.dart` | Delegates to `AnimeScraper`, adds fallback cascading for video sources |

### Feature screens
| File | Feature |
|------|---------|
| `lib/features/home/home_screen.dart` | Home catalog (trending, seasonal, AniList lists, history, favorites); `ProfileScreen`; `_AnilistLoginDialog` |
| `lib/features/search/search_screen.dart` | Search with text input and grid results |
| `lib/features/detail/detail_screen.dart` | Anime detail header, episode grid, source selector, quality picker |
| `lib/features/player/player_screen.dart` | Video player with controls, auto-next overlay, progress persistence |
| `lib/features/superflix/superflix_web_screen.dart` | Cloudflare Turnstile bypass via WebView for SuperFlix stream resolution |

### Shared UI
| File | Purpose |
|------|---------|
| `lib/shared/theme/app_theme.dart` | `ThemeData` construction |
| `lib/shared/widgets/focusable_card.dart` | Poster card with focus animation (`FocusableCard`, `FocusableBannerCard`) |
| `lib/shared/widgets/cached_image.dart` | Image with disk/memory caching via `cached_network_image` |
| `lib/shared/widgets/section_header.dart` | Section row with title, accent bar, optional "See All" |
| `lib/shared/widgets/tv_button.dart` | TV-focused button with animated border/shadow |
| `lib/shared/widgets/play_icon.dart` | Custom-painted play triangle icon |

### Tests
| File | Purpose |
|------|---------|
| `integration_test/anilist_catalog_test.dart` | AniList catalog loading E2E test |
| `integration_test/pairing_server_test.dart` | Pairing server integration test |
| `integration_test/scraper_smoke_test.dart` | Scraper smoke test |
| `integration_test/superflix_webview_test.dart` | WebView resolver test |

## Module Organisation

```
lib/
├── main.dart                    # Bootstrap
├── app.dart                     # MaterialApp
├── core/                        # Domain & infrastructure
│   ├── anilist/                 # AniList GraphQL + pairing
│   ├── cache/                   # TTL caching
│   ├── constants/               # Config + theme tokens
│   ├── ffi/                     # Go FFI bindings
│   ├── network/                 # HTTP client
│   ├── scraper/                 # Orchestration
│   ├── sources/                 # Provider adapters (port/adapter)
│   ├── storage/                 # Local persistence
│   └── utils/                   # Text helpers
├── data/                        # Models & repository
│   ├── models/
│   └── repositories/
├── features/                    # Screens by feature
│   ├── home/
│   ├── search/
│   ├── detail/
│   ├── player/
│   └── superflix/
└── shared/                      # Reusable UI
    ├── theme/
    └── widgets/
```

## Go Module (`go_superflix/`)

```
go_superflix/
├── go.mod                       # Module: go_superflix, Go 1.24
├── go.sum                       # Dependency checksums
├── superflix_bridge.go          # Main: cgo exports + SuperFlix scraping logic
├── superflix.h                  # Auto-generated C header
├── superflix.so                 # Compiled shared library
├── build_android.sh             # Cross-compile for Android
├── build/                       # Go build cache
```
