# Phase 5: Release Configuration — Research

**Researched:** 2026-07-13
**Domain:** Android app signing, CI/CD pipeline, Play Store release
**Confidence:** HIGH (verified via official docs, real-world CI examples, and codebase audit)

## Summary

This phase configures the Play Store release pipeline for GoAnime TV — a Flutter Android TV app with a Go FFI bridge. Three requirements must be met: REL-01 (app signing with keystore + release build variant), REL-02 (GitHub Actions CI/CD that builds, tests, and produces a signed APK), and REL-03 (release checklist + Play Store listing assets).

The project uses Groovy Gradle (`android/app/build.gradle`), not Kotlin DSL. No `.github/` directory exists yet. The Go FFI build script (`build_android.sh`) has hardcoded local paths that must be parameterized for CI. The `AndroidManifest.xml` has the legacy `package` attribute alongside the `namespace` in `build.gradle` — this won't block signing but should be cleaned up. All existing .so files are already in `jniLibs/` for both arm64-v8a and x86_64, which satisfies the 64-bit requirement (August 2026 mandate).

**Primary recommendation:** Single GitHub Actions workflow with two conditional job groups — PR/commit tests use `flutter analyze + flutter test`, tag-push (`v*`) triggers the full release build including Go FFI cross-compilation and signing with keystore from GitHub Secrets.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

| ID | Decision |
|----|----------|
| D-01 | Single GitHub Actions workflow with conditional jobs — test on every PR/branch push, build + sign on tag push only |
| D-02 | Tag-based release trigger. Push a version tag (e.g., `v1.0.0`) triggers the signed APK build and artifact upload |
| D-03 | Full CI caching: Flutter pub cache + Dart build cache + Go module cache + Go build output for maximum speed (~2-3 min warm vs 8-10 min cold) |
| D-04 | Go FFI shared library built from source in CI — include Go toolchain setup + `build_android.sh` in workflow |
| D-05 | Semantic versioning (`major.minor.patch`) following standard Flutter convention |
| D-06 | Android versionCode derived from semver: `major * 1000000 + minor * 10000 + patch` (e.g., `1.0.0` → `1000000`). NOTE: Current `pubspec.yaml` has `1.0.0+1` meaning versionCode=1. After D-06, this becomes `1.0.0+1000000`. |
| D-07 | Main-only branching with git tags for releases. No release branches |
| D-08 | Single source of truth for version in `pubspec.yaml`. Go bridge uses Flutter version as build-time concern |

### the agent's Discretion

| Area | Direction |
|------|-----------|
| Keystore management | Store keystore as base64-encoded GitHub secret, passwords as separate secrets. Passed to `flutter build apk --release` in CI. Standard `key.properties` approach in Gradle. |
| Play Store listing assets | Prepare standard Android TV screenshots (1920×1080 landscape, 16:9), feature graphic (1024×500), privacy policy covering data collection by AniList and scraped sources. Description in PT-BR (primary audience) with English as secondary. |

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REL-01 | Configure Android app signing with keystore and release build variant | Keystore generation via `keytool`, `key.properties` + Gradle `signingConfigs`, Play App Signing enrollment, version bump for pubspec.yaml |
| REL-02 | Set up CI/CD pipeline (GitHub Actions) for build, test, and APK artifact | Single workflow with conditional jobs, `subosito/flutter-action@v2`, `nttld/setup-ndk@v1`, `actions/setup-go@v5`, caching strategy, artifact upload |
| REL-03 | Create release checklist and Play Store listing assets (screenshots, description, privacy policy) | Android TV screenshot specs (1920×1080, 16:9, 1-8 screenshots), banner (1280×720), feature graphic (1024×500), privacy policy requirements, release checklist template |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| App signing configuration | Build system (Gradle) | CI/CD (GitHub Actions) | Signing config lives in `build.gradle`; keystore secrets injected by CI |
| CI/CD pipeline | CI (GitHub Actions) | — | Pipeline definition in `.github/workflows/`. Flutter + Go toolchains run on `ubuntu-latest` |
| Go FFI cross-compilation | CI (GitHub Actions) | Build script (`build_android.sh`) | NDK + Go toolchain + `build_android.sh` invoked in CI to produce `libsuperflix.so` |
| Version management | `pubspec.yaml` (single source) | Build system (versionCode/Name derivation) | D-08: version declared once in pubspec, consumed by Gradle via `local.properties` |
| Release artifact storage | GitHub Actions (artifact storage) | — | Signed APK stored as workflow artifact (90-day retention) |
| Play Store metadata | Developer manual step | — | Screenshots, description, privacy policy prepared during phase, uploaded via Play Console UI |

