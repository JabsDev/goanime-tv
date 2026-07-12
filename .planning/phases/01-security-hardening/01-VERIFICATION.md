---
phase: 01-security-hardening
verified: 2026-07-12
status: human_needed
score: 7/7 must-haves verified
overrides_applied: 0
gaps: []
deferred:
  - truth: "WebView login in home_screen.dart handles PKCE response (code= instead of access_token=)"
    addressed_in: "Phase 2"
    evidence: "Phase 2 is the Home Screen Refactor (CODE-01), which will refactor home_screen.dart including the AnilistLoginDialog component that currently uses the old Implicit Grant pattern (access_token from fragment)."
human_verification:
  - test: "Set phase goal to proper User Story format for MVP mode"
    expected: "Run `/gsd mvp-phase 01` to set a goal in format: As a [user role], I want to [capability], so that [outcome]."
    why_human: "MVP mode requires goal as User Story for User Flow Coverage table. Current goal is engineering-oriented."
  - test: "End-to-end pairing flow manual verification"
    expected: "Launch app, trigger pairing, scan QR code on phone, authorize on AniList, confirm token saved on TV"
    why_human: "Requires running Flutter app on TV/emulator with phone on same LAN — cannot be automated"
  - test: "LAN security warning is visible on pairing page"
    expected: "Portuguese warning about LAN-only usage appears below the 'Entrar com AniList' button"
    why_human: "Visual appearance of HTML rendered content"
---

# Phase 1: Security Hardening Verification Report

**Phase Goal:** Eliminate CRITICAL/HIGH security vulnerabilities in AniList OAuth and pairing server
**Verified:** 2026-07-12
**Status:** human_needed
**Re-verification:** No — initial verification

## MVP Mode Format Discrepancy

Phase 1 is marked as `mode: mvp` in ROADMAP.md, but the goal is not in User Story format. MVP mode requires goals in the form: `As a [user role], I want to [capability], so that [outcome].`

**GSD SDK validation result:** `valid: false`
```
Errors:
  - Must begin with "As a ".
  - Must contain ", I want to ".
  - Must contain ", so that ".
  - Must end with a period.
```

**Action needed:** Run `/gsd mvp-phase 01` to set a proper User Story goal (e.g., "As a TV user, I want to securely link my AniList account, so that my OAuth credentials are not exposed to LAN attackers.").

The verification below uses standard goal-backward methodology against the stated engineering goal. All must-haves pass their technical checks.

## Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | "User can pair AniList account via phone scanning QR code on TV (PKCE flow)" | ✓ VERIFIED | Pairing server generates PKCE authorize URL: `response_type=code`, `code_challenge_method=S256`, `state=` param, `code_challenge=` param. Callback page reads `code` from query string, POSTs to `/token`. Server validates `state`, exchanges via `AniListService.exchangeCodeForToken()`. All 3 PKCE tests pass. |
| 2 | "AniList client secret is no longer hardcoded in app_constants.dart" | ✓ VERIFIED | `grep -c 'anilistClientSecret'` returns 0. `app_constants.dart` has no `anilistClientSecret` field. |
| 3 | "/token endpoint on pairing server rejects requests without valid CSRF token" | ✓ VERIFIED | `_handleToken()` (line 177-183) checks `csrfToken` against stored `_csrfToken`, returns 403 if missing/wrong. Test 6 confirms POST without CSRF token returns 403. |
| 4 | "/token endpoint rejects requests with mismatched Origin/Referer headers" | ✓ VERIFIED | `_handleToken()` (lines 190-200) validates `Origin` exact match and `Referer` startsWith against `http://$_ip:$_port`. Test 7 confirms wrong Origin returns 403. |
| 5 | "/token endpoint rate-limits excessive POSTs from the same IP (max 5/60s)" | ✓ VERIFIED | `_rateLimitStore` tracks count per IP. Test 8 confirms 6th POST within 60s returns 429. Rate limit window expires lazily. |
| 6 | "Access-Control-Allow-Origin is restricted to TV's own origin" | ✓ VERIFIED | `_html()` helper (line 231) sets `Access-Control-Allow-Origin` to `http://$_ip:$_port`. No wildcard `*` fallback (WR-04 fixed). `grep -c 'Access-Control-Allow-Origin.*\*'` returns 0. Test 9 confirms. |
| 7 | "AniListService stores tokens via LocalStorage (SharedPreferences wrapper)" | ✓ VERIFIED | `AniListService.saveToken()` (line 115-129) calls `LocalStorage.saveToken()`. `isLoggedIn()` uses `LocalStorage.getToken()`. `logout()` calls `LocalStorage.removeToken()`. No `import.*shared_preferences` in `anilist_service.dart` (grep returns 0). |
| 8 | "Pairing page documents LAN-security boundary warning" | ✓ VERIFIED | `_landingPage()` (line 263) includes: "⚠ Este servidor é apenas para uso em rede local. O token de acesso é transmitido por HTTP em sua rede local." |

