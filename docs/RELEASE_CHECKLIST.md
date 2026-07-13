# GoAnime TV — Release Checklist v1.0

## Prerequisites

- [ ] Play Console account created ($25 one-time fee) and Developer Registration completed
- [ ] Google Play App Signing enrolled (checked during first upload)
- [ ] Upload keystore generated: `keytool -genkey -v -keystore android/app/upload-keystore.jks -alias goanime-tv-upload -keyalg RSA -keysize 2048 -validity 10000`
- [ ] Keystore backup saved to secure location (NOT in repo)
- [ ] GitHub Secrets configured: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
- [ ] All Play Store listing assets prepared (screenshots, banner, feature graphic, privacy policy)

## Version Bump

- [ ] Update `pubspec.yaml` version (e.g., `1.0.0+1000000` for v1.0.0). Per D-06: versionCode = major*1000000 + minor*10000 + patch.
- [ ] Run `flutter pub get` to verify version resolves
- [ ] Commit: `git commit -m "chore: bump version to X.Y.Z"`
- [ ] Create and push tag: `git tag vX.Y.Z && git push origin vX.Y.Z`

## CI Verification

- [ ] Wait for GitHub Actions release workflow to complete (check Actions tab)
- [ ] Verify test job passed (flutter analyze + flutter test)
- [ ] Verify release job completed successfully (Go FFI build + signed APK + AAB)
- [ ] Download signed APK + AAB from workflow artifacts (`goanime-tv-release-vX.Y.Z`)

## Local Verification

- [ ] Install APK on Android TV device or emulator: `flutter install build/app/outputs/flutter-apk/app-release.apk`
- [ ] Verify search, detail, and playback flows work correctly
- [ ] Verify no debug print statements visible in release build (check `flutter logs`)
- [ ] Verify app icon and name display correctly

## Play Store Listing

- [ ] Create or update store listing in Play Console
- [ ] Full description (PT-BR): `Aplicativo Android TV para assistir anime de múltiplas fontes...`
- [ ] Short description (PT-BR): `Assista anime de AnimeFire, AllAnime, SuperFlix e Goyabu em um só lugar`
- [ ] Full description (English): `Android TV app for watching anime from multiple sources...`
- [ ] Short description (English): `Watch anime from AnimeFire, AllAnime, SuperFlix and Goyabu in one place`
- [ ] Upload screenshots (1920x1080 landscape, 16:9) — at least 2, up to 8
- [ ] Upload TV banner (1280x720)
- [ ] Upload feature graphic (1024x500)
- [ ] Set app category: Entertainment
- [ ] Set content rating: Complete questionnaire

## Privacy & Data Safety

- [ ] Host privacy_policy.md (from assets/) at a public URL (GitHub Pages, or personal website)
- [ ] Enter privacy policy URL in Play Console
- [ ] Complete Data Safety section in Play Console:
  - Data collected: Personal info (optional, AniList OAuth name/avatar)
  - Data collected: App activity (watch history, favorites — stored locally)
  - No data shared with third parties (scraped sources are read-only)
- [ ] Declare ads: No

## App Content

- [ ] Target SDK: Comply with 2026 requirements (targetSdk 35)
- [ ] 64-bit architecture: Verified (arm64-v8a + x86_64 .so files exist)
- [ ] 16KB page size: Verify Go shared library alignment (research needed — see RESEARCH.md Open Questions)
- [ ] Android TV requirements: Leanback launcher icon, TV-optimized, gamepad support not needed
- [ ] Complete "App content" section in Play Console

## Production Deployment

- [ ] Upload AAB (`build/app/outputs/bundle/release/app-release.aab`) to Play Console
- [ ] Review release details (release name, release notes/what's new)
- [ ] Select rollout percentage (start at 100% for initial release or staged rollout)
- [ ] Submit for review
- [ ] Monitor review status in Play Console (typically 1-3 days)
- [ ] After approval: App goes live on Play Store

## Post-Release

- [ ] Verify app appears in Play Store search
- [ ] Install from Play Store on Android TV device
- [ ] Verify all features work in production build
- [ ] Monitor for crash reports (Play Console ANR & crash reporting)

## Release Notes (Whats New)

```
PT-BR:
• Primeiro lançamento do GoAnime TV
• Assista anime de AnimeFire, AllAnime, SuperFlix e Goyabu
• Pesquisa integrada com resultados de múltiplas fontes
• Player de vídeo com seleção de qualidade
• Integração com AniList para listas e descoberta

English:
• First release of GoAnime TV
• Watch anime from AnimeFire, AllAnime, SuperFlix, and Goyabu
• Integrated search with multi-source results
• Video player with quality selection
• AniList integration for lists and discovery
```

## Version History

- **1.0.0** — Initial release