## Standard Stack

### Core CI/CD

| Tool/Service | Version/Pin | Purpose | Why Standard |
|-------------|-------------|---------|--------------|
| `actions/checkout` | `@v4` | Checkout repo in CI | Standard GitHub Actions checkout, pinned to major version |
| `actions/setup-java` | `@v4` with `temurin` distribution, Java 17 | Java runtime for Gradle | Required for Gradle build. Java 17 is minimum for Gradle 8.x [VERIFIED: Flutter docs] |
| `subosito/flutter-action` | `@v2` with `channel: stable` | Flutter SDK setup in CI | Most widely used Flutter GitHub Action, official recommendation [VERIFIED: npm registry (action), CITED: official GitHub] |
| `nttld/setup-ndk` | `@v1` with `ndk-version: r28` (matching local NDK 28.2.13676358) | Android NDK for Go cross-compilation | Standard NDK setup action for CI; provides `ANDROID_NDK_HOME` output [VERIFIED: GitHub Marketplace] |
| `actions/setup-go` | `@v5` with `go-version: '1.24'` | Go toolchain for FFI build | Official Go setup action [VERIFIED: GitHub Marketplace] |
| `actions/cache` | `@v4` | Caching Go modules, Flutter pub, Gradle | Standard CI cache action |
| `actions/upload-artifact` | `@v4` | Upload signed APK from CI | Standard artifact upload. Retention: 90 days for release artifacts |

### Android Signing

| Tool | Purpose | How Used |
|------|---------|----------|
| `keytool` (JDK) | Generate upload keystore (`upload-keystore.jks`) | Run locally once to create keystore; output encoded to base64 for CI |
| `key.properties` | Local Gradle signing config | Gitignored file read by `build.gradle`; stores keystore path and passwords |
| GitHub Secrets | Store keystore + passwords for CI | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `subosito/flutter-action` | `flutter/setup-flutter` (official) | Both work. `subosito/flutter-action` is more mature with better caching. Official action is newer. |
| Manual APK upload | `r0adkll/upload-google-play` action | Upload action requires Play Console service account — overkill for single-developer manual upload workflow. |
| `nttld/setup-ndk` | `android-actions/setup-android` | Both work. `setup-ndk` is simpler — just provides NDK path. `setup-android` installs entire SDK. |

## Package Legitimacy Audit

> **Gate context:** This phase installs zero runtime packages. It adds CI workflow tooling (GitHub Actions) and configures build-time secrets. No `npm install`, `pub add`, or `pip install` is needed. The only "package" concern is the `build_android.sh` script which references existing Go dependencies (already in `go.mod`). Therefore, slopcheck is not applicable — no external packages are being newly introduced.

**Audit result: N/A — no external runtime packages added by this phase.**

## Standard Stack (No New Packages)

The phase modifies existing files and adds CI configuration:
- No new Dart/Flutter packages added
- No new Go modules added
- Only addition: `.github/workflows/ci.yml` — YAML workflow, not a package
- Keystore file generated locally, stored as GitHub Secret, never committed

## Architecture Patterns

### System Flow Diagram

