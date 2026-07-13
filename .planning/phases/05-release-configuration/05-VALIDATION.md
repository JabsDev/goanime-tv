# Phase 5: Release Configuration — Validation

> `workflow.nyquist_validation` is enabled.

## Test Framework

| Property | Value |
|----------|-------|
| Framework | flutter_test (SDK) |
| Config file | `pubspec.yaml` (dev_dependencies includes `flutter_test`, `integration_test`) |
| Quick run command | `flutter test` |
| Full suite command | `flutter test` (unit tests only; integration tests require device) |

## Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| REL-01 | Signing config loads from key.properties | Manual (build verification) | `flutter build apk --release` succeeds locally | N/A — build succeeds or fails |
| REL-02 | CI workflow triggers on tag push | Integration (GitHub Actions) | Push `v0.0.0-test` tag to fork, verify workflow runs | N/A — CI YAML |
| REL-02 | CI runs flutter analyze + flutter test on PR | Integration (GitHub Actions) | Open PR, verify checks pass | N/A — CI YAML |
| REL-03 | Release checklist document exists | Manual review | `docs/RELEASE_CHECKLIST.md` readable | ❌ Wave 0 |
| REL-03 | Screenshots and banner meet spec | Manual review | Visual inspection against Play Console requirements | ❌ Wave 0 |

## Sampling Rate

- **Per task commit:** N/A (no code changes that affect tests)
- **Per wave merge:** `flutter test` — verify existing tests still pass after Gradle/build changes
- **Phase gate:** `flutter test` green, signed APK builds successfully, release checklist complete

## Wave 0 Gaps

- [ ] `docs/RELEASE_CHECKLIST.md` — complete Play Store submission steps document
- [ ] `assets/store/` — directory for screenshots and banner (not test files, but needed for REL-03)
