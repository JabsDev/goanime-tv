# GoAnime TV

Android TV app for anime streaming based on [GoAnime](https://github.com/alvarorichard/GoAnime) scraping engine.

## Features

- **Home Screen** with trending, recent, and continue-watching sections
- **Search** with on-screen TV keyboard and multi-source results
- **Detail Screen** with episode grid, genres, and favorite toggle
- **Video Player** with quality selection, resume playback, and auto-next episode
- **Profile** with watch history and favorites

## Build Instructions

### Prerequisites

- Flutter SDK 3.9.2+
- Android Studio with Android TV emulator

### Setup

```bash
flutter pub get
```

### Run on Android TV emulator

```bash
flutter run -d android
```

### Build APK

```bash
flutter build apk --debug
```

APK output: `build/app/outputs/flutter-apk/app-debug.apk`

### Build Release APK

```bash
flutter build apk --release
```

## Architecture

```
lib/
├── main.dart                    # Entry point
├── app.dart                     # App shell
├── core/
│   ├── constants/               # URLs, configs, theme values
│   ├── scraper/                 # AnimeFire & AllAnime scraping
│   └── storage/                 # SharedPreferences wrapper
├── data/
│   ├── models/                  # Anime, Episode, VideoSource
│   └── repositories/            # AnimeRepository
├── features/
│   ├── home/                    # Home screen + Profile
│   ├── search/                  # Search with TV keyboard
│   ├── detail/                  # Anime detail + episodes
│   └── player/                  # Video player with TV controls
└── shared/
    ├── widgets/                 # FocusableCard, TVButton
    └── theme/                   # Dark TV theme
```

## Sources

- **AnimeFire** (PT-BR) — HTML scraping
- **AllAnime** (EN) — GraphQL API

## Disclaimer

For personal/educational use only.