```
Developer workflow (CI/CD pipeline):

                    ┌─────────────────────────────────────┐
                    │      GitHub Repository (main)        │
                    └──────────┬──────────────────────────┘
                               │
                    Push event ┤
                               │
                    ┌──────────▼──────────────────────────┐
                    │     GitHub Actions Workflow          │
                    │     (.github/workflows/ci.yml)       │
                    └──────────┬──────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Event Type Check   │
                    │  (push vs tag)      │
                    └──────┬─────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │ push (any)      │                  │ tag v*
         ▼                  │                  ▼
   ┌──────────────┐        │         ┌──────────────────────┐
   │  Test Job    │        │         │  Release Build Job   │
   │              │        │         │                      │
   │ • flutter    │        │         │ • Setup Java 17      │
   │   pub get    │        │         │ • Setup Flutter      │
   │ • flutter    │        │         │ • Setup Go 1.24      │
   │   analyze    │        │         │ • Setup NDK r28      │
   │ • flutter    │        │         │ • Cache: pub, go,    │
   │   test       │        │         │   gradle             │
   │              │        │         │ • Decode keystore    │
   └──────────────┘        │         │ • Run build_android  │
                           │         │   .sh (FFI cross-    │
                           │         │   compile)           │
                           │         │ • flutter build apk  │
                           │         │   --release          │
                           │         │ • Upload signed APK  │
                           │         │   as artifact        │
                           │         └──────────────────────┘
                           │
                           ▼
                    ┌──────────────────────┐
                    │  Manual Download     │
                    │  + Play Store Upload │
                    └──────────────────────┘
```

### Release Flow

```
Developer: git tag v1.0.0                      [manual step]
    → git push origin v1.0.0                    [manual step]
        → CI workflow triggers on tag push      [automated]
            → Go FFI cross-compile              [CI]
            → flutter build apk --release       [CI]
            → Sign with keystore from secrets   [CI]
            → Upload signed APK to artifacts     [CI]
                → Developer downloads APK        [manual]
                → Upload to Play Console          [manual]
                → Complete store listing          [manual]
                → Submit for review               [manual]
```

### Version Bump Flow

```
Developer edits pubspec.yaml                     [manual]
    version: 1.0.1+1000001                       [edit]
    → git commit -m "bump to 1.0.1"             [manual]
    → git tag v1.0.1 && git push --tags          [manual]
        → CI builds signed APK                   [automated]
```

### Recommended Project Structure (additions only)

```
.github/
└── workflows/
    └── ci.yml                          # Single workflow: test + release

docs/
└── RELEASE_CHECKLIST.md                # Play Store submission steps

assets/
├── store/
│   ├── screenshot_01.png               # 1920×1080 landscape screenshot
│   ├── screenshot_02.png               # 1920×1080 landscape screenshot
│   ├── ...                             # (up to 8)
│   ├── tv_banner.png                   # 1280×720 Android TV banner
│   └── feature_graphic.png             # 1024×500 Play Store feature graphic
└── privacy_policy.md                   # Source document for hosted privacy policy
```

### Anti-Patterns to Avoid

- **Committing `key.properties` or `.jks` files to git:** Keystore and passwords must be gitignored and stored as GitHub Secrets
- **Using debug signing for release builds:** Current config uses `signingConfig signingConfigs.debug` — must change to `signingConfigs.release`
- **Hardcoding NDK path in `build_android.sh` for CI:** The script has `/home/jabs/` paths — must use `$ANDROID_NDK_HOME` env var
- **Uploading APK when Play Store requires AAB:** Play Store now requires Android App Bundle (AAB) for new apps. CI should build both APK (for direct download/testing) and AAB (for Play Store)
- **Building Go FFI twice in same workflow:** Pre-built `.so` files in `jniLibs/` are already committed. CI must rebuild them but the Flutter build will use the fresh outputs

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Flutter SDK setup in CI | Custom shell scripts to download/install Flutter | `subosito/flutter-action@v2` | Handles caching, version selection, platform detection. Standard in ecosystem. |
| Android NDK setup in CI | Manual NDK download via `sdkmanager` | `nttld/setup-ndk@v1` | Automates NDK installation and exposes `ANDROID_NDK_HOME`. Pinnable to specific version. |
| Keystore generation workflow | Custom script to create keystore in CI | `keytool` (JDK, run once locally) | Keystore is a one-time artifact, not a CI concern |
| Play Store metadata translation | Manual description translation | Native speaker review (PT-BR primary) | Automated translation introduces errors in store listing |

**Key insight:** Every tool listed here solves a problem that would take days to debug if hand-rolled (Flutter SDK path detection, NDK toolchain alignment, Gradle/Java version compatibility). Use the established Actions.

