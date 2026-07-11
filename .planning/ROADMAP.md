# Roadmap: GoAnime TV

**Initiated:** 2026-07-11
**v1 Requirements:** 13
**Phases:** 5

---

### Phase 1: Security Hardening
**Goal:** Eliminate CRITICAL/HIGH security vulnerabilities in AniList OAuth and pairing server
**Mode:** mvp
**Success Criteria**:
1. Hardcoded AniList client secret is removed or explicitly documented as a public-insecure secret
2. Pairing server binds to localhost only (not 0.0.0.0) with CSRF protection
3. OAuth token transmission is secured or LAN-only risk is documented
4. Existing pairing flow still works end-to-end

**Requirements:** SEC-01, SEC-02, SEC-03

---

### Phase 2: Home Screen Refactor
**Goal:** Split the 1320-line home_screen.dart into focused, maintainable components
**Mode:** mvp
**Success Criteria**:
1. HomeScreen extracted as standalone file (~400 lines)
2. AnilistLoginDialog extracted as separate widget file
3. ProfileScreen extracted as separate file
4. All existing functionality preserved (no regressions in catalog browsing, history, favorites)
5. Navigation between extracted components works correctly

**Requirements:** CODE-01

---

### Phase 3: Error Handling & Bug Fixes
**Goal:** Improve scraper robustness and fix known bugs
**Mode:** mvp
**Success Criteria**:
1. Scraper adapter layer distinguishes between network timeout, parse failure, Cloudflare challenge, and empty results
2. Appropriate fallback or retry logic for each error type
3. SuperFlix domain uses a single source of truth (no .pro vs .best mismatch)
4. Episode numbers that fail to parse sort to end of list (not position 0)
5. All existing search and playback flows continue to work

**Requirements:** CODE-02, CODE-03, BUG-01

---

### Phase 4: Testing & Documentation
**Goal:** Establish test coverage and developer documentation
**Mode:** mvp
**Success Criteria**:
1. Unit tests exist for key scraper orchestration logic
2. Unit tests exist for each adapter's core parsing methods
3. Integration tests cover search → detail → playback flow
4. AGENTS.md contains workflow instructions, build commands, and architecture overview
5. Tests pass on CI

**Requirements:** CODE-04, TEST-01, TEST-02

---

### Phase 5: Release Configuration
**Goal:** Configure build pipeline and release assets for Play Store submission
**Mode:** mvp
**Success Criteria**:
1. Android app signing is configured with keystore and release build variant
2. GitHub Actions workflow builds, tests, and produces a signed release APK
3. Release checklist documents Play Store submission steps
4. Play Store listing assets are prepared (screenshots, description, privacy policy)
5. Manual release dry-run succeeds end-to-end

**Requirements:** REL-01, REL-02, REL-03

---

## Coverage

| Phase | Requirements | Status |
|-------|-------------|--------|
| 1 | SEC-01, SEC-02, SEC-03 | Pending |
| 2 | CODE-01 | Pending |
| 3 | CODE-02, CODE-03, BUG-01 | Pending |
| 4 | CODE-04, TEST-01, TEST-02 | Pending |
| 5 | REL-01, REL-02, REL-03 | Pending |

**All v1 requirements mapped:** 13/13 ✓
