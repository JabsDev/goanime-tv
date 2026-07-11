# Requirements: GoAnime TV

**Defined:** 2026-07-11
**Core Value:** Users can discover, browse, and watch anime from multiple providers through a single Android TV interface with reliable video playback.

## v1 Requirements

Requirements for release readiness. Each maps to roadmap phases.

### Security

- [ ] **SEC-01**: Remove or document hardcoded AniList OAuth client secret in `app_constants.dart`
- [ ] **SEC-02**: Add TLS to AniList pairing server or restrict binding to localhost only
- [ ] **SEC-03**: Add authentication or CSRF protection to pairing server endpoint

### Release Configuration

- [ ] **REL-01**: Configure Android app signing with keystore and release build variant
- [ ] **REL-02**: Set up CI/CD pipeline (GitHub Actions) for build, test, and APK artifact
- [ ] **REL-03**: Create release checklist and Play Store listing assets (screenshots, description, privacy policy)

### Code Quality

- [ ] **CODE-01**: Split `home_screen.dart` (1320 lines) into focused components (HomeScreen, AnilistLoginDialog, ProfileScreen)
- [ ] **CODE-02**: Add structured error handling to scraper layer (distinguish timeout, parse failure, Cloudflare, empty results)
- [ ] **CODE-03**: Fix SuperFlix domain inconsistency between `.pro` (WebView) and `.best` (constants)
- [ ] **CODE-04**: Add AGENTS.md with workflow and build instructions

### Bug Fixes

- [ ] **BUG-01**: Fix episode sorting for unparseable numbers (default to end, not position 0)

### Testing

- [ ] **TEST-01**: Add unit tests for core scraper and adapter logic
- [ ] **TEST-02**: Expand integration test coverage to cover search, detail, and playback flows

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Performance

- **PERF-01**: Add response streaming to avoid full-body reads into memory
- **PERF-02**: Implement race pattern for search (first result wins) instead of parallel fan-out to all sources

### Maintainability

- **MAINT-01**: Split `superflix_bridge.go` (932 lines) into focused files
- **MAINT-02**: Document magic numbers and persisted query hashes
- **MAINT-03**: Add environment-based config mechanism (remove hardcoded URLs)

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| New anime source adapters | Focus on releasing current sources |
| iOS support | Android TV only, not portable |
| UI redesign or theming | Existing dark theme is release-ready |
| Go bridge rewrite in Dart | FFI approach is functional and proven |
| Real-time features | Not in scope for initial release |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SEC-01 | Phase 1 | Pending |
| SEC-02 | Phase 1 | Pending |
| SEC-03 | Phase 1 | Pending |
| CODE-01 | Phase 2 | Pending |
| CODE-02 | Phase 3 | Pending |
| CODE-03 | Phase 3 | Pending |
| BUG-01 | Phase 3 | Pending |
| CODE-04 | Phase 4 | Pending |
| TEST-01 | Phase 4 | Pending |
| TEST-02 | Phase 4 | Pending |
| REL-01 | Phase 5 | Pending |
| REL-02 | Phase 5 | Pending |
| REL-03 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 13 total
- Mapped to phases: 13
- Unmapped: 0 ✓

---
*Requirements defined: 2026-07-11*
*Last updated: 2026-07-11 after initial definition*