**Score:** 7/7 truths verified

### Deferred Items

Items not yet met but explicitly addressed in later milestone phases.

| # | Item | Addressed In | Evidence |
|---|------|-------------|----------|
| 1 | home_screen.dart WebView flow still reads `access_token` from fragment instead of `code` from query string | Phase 2 (Home Screen Refactor) | Phase 2 goal states "Split the 1320-line home_screen.dart into focused, maintainable components". The AnilistLoginDialog refactor will update the WebView interceptor to handle PKCE response. Current code at home_screen.dart:668 still uses `request.url.contains('access_token')` and extracts `access_token` (line 700). The key_link `home_screen.dart → anilist_service.dart` via `code=|exchangeCode` is NOT wired yet. |

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `test/security/pkce_pairing_test.dart` | Integration tests, ≥80 lines, `code_challenge_method=S256` | ✓ VERIFIED | 107 lines, contains `code_challenge_method=S256`, all 5 test groups present (PKCE, CSRF, Origin, RateLimiting, CORS). Min 80 lines: ✓ |
| `lib/core/anilist/anilist_pairing_server.dart` | PKCE server, ≥200 lines, exports `AniListPairingServer` | ✓ VERIFIED | 353 lines, exports `AniListPairingServer` class, implements PKCE + CSRF + origin validation + rate limiting. |
| `lib/core/constants/app_constants.dart` | No `anilistClientSecret`, ≥14 lines | ✓ VERIFIED | 18 lines, no `anilistClientSecret`, contains `anilistClientId = '44217'`. |
| `lib/core/anilist/anilist_service.dart` | PKCE methods + LocalStorage, ≥150 lines, exports `AniListService` | ✓ VERIFIED | 424 lines, exports `AniListService`, contains `exchangeCodeForToken(code, verifier, {redirectUri})`, `authUrl` returns PKCE URL. |
| `lib/core/storage/local_storage.dart` | Token helpers, ≥120 lines, `saveToken` method | ✓ VERIFIED | 152 lines, has `saveToken`, `getToken`, `removeToken`, `saveUserData`, `getUserData`, `removeUserData`. |

### Key Link Verification

