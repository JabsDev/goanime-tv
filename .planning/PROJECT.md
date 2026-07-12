# GoAnime TV

## What This Is

Android TV app for streaming anime from multiple sources (AnimeFire, AllAnime, SuperFlix, Goyabu) with a unified search, catalog browsing via AniList, video playback with quality selection, and cross-source episode resolution. Built with Flutter and a Go FFI bridge for Cloudflare bypass.

## Core Value

Users can discover, browse, and watch anime from multiple providers through a single Android TV interface with reliable video playback.

## Requirements

### Validated

- ✓ Multi-source anime search (AnimeFire, AllAnime, SuperFlix, Goyabu) — existing
- ✓ Cross-source episode resolution and aggregation — existing
- ✓ Video playback with quality selection and progress persistence — existing
- ✓ AniList catalog browsing, enrichment, and OAuth pairing — existing
- ✓ Watch history and continue-watching tracking — existing
- ✓ Favorites/bookmarks — existing
- ✓ Cloudflare bypass for SuperFlix via Go FFI bridge, HTTP fallback, and WebView — existing
- ✓ In-memory TTL caching layer for search, episodes, enrichment, and HTTP — existing
- ✓ Dark TV-optimized UI with focus-based navigation — existing
- ✓ Profile screen with history and favorites — existing
- ✓ SEC-01: Hardcoded client secret removed — PKCE migration eliminates need (Phase 1)
- ✓ SEC-02: Pairing server LAN access preserved with documented warning — risk accepted (Phase 1)
- ✓ SEC-03: CSRF protection + Origin/Referer validation + rate limiting on /token (Phase 1)

### Active

- [ ] REL-01: Configure Android app signing and release build
- [ ] REL-02: Set up CI/CD pipeline (GitHub Actions)
- [ ] REL-03: Create release checklist and Play Store listing assets
- [ ] CODE-01: Split home_screen.dart (1320 lines) into focused components
- [ ] CODE-02: Add structured error handling to scraper layer
- [ ] CODE-03: Fix SuperFlix domain inconsistency (.pro vs .best)
- [ ] CODE-04: Add AGENTS.md with workflow instructions
- [ ] BUG-01: Fix episode sorting for unparseable numbers
- [ ] TEST-01: Add unit tests for core scraper and adapter logic
- [ ] TEST-02: Expand integration test coverage

### Out of Scope

- Adding new anime sources — focus on stabilizing and releasing current sources
- iOS support — Android TV only
- UI redesign or theming changes — existing dark theme is release-ready
- Rewriting the Go bridge in pure Dart — functional as-is
- Real-time features (chat, comments, live streaming) — not part of release scope

## Context

GoAnime TV is a Flutter 3.9.2+ Android TV app with a Go cgo shared library for optimized scraping. The app scrapes four anime providers (two PT-BR, one EN, one multi-language) and enriches results via AniList GraphQL. Video playback uses media_kit (libmpv-based). The codebase has a mapped architecture with documented concerns — three CRITICAL/HIGH security issues, one HIGH technical debt item (1320-line home screen), and several MEDIUM fragility areas that should be addressed before release.

## Constraints

- **Platform**: Android TV only (API 21+, targeting modern Android TV devices)
- **SDK**: Flutter ^3.9.2, Dart ^3.9.2
- **Build**: Requires Go toolchain for FFI bridge cross-compilation
- **Compatibility**: Must handle upstream provider changes gracefully (scrapers break when sites update)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Multi-source scraping architecture | Max coverage when sources go down | ✓ Good |
| Go FFI for SuperFlix | TLS fingerprinting requires low-level control | ✓ Good |
| AniList as metadata source | Rich catalog data without scraping | ✓ Good |
| media_kit for video playback | Best Android TV codec support | ✓ Good |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-12 after Phase 1 completion*
