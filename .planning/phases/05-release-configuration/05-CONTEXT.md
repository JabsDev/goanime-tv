# Phase 5: Release Configuration - Context

**Gathered:** 2026-07-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Configure Android app signing, CI/CD pipeline, and Play Store listing assets for v1.0 Play Store submission. Three requirements: REL-01 (app signing with keystore + release build variant), REL-02 (GitHub Actions CI/CD workflow that builds, tests, and produces a signed release APK), REL-03 (release checklist + Play Store listing assets).

All existing functionality must be preserved. The Go FFI toolchain must remain buildable in CI.

</domain>

<decisions>
## Implementation Decisions

### CI/CD Workflow Structure
- **D-01:** Single GitHub Actions workflow with conditional jobs — test on every PR/branch push, build + sign on tag push only. Simplest to maintain for a single-developer project.
- **D-02:** Tag-based release trigger. Push a version tag (e.g., `v1.0.0`) triggers the signed APK build and artifact upload. Test-on-PR runs on every push automatically.
- **D-03:** Full CI caching: Flutter pub cache + Dart build cache + Go module cache + Go build output for maximum speed (~2-3 min warm vs 8-10 min cold).
- **D-04:** Go FFI shared library built from source in CI — include Go toolchain setup + `build_android.sh` in workflow. Not pre-built or committed.

### Versioning & Release Cadence
- **D-05:** Semantic versioning (`major.minor.patch`) following standard Flutter convention.
- **D-06:** Android versionCode derived from semver: `major * 1000000 + minor * 10000 + patch` (e.g., `1.0.0` → `1000000`).
- **D-07:** Main-only branching with git tags for releases. No release branches — overhead not justified for single-developer project.
- **D-08:** Single source of truth for version in `pubspec.yaml`. Go bridge uses the Flutter version as a build-time concern — no separate Go version.

### the agent's Discretion
- **Keystore management** (not discussed): Use standard approach — store keystore as base64-encoded GitHub secret, passwords as separate secrets. Passed to `flutter build apk --release` in CI.
- **Play Store listing assets** (not discussed): Prepare standard Android TV screenshots (1920x1080 landscape), feature graphic (1024x500), and a privacy policy covering data collection by AniList and scraped sources. Description in PT-BR (primary audience) with English as secondary.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope & requirements
- `.planning/ROADMAP.md` — Phase 5 definition, goals, success criteria, REL-01/REL-02/REL-03 mapping
- `.planning/REQUIREMENTS.md` — REL-01 (app signing), REL-02 (CI/CD), REL-03 (listing assets)

### Project context & state
- `.planning/PROJECT.md` — Project overview, key decisions, constraints
- `.planning/STATE.md` — Current project state and traceability

### Codebase analysis (build & architecture)
- `.planning/codebase/STACK.md` — Build toolchain (Flutter SDK ^3.9.2, Go 1.24, NDK)
- `.planning/codebase/ARCHITECTURE.md` — System architecture, FFI bridge integration, build flow
- `.planning/codebase/INTEGRATIONS.md` — External API dependencies for release documentation

### Source files to modify
- `pubspec.yaml` — Version declaration (source of truth)
- `android/app/build.gradle` — Signing config, versionCode derivation
- `go_superflix/build_android.sh` — FFI cross-compile script (referenced by CI)
- `go_superflix/go.mod` — Go module definition

### Prior decisions (Phase 1–4 carryforward)
- `.planning/phases/04-testing-documentation/04-CONTEXT.md` — D-11: CI pipeline setup deferred to Phase 5; tests exist but no CI wiring
- `.planning/phases/03-error-handling-bug-fixes/03-CONTEXT.md` — ScraperResult/ScraperError sealed classes, adapter patterns
- `.planning/phases/02-home-screen-refactor/02-CONTEXT.md` — File structure conventions, navigation patterns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `go_superflix/build_android.sh` — Existing cross-compile script for Go FFI. CI workflow can reference this directly.
- AGENTS.md (project root) — Already documents build commands and Go FFI bridge rebuild instructions.
- Existing test suite (Phase 4) — Unit tests for core scraper + adapter logic + integration tests. CI will run `flutter test` and `flutter test integration_test/`.

### Established Patterns
- `build.gradle` already has `minSdk`, `targetSdk`, `applicationId` configured — signing config is the missing piece.
- All secrets currently in `app_constants.dart` — keystore passwords will be CI secrets, not in-repo.
- Version declared in `pubspec.yaml:3` (`version: 1.0.0+1`) — single source of truth.

### Integration Points
- CI needs Android SDK + NDK for Flutter build, Go toolchain + NDK for FFI cross-compilation
- `flutter build apk --release` is the primary CI build command
- Signed APK uploads as GitHub Actions artifact for manual Play Store upload
- AGENTS.md build section should be updated to reference CI workflow

</code_context>

<specifics>
## Specific Ideas

- CI workflow file: `.github/workflows/ci.yml` — single file, standard location
- Release steps: tag push → CI builds + signs → artifact uploaded → manual Play Store upload (App Center or manual download)
- Version bump: manually update `pubspec.yaml` version and create git tag — no automation needed for initial release

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 5-Release Configuration*
*Context gathered: 2026-07-13*