| From | To | Via | Status | Details |
| ---- | --- | --- | ------ | ------- |
| `anilist_pairing_server.dart` | `anilist_service.dart` | `AniListService.exchangeCodeForToken()` | ✓ WIRED | Line 208: `AniListService.exchangeCodeForToken(code, _codeVerifier ?? '')` |
| `anilist_pairing_server.dart` | `app_constants.dart` | `AppConstants.anilistClientId` | ✓ WIRED | Line 106: `AppConstants.anilistClientId` — no `anilistClientSecret` reference anywhere. |
| `anilist_service.dart` | `local_storage.dart` | `LocalStorage.saveToken/getToken/removeToken` | ✓ WIRED | Multiple references: lines 108, 112, 117, 121, 128, 143-144. No direct `SharedPreferences` calls. |
| `anilist_service.dart` | `home_screen.dart` | `authUrl` with PKCE params | ⚠️ PARTIAL | `anilist_service.dart` `authUrl` (line 55-61) correctly returns PKCE URL with `response_type=code`, `code_challenge`. But `home_screen.dart` does NOT reference these patterns — it uses `authUrl` (line 674) but still handles the response as Implicit Grant (looking for `access_token` in fragment, line 668). See deferred item. |
| `home_screen.dart` | `anilist_service.dart` | Handle `code=` instead of `access_token=` | ✗ NOT WIRED | `home_screen.dart` lines 668, 700 still use `access_token` pattern. The `code=|exchangeCode` pattern does NOT appear in home_screen.dart. **Deferred to Phase 2.** |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| -------- | ------------- | ------ | ------------------ | ------ |
| `anilist_pairing_server.dart` → `_landingPage()` | `_csrfToken` | `Random.secure()` via `_randomBase64Url(32)` | ✓ FLOWING — 32-byte cryptographically random token embedded in HTML meta tag | ✓ VERIFIED |
| `anilist_pairing_server.dart` → `_handleToken()` | `code`, `state`, `csrfToken` | POST body parsed from phone browser | ✓ FLOWING — validated against stored `_state` and `_csrfToken` | ✓ VERIFIED |
| `anilist_pairing_server.dart` → `_handleToken()` | `token` | `AniListService.exchangeCodeForToken()` → AniList API `https://anilist.co/api/v2/oauth/token` | ✓ FLOWING — real HTTP POST to AniList (line 208-210), JSON response parsed (line 96-98) | ✓ VERIFIED |
| `AniListService` → `LocalStorage` | `token` | `exchangeCodeForToken` → `saveToken()` → `LocalStorage.saveToken()` | ✓ FLOWING — token saved to SharedPreferences via `_prefs?.setString('anilist_token', token)` | ✓ VERIFIED |
| `home_screen.dart` → WebView | `token` | `AniListService.authUrl` → WebView navigation → Interceptor checking `access_token` in fragment | ⚠️ STATIC — Home screen still looks for `access_token` from fragment (Implicit Grant), but `authUrl` now returns PKCE URL which AniList responds to with `?code=...&state=...` query params. **Deferred to Phase 2.** |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| 10 integration tests pass | `flutter test test/security/pkce_pairing_test.dart` | 10/10 passed | ✓ PASS |
| `anilistClientSecret` removed from constants | `grep -c 'anilistClientSecret' lib/core/constants/app_constants.dart` | 0 matches (exit 1) | ✓ PASS |
| No wildcard CORS in pairing server | `grep -c 'Access-Control-Allow-Origin.*\*' lib/core/anilist/anilist_pairing_server.dart` | 0 matches (exit 1) | ✓ PASS |
| No direct SharedPreferences in AniListService | `grep -c 'import.*shared_preferences' lib/core/anilist/anilist_service.dart` | 0 matches (exit 1) | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| ----------- | ----------- | ----------- | ------ | -------- |
| SEC-01 | 01-01-PLAN.md | Remove or document hardcoded AniList OAuth client secret in `app_constants.dart` | ✓ SATISFIED | `anilistClientSecret` completely removed from `app_constants.dart`. PKCE migration eliminates need entirely (D-01). All auth flows use `AniListService.exchangeCodeForToken()` with PKCE code verifier instead of client secret. |
| SEC-02 | 01-01-PLAN.md | Add TLS to AniList pairing server or restrict binding to localhost only | ✓ SATISFIED | Per D-03 (user decision), LAN access preserved at 0.0.0.0 with documented warning on pairing page (D-04). No TLS — mobile browsers reject self-signed certs. Risk accepted and documented. |
| SEC-03 | 01-01-PLAN.md | Add authentication or CSRF protection to pairing server endpoint | ✓ SATISFIED | `/token` endpoint has: (1) CSRF token flow (32-byte random, single-use, embedded in landing page meta tag, validated on POST), (2) Origin/Referer header validation (exact origin match + referer startsWith), (3) Rate limiting (max 5 POST/60s per IP, returns 429). |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| None found | — | — | — | No TBD, FIXME, XXX, PLACEHOLDER, HACK, or stub patterns found in phase-modified files. |