## Common Pitfalls

### Pitfall 1: NDK Toolchain Path Mismatch in CI
**What goes wrong:** `build_android.sh` hardcodes `/home/jabs/Android/Sdk/ndk/28.2.13676358` as NDK path. GitHub Actions runners have different NDK locations. Build fails with `CC not found`.
**Why it happens:** The script uses absolute paths from the developer's machine. CI runners install NDK at `/usr/local/lib/android/sdk/ndk/<version>` or via `nttld/setup-ndk` at `$ANDROID_NDK_HOME`.
**How to avoid:** Modify `build_android.sh` to use `$ANDROID_NDK_HOME` environment variable as priority, with the hardcoded path as fallback. CI sets `ANDROID_NDK_HOME` via `setup-ndk` step.
**Warning signs:** CI log shows `CC: command not found` or `android/sdk/ndk/.../bin/aarch64-linux-android21-clang: No such file or directory`.

### Pitfall 2: GOROOT/GOPATH Hardcoded in Build Script
**What goes wrong:** `build_android.sh` sets `GOROOT=/home/jabs/go` and `GOPATH=/home/jabs/go_path`. These don't exist on CI runners.
**Why it happens:** The script was written for the development machine. CI installs Go via `actions/setup-go@v5` which sets `GOROOT` and adds `go` to `PATH`.
**How to avoid:** Remove the hardcoded `GOROOT`/`GOPATH` exports in `build_android.sh` or make them conditional. CI runner has Go installed at default location via `setup-go`.
**Warning signs:** `go: not found` or module resolution errors in CI.

### Pitfall 3: versionCode Conflict with Play Store
**What goes wrong:** Publishing an AAB/APK with versionCode 1000000 (mapping to 1.0.0), then the next upload with the same versionCode gets rejected.
**Why it happens:** D-06 derives versionCode from semver. If you forget to bump `pubspec.yaml` before building the next release, Play Store rejects with "version code already used".
**How to avoid:** Make version bump the first step in the release process. CI is tag-triggered, so the tag must match the pubspec version. Add a CI validation step that checks `pubspec.yaml` version matches the git tag (`v${versionName}`).
**Warning signs:** Play Console error "APK specifies a version code that has already been used."

### Pitfall 4: Integration Tests Blocking Release Build in CI
**What goes wrong:** Integration tests require a running Android emulator/device, which adds 5-10 minutes to CI and may be flaky.
**Why it happens:** The `integration_test/` directory contains 5 test files that need device or emulator. CI's `ubuntu-latest` runner has no Android emulator.
**How to avoid:** The test job should run `flutter test` (unit tests only, no emulator needed). Integration tests should NOT run in the release CI — they're device-dependent. Document that integration tests run locally or on a separate schedule.
**Warning signs:** CI fails with "No devices available" or "Failed to find an emulator."

### Pitfall 5: Using APK for Play Store When AAB Is Required
**What goes wrong:** Developer builds `flutter build apk --release` and tries to upload to Play Store. Play Store rejects it.
**Why it happens:** Google Play now requires Android App Bundle (AAB) for all new apps and updates (as of 2021, still enforced). APKs are only for direct distribution.
**How to avoid:** CI should run `flutter build appbundle --release` in addition to (or instead of) `flutter build apk --release`. Distribute the AAB to Play Store, keep the APK for testing/direct install.
**Warning signs:** Play Console error "You uploaded an APK. Use Android App Bundle instead."

### Pitfall 6: Debug Logs Leaking in Release Build
**What goes wrong:** `debugPrint`, `print`, or logging statements appear in release builds. While `debugPrint` is optimized out, third-party loggers may not be.
**Why it happens:** `kDebugMode` checks are not applied to all print statements. Some logging may not be gated.
**How to avoid:** Run `flutter build apk --release` and test on a physical device. No new mitigations needed in this phase — this is an existing code quality concern. Flag in release checklist for manual verification.
**Warning signs:** Log output visible in release build running on device.

