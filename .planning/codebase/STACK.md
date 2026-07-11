# Stack: GoAnime TV

**Date:** 2026-07-11
**Last updated:** 2026-07-11

## Languages

- **Dart** — `^3.9.2` — `pubspec.yaml:7`
- **Go** — `go 1.24` — `go_superflix/go.mod:3`

## Runtime

- **Flutter SDK** — `^3.9.2` — [`pubspec.yaml:7`](pubspec.yaml)
- **Go (cgo)** — compiled to a shared library (`superflix.so`) loaded via Dart FFI — `go_superflix/superflix_bridge.go`

## Framework

- **Flutter** — UI framework targetting Android TV — `pubspec.yaml:10`
  - Uses Material Design (`uses-material-design: true`)
  - Android-specific plugins for video playback, WebView, and native event loop

## Dependencies

### Dart / Flutter (pubspec.yaml)

| Package | Version | Purpose |
|---------|---------|---------|
| `flutter` | SDK | UI framework |
| `flutter_localizations` | SDK | i18n / localization |
| `cupertino_icons` | ^1.0.8 | iOS-style icon set |
| `media_kit` | ^1.1.10 | Video playback engine (libmpv-based) |
| `media_kit_video` | ^2.0.0 | Flutter widget wrapping media_kit player |
| `media_kit_native_event_loop` | ^1.0.7 | Native event loop integration for media_kit |
| `media_kit_libs_android_video` | ^1.3.3 | Bundled Android video codec libraries |
| `http` | ^1.1.0 | HTTP client (used by all scrapers and API calls) |
| `html` | ^0.15.4 | HTML DOM parsing (AnimeFire, Goyabu, SuperFlix scrape) |
| `ffi` | ^2.1.0 | Dart FFI to load the Go shared library |
| `encrypt` | ^5.0.0 | AES-256-CTR decryption (AllAnime stream token decode) |
| `pointycastle` | ^3.7.3 | SHA-256 hashing for AllAnime key derivation |
| `cached_network_image` | ^3.3.1 | On-disk and in-memory image caching |
| `shared_preferences` | ^2.2.2 | Local key-value persistence |
| `provider` | ^6.1.1 | State management (change notifier) |
| `qr_flutter` | ^4.1.0 | QR code rendering for AniList pairing |
| `webview_flutter` | ^4.7.0 | WebView for AniList OAuth + Cloudflare Turnstile bypass |
| `intl` | any | Date/time formatting (transitive) |

### Go (go_superflix/go.mod)

| Package | Version | Purpose |
|---------|---------|---------|
| `github.com/PuerkitoBio/goquery` | v1.9.2 | HTML parsing and CSS selector extraction |
| `github.com/refraction-networking/utls` | v1.6.6 | TLS fingerprint impersonation (HTTP/2 bypass) |
| `golang.org/x/net` | v0.24.0 | HTTP/2 transport, net utilities |

### Dev dependencies

| Package | Purpose |
|---------|---------|
| `flutter_test` (SDK) | Unit testing |
| `integration_test` (SDK) | Integration / E2E testing |
| `flutter_lints` ^6.0.0 | Recommended lint rules |

## Configuration

| File | Purpose |
|------|---------|
| `pubspec.yaml` | Project metadata, dependency declarations, SDK constraints |
| `analysis_options.yaml` | Dart linter rules (extends `flutter_lints`) |
| `go_superflix/go.mod` | Go module definition and dependency pins |
| `android/app/build.gradle` | Android app build config (minSdk, targetSdk, etc.) |
| `android/settings.gradle` | Android project module settings |
| `android/build.gradle` | Android top-level Gradle config |
| `.gitignore` | Ignored files (`.dart_tool/`, `build/`, `*.so`, etc.) |