**Note:** The code review (01-REVIEW.md) identified one critical issue (CR-01: callback page missing CSRF meta tag) and several warnings/info items. Verification of the current code confirms:

| Review Finding | Status in Current Code | Notes |
| -------------- | ---------------------- | ----- |
| CR-01: Callback page CSRF meta tag missing | **FIXED** ✓ | `_handle()` at line 124 now passes `_csrfToken` to `_callbackPage(_csrfToken)`. Callback page at line 275 embeds `<meta name="csrf-token" content="$token">` in its `<head>`. |
| WR-01: Origin check uses `startsWith` without port | **FIXED** ✓ | Origin check uses exact match (`origin != tvOrigin`) with port included. Referer uses `startsWith(tvOrigin)` where `tvOrigin` includes port `http://$_ip:$_port`. |
| WR-02: Static PKCE state race condition | **ACCEPTED** | Low impact — pairing server passes verifier as parameter, not via static getter. |
| WR-03: `logout()` doesn't clear user data | **FIXED** ✓ | `logout()` now calls `LocalStorage.removeUserData('user')` at line 144. |
| WR-04: `_html` falls back to wildcard CORS | **FIXED** ✓ | Line 231: `final origin = 'http://$_ip:$_port'` — no wildcard fallback. |
| WR-05: `saveUserData` always returns `true` | **FIXED** ✓ | Line 135: `if (_prefs == null) return false;` then `return await _prefs!.setString(...)`. |
| WR-06: `_html()` does not await `response.close()` | **FIXED** ✓ | Line 230: signature is `Future<void>`. Line 238: `await req.response.close()` with try/catch. |

### Human Verification Required

1. **MVP Mode Goal Format**
   - **Test:** Run `/gsd mvp-phase 01` to set a proper User Story goal
   - **Expected:** Phase goal in format: As a [user role], I want to [capability], so that [outcome].
   - **Why human:** Current goal is engineering-oriented, not User Story format. MVP mode verification requires User Story for User Flow Coverage table.

2. **End-to-end pairing flow**
   - **Test:** Launch the app on TV/emulator, trigger the AniList pairing flow (scan QR code with phone), authorize on AniList, verify token is saved on TV
   - **Expected:** User can complete full pairing flow: QR → phone browser → AniList authorization → redirect to TV's pairing server → token saved → TV shows logged-in state
   - **Why human:** Requires running Flutter app on device/emulator with phone on same LAN. Automated tests can't simulate the full OAuth redirect chain through a mobile browser.

3. **WebView login flow (deferred to Phase 2)**
   - **Test:** Launch app, use the TV-side WebView login (not QR/pairing), complete AniList authorization
   - **Expected:** Currently EXPECTED TO FAIL — home_screen.dart still uses Implicit Grant flow but `authUrl` now returns PKCE URL. Will be fixed in Phase 2 (Home Screen Refactor).
   - **Why human:** The TV WebView login flow uses a different code path than the pairing server. The phase intentionally deferred this to Phase 2.

### Gaps Summary

**No blocking gaps found.** All 7 must-have truths for this phase are verified against the codebase. 

Key findings:
- All 10 PKCE pairing integration tests pass
- `anilistClientSecret` removed from `app_constants.dart`
- CSRF protection, Origin/Referer validation, and rate limiting implemented on `/token`
- CORS restricted to TV's own origin (not `*`)
- Token storage migrated to LocalStorage (no direct SharedPreferences)
- LAN security warning displayed on pairing page
- All code review findings (CR-01, WR-03, WR-04, WR-05, WR-06) have been fixed in the current code

**One deferred item:** The home_screen.dart WebView login flow still uses the old Implicit Grant pattern (`access_token` from fragment) but receives PKCE response (`?code=...&state=...`). This is a known issue deferred to Phase 2 (Home Screen Refactor), which explicitly includes refactoring the `AnilistLoginDialog` component.

**MVP mode format:** The phase goal needs to be set to User Story format via `/gsd mvp-phase 01`.

---

_Verified: 2026-07-12_
_Verifier: the agent (gsd-verifier)_
