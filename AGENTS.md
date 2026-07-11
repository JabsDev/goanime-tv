# GoAnime TV — Project Guide

## Build & Run

```bash
# Get dependencies
flutter pub get

# Run on Android TV emulator
flutter run -d android

# Build release APK
flutter build apk --release

# Build debug APK
flutter build apk --debug
```

### Go FFI Bridge

The SuperFlix scraper uses a Go shared library. To rebuild:

```bash
cd go_superflix
./build_android.sh
```

## Project Structure

```
lib/
├── main.dart                    # Bootstrap (MediaKit init, LocalStorage init)
├── app.dart                     # GoAnimeTVApp (MaterialApp with dark theme)
├── core/
│   ├── anilist/                 # AniList GraphQL client + OAuth pairing server
│   ├── cache/                   # TTL in-memory caches
│   ├── constants/               # URLs, theme colors, app config
│   ├── ffi/                     # Go FFI bridge bindings
│   ├── network/                 # HTTP client with caching
│   ├── scraper/                 # Cross-source orchestration
│   ├── sources/                 # Source adapters (port/adapter pattern)
│   ├── storage/                 # SharedPreferences wrapper
│   └── utils/                   # Text helpers
├── data/
│   ├── models/                  # Anime, Episode, VideoSource, AniList models
│   └── repositories/            # AnimeRepository (fallback cascading)
├── features/
│   ├── home/                    # Home catalog + profile screen
│   ├── search/                  # Search with TV keyboard
│   ├── detail/                  # Anime detail + episode grid
│   ├── player/                  # Video player with TV controls
│   └── superflix/               # WebView Cloudflare bypass
└── shared/
    ├── theme/                   # AppTheme construction
    └── widgets/                 # FocusableCard, TVButton, etc.
```

## Workflow

This project uses GSD (Get Shit Done) for phased execution.

- `/gsd-new-project` — Initialize project (already done)
- `/gsd-plan-phase N` — Plan a phase
- `/gsd-execute-phase N` — Execute a phase
- `/gsd-transition N` — Complete a phase
- `/gsd-progress` — View project progress

## Architecture Notes

- **Source adapters**: Port/adapter pattern with `AnimeSourceAdapter` interface. Four implementations: AnimeFire, AllAnime, SuperFlix, Goyabu.
- **Scraper orchestration**: `AnimeScraper` fans out to all adapters, deduplicates, enriches with AniList.
- **Video playback**: `media_kit` (libmpv-based) with quality selection, resume playback, auto-next.
- **Cloudflare bypass**: Three-tier: Go FFI → Dart HTTP fallback → WebView Turnstile bypass.