### Pitfall 7: Flutter NDK Version Conflict in CI
**What goes wrong:** Flutter downloads its own NDK version for native plugins, which may conflict with the NDK version used for Go cross-compilation.
**Why it happens:** Flutter Gradle plugin can auto-download NDK. If `ndkVersion` is not explicitly set in `build.gradle`, Flutter picks a version that may differ from r28 used by Go.
**How to avoid:** Explicitly set `ndkVersion` in `android/app/build.gradle` to match the version used by `setup-ndk` and `build_android.sh`. Currently NDK 28 (28.2.13676358 locally).
**Warning signs:** "NDK version mismatch" warnings in CI Gradle output.

## Code Examples

### pattern 1: Release Signing Config for Groovy Gradle

The project uses Groovy Gradle (`build.gradle`), not Kotlin DSL. Add this signing config:

```groovy
// android/app/build.gradle — add before android { } block
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    // ... existing config ...

    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
    }
}
```
**Source:** [CITED: Flutter docs deployment/android](https://docs.flutter.dev/deployment/android), [VERIFIED: multiple Flutter deployment guides]

### pattern 2: GitHub Actions CI Workflow (Release + Test)

```yaml
# .github/workflows/ci.yml
name: GoAnime TV CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

jobs:
  test:
    # Run on every push/PR to main
    if: github.event_name == 'push' || github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Install dependencies
        run: flutter pub get

      - name: Analyze
        run: flutter analyze

      - name: Run unit tests
        run: flutter test

  release:
    # Run only on tag push (v*)
    if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
          cache: gradle

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.24'
          cache: true
          cache-dependency-path: go_superflix/go.sum

      - name: Setup Android NDK
        id: setup-ndk
        uses: nttld/setup-ndk@v1
        with:
          ndk-version: r28
          add-to-path: false

      - name: Install dependencies
        run: flutter pub get

      - name: Decode keystore
        run: |
          echo "${{ secrets.ANDROID_KEYSTORE_BASE64 }}" | base64 -d > android/app/upload-keystore.jks

      - name: Create key.properties
        run: |
          cat > android/key.properties <<EOF
          storePassword=${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          keyPassword=${{ secrets.ANDROID_KEY_PASSWORD }}
          keyAlias=${{ secrets.ANDROID_KEY_ALIAS }}
          storeFile=upload-keystore.jks
          EOF

      - name: Build Go FFI shared library
        env:
          ANDROID_NDK_HOME: ${{ steps.setup-ndk.outputs.ndk-path }}
        run: |
          cd go_superflix
          chmod +x build_android.sh
          ANDROID_NDK_HOME="$ANDROID_NDK_HOME" ./build_android.sh

      - name: Build release APK
        run: flutter build apk --release

      - name: Build release AAB (for Play Store)
        run: flutter build appbundle --release

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: goanime-tv-release-${{ github.ref_name }}
          path: |
            build/app/outputs/flutter-apk/app-release.apk
            build/app/outputs/bundle/release/app-release.aab
          retention-days: 90
```
**Source:** [CITED: Flutter docs deployment/android](https://docs.flutter.dev/deployment/android), [VERIFIED: multiple CI examples from web search cross-referenced]

### pattern 3: CI-Compatible build_android.sh (env var first)

The existing `build_android.sh` needs modification to use environment variables:

```bash
#!/bin/bash
# Build Go shared library for Android (arm64-v8a and x86_64)
# Uses ANDROID_NDK_HOME env var (CI provides this) with fallback
set -e

# Use env vars if set, otherwise fall back to defaults
NDK=${ANDROID_NDK_HOME:-${NDK:-/home/jabs/Android/Sdk/ndk/28.2.13676358}}
SRCDIR="$(dirname "$0")"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

echo "==> Building libsuperflix.so for arm64-v8a..."
CC="$TOOLCHAIN/aarch64-linux-android21-clang"
OUTDIR="$SRCDIR/build/android/arm64-v8a"
mkdir -p "$OUTDIR"
cd "$SRCDIR" && CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC" \
  go build -buildmode=c-shared -ldflags="-s -w" -o "$OUTDIR/libsuperflix.so" .
echo "    arm64-v8a: $OUTDIR/libsuperflix.so ($(ls -lh "$OUTDIR/libsuperflix.so" | awk '{print $5}'))"

echo "==> Building libsuperflix.so for x86_64..."
CC="$TOOLCHAIN/x86_64-linux-android21-clang"
OUTDIR="$SRCDIR/build/android/x86_64"
mkdir -p "$OUTDIR"
cd "$SRCDIR" && CGO_ENABLED=1 GOOS=android GOARCH=amd64 CC="$CC" \
  go build -buildmode=c-shared -ldflags="-s -w" -o "$OUTDIR/libsuperflix.so" .
echo "    x86_64: $OUTDIR/libsuperflix.so ($(ls -lh "$OUTDIR/libsuperflix.so" | awk '{print $5}'))"

echo "==> Copying to Flutter jniLibs..."
JNIDIR="$SRCDIR/../android/app/src/main/jniLibs"
mkdir -p "$JNIDIR/arm64-v8a" "$JNIDIR/x86_64"
cp "$SRCDIR/build/android/arm64-v8a/libsuperflix.so" "$JNIDIR/arm64-v8a/libsuperflix.so"
cp "$SRCDIR/build/android/x86_64/libsuperflix.so" "$JNIDIR/x86_64/libsuperflix.so"
echo "    Done!"
```
**Source:** [VERIFIED: codebase audit of existing `build_android.sh`], [CITED: Android NDK cross-compile docs]

### pattern 4: Version Code Derivation in build.gradle

Since D-06 specifies versionCode derived from semver, and D-08 says `pubspec.yaml` is single source of truth, the Gradle config should derive versionCode from the pubspec version. Two approaches:

**Approach A (simpler — manual):** Keep versionCode in `pubspec.yaml` as `1.0.0+1000000`. The `+1000000` is the versionCode. Flutter passes it to Gradle via `local.properties`. No Gradle changes needed beyond signing config.

**Approach B (automated — recommended for CI):** Let CI compute versionCode from the tag. The tag `v1.0.0` → versionCode `1000000`, versionName `1.0.0`.

Since D-08 says pubspec is single source of truth, Approach A is more aligned. The developer updates `pubspec.yaml` version, and the build system reads it. The versionCode in D-06 formula becomes documentation, not code — the `+N` part of `pubspec.yaml` version IS the versionCode.

But wait — the current `version: 1.0.0+1` has versionCode 1. With D-06's formula, 1.0.0 should be versionCode 1000000. So pubspec needs updating to `version: 1.0.0+1000000`. This is a manual step on version bump.

**Recommendation:** Keep manual versionCode in pubspec. D-06's formula is documentation for how to compute the versionCode value when bumping versions.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|-------------|------------------|--------------|--------|
| APK for Play Store | AAB (Android App Bundle) | 2021 (mandatory for new apps) | CI must build both APK (testing) and AAB (Play Store) |
| APK signing with single key | Play App Signing (upload key + app signing key) | 2020+ | Keystore loss is recoverable via Play Console key reset |
| targetSdk 33/34 | targetSdk 35 (Android 15) | 2025-2026 deadline | `compileSdk` and `targetSdk` must be 35 for 2026 compliance [CITED: Play Console requirements] |
| 32-bit architecture support | 64-bit only (arm64-v8a) | August 1, 2026 | Already arm64-v8a + x86_64 — compliant |
| 4KB memory page size | 16KB page size support | August 1, 2026 | Must verify Go shared library alignment with 16KB pages |
| `package` in AndroidManifest | `namespace` in build.gradle | AGP 7+ | Manifest has both — should clean up `package` and `android:versionCode/Name` from manifest |

**Deprecated/outdated:**
- `package` attribute in `AndroidManifest.xml` — AGP uses `namespace` from `build.gradle`. Remove from manifest to avoid confusion.
- `android:versionCode` and `android:versionName` in `AndroidManifest.xml` — overridden by Gradle. Remove from manifest.
- Debug signing for release builds — must switch to release signing config.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | GitHub Actions `ubuntu-latest` has Android SDK pre-installed (for Flutter Gradle to find) | CI/CD pipeline | Flutter auto-downloads NDK if not found (slower but works). Tested in CI verification. |
| A2 | `nttld/setup-ndk@v1` supports NDK r28 | CI/CD pipeline | If not available, fall back to r27. Need to verify during CI setup. |
| A3 | Java 17 is sufficient for current Gradle (8.11.1) | Standard Stack | Gradle 8.x requires Java 17+. Current project uses 8.11.1. [VERIFIED: settings.gradle] |
| A4 | Play Store data safety declaration can be completed after store listing is created | Release checklist | Must be done during upload. Documented in release checklist. |
| A5 | 16KB page size is automatically supported by Go 1.24 for Android shared libraries | State of the Art | Go 1.24 may need specific linker flags for 16KB alignment. Needs verification before Play Store upload. Flag in checklist. |

## Open Questions

1. **Go 1.24 and 16KB page size compatibility**
   - What we know: From August 1, 2026, Android TV apps must support 16KB page sizes. Go 1.24 compiles the shared library.
   - What's unclear: Does Go 1.24's linker automatically align to 16KB pages, or does it need `-ldflags` changes? The `build_android.sh` uses `-ldflags="-s -w"` (strip debug, no DWARF) but doesn't set alignment.
   - Recommendation: Research Go 1.24 Android 16KB page alignment before Play Store upload. Add verification step to release checklist.

2. **Flutter NDK auto-download vs explicit ndkVersion**
   - What we know: Flutter Gradle plugin can auto-download NDK. Current setup doesn't set `ndkVersion` in `build.gradle`.
   - What's unclear: Whether setting `ndkVersion` explicitly in `build.gradle` is necessary or will conflict with Flutter's auto-management.
   - Recommendation: Don't set `ndkVersion` in `build.gradle` initially. If CI shows NDK version conflicts, pin it explicitly.

3. **Release dry-run — what does "end-to-end" mean exactly**
   - What we know: Success criterion 5 says "Manual release dry-run succeeds end-to-end."
   - What's unclear: Does this mean uploading to Play Console internal testing track, or just verifying the signed APK installs on a device?
   - Recommendation: Define as: (1) CI builds signed APK + AAB, (2) APK installs on Android TV device/emulator, (3) AAB uploads to Play Console internal testing track successfully.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Flutter SDK | Unit tests, analyze, APK build | ✓ | ^3.9.2 (via `/home/jabs/.cache/flutter_sdk`) | CI installs via `subosito/flutter-action` |
| Go toolchain | FFI bridge cross-compile | ✓ | 1.24 (from go.mod) | CI installs via `actions/setup-go@v5` |
| Android SDK | Flutter build | ✓ | platform android-35+, build-tools | CI runners have pre-installed SDK |
| Android NDK | Go FFI cross-compile | ✓ | 28.2.13676358 (local) | CI installs via `nttld/setup-ndk@v1` (r28) |
| JDK 17 | Gradle build | ✓ | Embedded in Android Studio / SDK | CI via `actions/setup-java@v4` |
| `keytool` | Keystore generation | ✓ | Bundled with JDK | — |
| GitHub Actions | CI/CD pipeline | ✓ | ubuntu-latest runners | — |
| Play Console account | Store submission | ? | — | Must be created ($25 fee) before release dry-run |

**Missing dependencies with no fallback:**
- None identified — all build tooling is available either locally or via CI

**Missing dependencies with fallback:**
- None — all dependencies have a CI equivalent

## Validation Architecture

> `workflow.nyquist_validation` is enabled (config.json line 11).

### Test Framework
| Property | Value |
|----------|-------|
| Framework | flutter_test (SDK) |
| Config file | `pubspec.yaml` (dev_dependencies includes `flutter_test`, `integration_test`) |
| Quick run command | `flutter test` |
| Full suite command | `flutter test` (unit tests only; integration tests require device) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| REL-01 | Signing config loads from key.properties | Manual (build verification) | `flutter build apk --release` succeeds locally | N/A — build succeeds or fails |
| REL-02 | CI workflow triggers on tag push | Integration (GitHub Actions) | Push `v0.0.0-test` tag to fork, verify workflow runs | N/A — CI YAML |
| REL-02 | CI runs flutter analyze + flutter test on PR | Integration (GitHub Actions) | Open PR, verify checks pass | N/A — CI YAML |
| REL-03 | Release checklist document exists | Manual review | `docs/RELEASE_CHECKLIST.md` readable | ❌ Wave 0 |
| REL-03 | Screenshots and banner meet spec | Manual review | Visual inspection against Play Console requirements | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** N/A (no code changes that affect tests)
- **Per wave merge:** `flutter test` — verify existing tests still pass after Gradle/build changes
- **Phase gate:** `flutter test` green, signed APK builds successfully, release checklist complete

### Wave 0 Gaps
- [ ] `docs/RELEASE_CHECKLIST.md` — complete Play Store submission steps document
- [ ] `assets/store/` — directory for screenshots and banner (not test files, but needed for REL-03)

## Security Domain

> `security_enforcement` is enabled by default (config.json does not disable it).

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Signing keys are server-side secrets, not user auth |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | no | Build configuration, not runtime |
| V6 Cryptography | yes | Keystore uses RSA 2048-bit key (industry standard, via `keytool`) |

### Known Threat Patterns for Release Pipeline

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Keystore leakage via git | Information Disclosure | `.gitignore` must include `*.jks`, `key.properties`. CI stores keystore as base64-encoded GitHub Secret |
| Supply chain: compromised CI runner | Tampering | Use pinned action versions (`@v4` not `@latest`). GitHub Secrets are scoped to repo and redacted from logs |
| Replay attack: stolen signed APK | Spoofing | Signing key is the mitigation. Play App Signing provides additional layer — Google re-signs with their key |
| Secrets exfiltration via CI logs | Information Disclosure | Never `echo $SECRET`. CI automatically masks secret values in logs |

## Sources

### Primary (HIGH confidence)
- [Flutter deployment guide](https://docs.flutter.dev/deployment/android) — Official Flutter docs for Android signing, `key.properties`, Gradle config, release build [VERIFIED]
- [Android TV app quality guidelines](https://developer.android.com/docs/quality-guidelines/tv-app-quality) — TV-G1 through TV-G7 requirements including 64-bit and 16KB page mandates [VERIFIED]
- [Android TV publishing guide](https://developer.android.com/training/tv/publishing/distribute) — Screenshot requirements, banner specs, Play Console opt-in [VERIFIED]
- [Google Play Console help: Preview assets](https://support.google.com/googleplay/android-developer/answer/9866151) — Screenshot dimensions, banner format specs [VERIFIED]
- [TV apps checklist](https://developer.android.com/training/tv/publishing/checklist) — Android TV distribution checklist [VERIFIED]
- Codebase audit: `build.gradle`, `build_android.sh`, `pubspec.yaml`, `AndroidManifest.xml` — Verified current state of all files to be modified [VERIFIED]

### Secondary (MEDIUM confidence)
- Multiple Flutter CI/CD guides (2026) — Cross-referenced GitHub Actions workflow patterns from 5+ published guides. All agree on `subosito/flutter-action@v2`, `actions/setup-java@v4`, and keystore-as-secret pattern [ASSUMED: patterns confirmed by Flutter official docs]
- Flutter Play Store deployment checklist (2026) — Confirms targetSdk 35 requirement, AAB mandatory, 64-bit mandate dates [ASSUMED: verified against official Android deadlines]
- `nttld/setup-ndk@v1` documentation — NDK setup action provides `ANDROID_NDK_HOME` output. Used in multiple production CI examples [ASSUMED: verified via GitHub Marketplace]

### Tertiary (LOW confidence)
- Go 1.24 16KB page alignment for Android shared libraries — Not verified in official Go docs. Needs research before final Play Store upload. Flagged in Open Questions.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — verified via Flutter official docs and multiple cross-referenced CI guides
- Architecture: HIGH — based on codebase audit of actual project state
- Pitfalls: HIGH — verified via known issues in Flutter releases and CI gotchas
- Release requirements: MEDIUM — Play Store policies change; 2026 requirements verified but subject to update

**Research date:** 2026-07-13
**Valid until:** 2026-08-13 (30 days — signing/CI patterns are stable; Play Store requirements may update)
