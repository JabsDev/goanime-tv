---
phase: 05-release-configuration
plan: 01
subsystem: build-pipeline
tags: [release, signing, ci, gradle, go-ffi]
key-files:
  created: []
  modified:
    - pubspec.yaml
    - .gitignore
    - go_superflix/build_android.sh
    - android/app/build.gradle
metrics:
  tasks: 3/3
  commits: 3
  deviations: 0
---

## Summary

Configured the local release build pipeline: version bump, gitignore keystore protection, Go FFI build script CI-hardening, and Gradle release signing config.

## Commits

| # | Commit | Description |
|---|--------|-------------|
| 1 | `2736379` | Bump version to 1.0.0+1000000 and protect keystore from git |
| 2 | `811209f` | CI-harden build_android.sh — ANDROID_NDK_HOME, TOOLCHAIN var, mkdir -p jniLibs |
| 3 | `27bd861` | Configure release signing in build.gradle with keystore properties |

## Deviations

None.

## Self-Check

- [x] `pubspec.yaml` version is `1.0.0+1000000`
- [x] `.gitignore` protects `*.jks` and `key.properties`
- [x] `build_android.sh` uses `$ANDROID_NDK_HOME`, removes hardcoded GOROOT/GOPATH, uses TOOLCHAIN variable, creates jniLibs dirs
- [x] `build.gradle` has `signingConfigs.release` with keystore properties loading
- [x] `build.gradle` `buildTypes.release` uses `signingConfigs.release` instead of `signingConfigs.debug`

**Self-Check: PASSED**
