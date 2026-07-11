# Code Conventions: GoAnime TV

**Date:** 2026-07-11

## Code Style & Formatting

- **Language:** Dart `^3.9.2` with Flutter SDK.
- **Lints:** Extends `package:flutter_lints/flutter.yaml` (`analysis_options.yaml:1`). Two overrides:
  - `prefer_const_constructors: false`
  - `prefer_const_literals_to_create_immutables: false`
- **No generated code** (no freezed, json_serializable, retrofit).
- **Go code** (`go_superflix/superflix_bridge.go`) uses standard `gofmt` style, Go 1.24.
- **Indentation:** 2-space for Dart, tabs for Go.
- **File length:** No enforced limit; source files range from ~17 lines (`app.dart`) to ~1,320 lines (`home_screen.dart`).

## Naming Conventions

| Category | Convention | Example |
|----------|-----------|---------|
| Classes | `PascalCase` | `AnimeScraper`, `SuperFlixAdapter` |
| Enums | `PascalCase` | `AnimeSource` (`anime.dart:48`) |
| Enum values | `camelCase` | `AnimeSource.animeFire` |
| Extensions | `PascalCase` | `AnimeSourcePriority` (`anime.dart:50`) |
| Private members | `_camelCase` | `_adapters`, `_extractSources` |
| Top-level constants | `lowerCamelCase` | `apiClient` (`api_client.dart:70`) |
| Static consts | `camelCase` | `AppConstants.requestTimeout` |
| Widget state classes | `_PascalCaseState` | `_HomeScreenState`, `_DetailScreenState` |
| Private classes | `_PascalCase` | `_CacheEntry`, `_ResolvedInfo` |
| File names | `snake_case` | `anime_fire_adapter.dart`, `ttl_cache.dart` |
| Go exported funcs | `PascalCase` | `SearchSuperFlix`, `FreeCString` |
| Go types | `PascalCase` | `SearchResult`, `EpisodeItem` |
| Record types | `PascalCase` | `AniListMediaDetail`, `VideoSource` |

## Imports Organization

All Dart files follow this order with blank-line separation:

1. Dart SDK (`dart:convert`, `dart:ffi`, etc.)
2. Flutter SDK (`package:flutter/...`)
3. Third-party packages (`package:http/...`, `package:html/...`)
4. Project imports (relative paths from `lib/`)

Example from `anime_scraper.dart:1-6`:
```dart
import 'package:flutter/foundation.dart';
import '../anilist/anilist_service.dart';
import '../cache/app_caches.dart';
import '../sources/source_registry.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
```

Go imports follow standard `goimports` convention (stdlib first, then third-party).

## Package / Directory Layout

```
lib/
├── main.dart, app.dart              — Entry point + app shell
├── core/
│   ├── anilist/                     — AniList OAuth, GraphQL, pairing server
│   ├── cache/                       — TTL in-memory cache (TtlCache, AppCaches)
│   ├── constants/                   — AppConstants, ThemeConstants
│   ├── ffi/                         — Dart FFI bridge to Go shared lib
│   ├── network/                     — ApiClient (thin http wrapper + cache)
│   ├── scraper/                     — AnimeScraper orchestration layer
│   ├── sources/                     — Adapters per provider (AnimeFire, AllAnime, etc.)
│   ├── storage/                     — LocalStorage (SharedPreferences wrapper)
│   └── utils/                       — TextUtils normalisation helpers
├── data/
│   ├── models/                      — Anime, Episode, VideoSource, EpisodesResult, AniList models
│   └── repositories/                — AnimeRepository (delegates to AnimeScraper + SourceRegistry)
├── features/
│   ├── home/                        — Home screen, Profile screen, AniList login dialog
│   ├── search/                      — Search screen with TV keyboard
│   ├── detail/                      — Detail screen with episode grid, quality picker
│   ├── player/                      — Video player with media_kit, OSD controls, auto-next
│   └── superflix/                   — WebView screen for SuperFlix Turnstile bypass
└── shared/
    ├── widgets/                     — FocusableCard, CachedImage, SectionHeader, TVButton, PlayIcon
    └── theme/                       — AppTheme (dark theme definition)
```

