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

## CI/CD

The project uses GitHub Actions for CI:

- **Test pipeline:** Triggered on every push/PR to `main`. Runs `flutter analyze` + `flutter test`.
- **Release pipeline:** Triggered by pushing a version tag (`v1.0.0`). Builds Go FFI library, then produces signed APK + AAB artifacts.
- **Artifacts:** Signed APK and AAB are available for download from the Actions tab (90-day retention).

To trigger a release:
```bash
# After bumping version in pubspec.yaml
git tag v1.0.0
git push origin v1.0.0
# Wait for CI to complete, then download artifacts from GitHub Actions
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

## Testing

```bash
# Run all unit tests
flutter test test/

# Run a single unit test file
flutter test test/core/cache/ttl_cache_test.dart

# Run integration tests (requires connected Android device or emulator)
flutter test integration_test/search_detail_playback_test.dart -d <device-id>

# Run all integration tests
flutter test integration_test/ -d <device-id>
```

### Mocking

Tests use `mocktail` for HTTP and dependency mocking. Install with `flutter pub get` (already in dev_dependencies).

## Workflow

This project uses GSD (Get Shit Done) for phased execution.

- `/gsd-new-project` — Initialize project (already done)
- `/gsd-plan-phase N` — Plan a phase
- `/gsd-execute-phase N` — Execute a phase
- `/gsd-transition N` — Complete a phase
- `/gsd-progress` — View project progress
- [RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) — Play Store submission steps

## Architecture Notes

- **Source adapters**: Port/adapter pattern with `AnimeSourceAdapter` interface. Four implementations: AnimeFire, AllAnime, SuperFlix, Goyabu.
- **Scraper orchestration**: `AnimeScraper` fans out to all adapters, deduplicates, enriches with AniList.
- **Video playback**: `media_kit` (libmpv-based) with quality selection, resume playback, auto-next.
- **Cloudflare bypass**: Three-tier: Go FFI → Dart HTTP fallback → WebView Turnstile bypass.