## Error Handling Patterns

### `exception → return empty/default` (most common)
Public methods catch all exceptions and return an empty result instead of propagating:
```dart
// anime_scraper.dart:55-58
} catch (e) {
  debugPrint('[AnimeScraper] Search error: $e');
  return [];
}
```

### `try/catch + debugPrint` (everywhere)
Every scraper adapter wraps its public methods in try/catch. Exceptions are logged and never rethrown. There are **no custom exception classes** and **no `Result` types** — empty collections signal failure.

### `throw` only for developer errors
- `LocalStorage.ensureInitialized()` throws if `init()` wasn't called (`local_storage.dart:17-21`).
- `AppConstants` values are hardcoded (no runtime validation).

### Guard clauses with `!mounted`
Every async method in `StatefulWidget` classes checks `if (!mounted) return;` after `await` to prevent calling `setState` on disposed widgets (e.g., `detail_screen.dart:607`, `player_screen.dart:88`).

### Timeout pattern
Network calls use `.timeout(AppConstants.requestTimeout)` which is 15 seconds (`app_constants.dart:17`). The player also has a separate 20-second load timer (`player_screen.dart:119-126`).

### Error recovery at the top level
`main.dart:9-30` wraps initialization in try/catch and renders a fallback `MaterialApp` on failure.

## Common Patterns

### Adapter pattern for scraping sources
`AnimeSourceAdapter` (`anime_source_adapter.dart:14`) defines a uniform interface. Each provider implements `search()`, `getEpisodes()`, `getVideoSources()`. Registered in `SourceRegistry` (`source_registry.dart:13`).

### TTL-based in-memory caching
`TtlCache` (`ttl_cache.dart`) is a simple `Map<String, _CacheEntry>` with per-entry expiry. Used by `AppCaches` (`app_caches.dart`) for search results (30 min), episodes (1 h), enrichment (24 h), HTTP responses (5 min).

### In-flight deduplication
`AniListService._enrichInflight` (`anilist_service.dart:263`) uses a `Map<String, Future>` so concurrent enrich calls for the same title share one network request.

### Singleton (lazy)
`SuperFlixFFI.instance` (`superflix_bridge.dart:30`) — lazy singleton for the native library handle.

### Const constructor on stateless widgets
All `const`-eligible widgets use `const` constructors (e.g., `const SuperFlixAdapter()`, `const SearchScreen({super.key})`).

### `withValues(alpha:)` for opacity
Modern Flutter API: `ThemeConstants.primary.withValues(alpha: 0.5)` instead of `withOpacity(0.5)`.

### Cascading extraction fallbacks
`AnimeFireAdapter._extractFromAnimeFire` tries 6 strategies in order (JSON API → data-video-src → video element → Blogger iframe → data attributes → regex). GoyabuAdapter has a similar cascade.

### FFI with Dart `dart:ffi` + Go (cgo)
Go functions compiled via `cgo` into `libsuperflix.so`. Dart loads it via `DynamicLibrary.open()` in `SuperFlixFFI` (`superflix_bridge.dart`). Memory is managed with `malloc`/`free`.

### Multi-level stream resolution for SuperFlix
Two paths: (1) Go FFI bridge with TLS fingerprinting (preferred), (2) Dart HTTP fallback that mirrors the Go logic, (3) WebView Turnstile bypass for Cloudflare-gated player pages.

### Focus-based TV navigation
All interactive widgets use `Focus` + `onFocusChange` + `AnimatedContainer`/`AnimatedScale` for visual feedback (`focusable_card.dart:34-46`, `tv_button.dart:29-30`). `Semantics(button: true)` is wrapped around every tappable element.

### Provider pattern for state routing
Stream URL resolution is handled via `showDialog` + `Navigator.push` that returns results (e.g., `SuperFlixWebScreen.resolve()` returns `Future<List<VideoSource>>`). No global state management beyond what's built-in.

### `EpisodesResult` for multi-source episode merging
`EpisodesResult` (`episode.dart:42-46`) carries both a primary list and a map of named source options, used when episodes from different providers are merged.

## Testing Conventions

(Refer to `.planning/codebase/TESTING.md` for full details.)
