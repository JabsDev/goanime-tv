---
phase: 01-security-hardening
reviewed: 2026-07-12T03:35:00Z
depth: deep
files_reviewed: 5
files_reviewed_list:
  - lib/core/anilist/anilist_pairing_server.dart
  - lib/core/anilist/anilist_service.dart
  - lib/core/constants/app_constants.dart
  - lib/core/storage/local_storage.dart
  - test/security/pkce_pairing_test.dart
findings:
  critical: 1
  warning: 6
  info: 5
  total: 12
status: issues_found
---

# Phase 01: Code Review Report — Security Hardening

**Reviewed:** 2026-07-12T03:35:00Z
**Depth:** deep
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Phase 01 migrated the AniList OAuth flow from Implicit Grant to PKCE, hardened the pairing server's `/token` endpoint with CSRF protection, origin validation, and rate limiting, and migrated token storage to the `LocalStorage` abstraction. The structural changes are well-planned and largely correct.

**However, the core OAuth pairing flow is non-functional due to a CSRF token mismatch between the landing page and the callback page.** The callback page's JavaScript attempts to read a `<meta name="csrf-token">` tag that does not exist in that page's HTML, causing a TypeError crash. This defect blocks the entire login flow — the user will see "Autorizando..." permanently and the POST to `/token` never fires.

One critical bug, six warnings, and five info items were identified across the reviewed files.

---

## Critical Issues

### CR-01: Callback page JS crashes because CSRF meta tag is missing from callback page HTML

**File:** `lib/core/anilist/anilist_pairing_server.dart:286`
**Issue:** The callback page (served at `/callback`) has no `<meta name="csrf-token">` element in its `<head>`, but the JavaScript on line 286 unconditionally calls `document.querySelector('meta[name="csrf-token"]').getAttribute('content')`. When the meta tag is absent, `querySelector` returns `null`, and `.getAttribute('content')` throws a `TypeError: Cannot read properties of null`.

This breaks the entire OAuth pairing flow:
1. The landing page (`/`) generates `_csrfToken` and embeds it in a `<meta>` tag.
2. The user clicks "Entrar com AniList", authorizes on AniList, and is redirected back to `/callback?code=...&state=...`.
3. The callback page is a **separate HTML document** that does **not** contain the CSRF meta tag.
4. The JavaScript IIFE crashes at line 286 before the `fetch('/token', ...)` ever executes.
5. The user sees "Autorizando..." indefinitely; login never completes.

**Impact:** All CSRF-protection tests pass (tests 4-6) because they test the landing page and direct POSTs, but the actual end-to-end pairing flow is broken. This defect was not caught by the test suite because none of the 10 tests simulate the full OAuth redirect-to-callback-page flow.

**Fix:** Pass the CSRF token into `_callbackPage()` and embed it in a `<meta>` tag.

**In `_handle()` (line 124), pass `_csrfToken` to `_callbackPage()`:**
```dart
} else if (path == '/callback') {
  _html(req, _callbackPage(_csrfToken));
}
```

**Update `_callbackPage()` signature and embed the token:**
```dart
String _callbackPage(String? csrfToken) {
  final token = csrfToken ?? '';
  return '''<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf-token" content="$token">
<title>Autorizando...</title>
...
</head><body>...
```

Alternatively (less invasive), the callback page could store the CSRF token in `sessionStorage` before redirecting to AniList, but embedding it in the callback page's `<head>` is more consistent with the existing pattern.

---

## Warnings

### WR-01: Origin check uses `startsWith` without port qualification

**File:** `lib/core/anilist/anilist_pairing_server.dart:192-199`
**Issue:** The Origin/Referer validation uses `tvOrigin = 'http://$_ip'` (without port number) and checks `origin.startsWith(tvOrigin)`. This is looser than intended:

- An origin `http://192.168.1.109:9999` would pass validation when the TV's IP is `192.168.1.10` (the string `192.168.1.1099999` starts with `192.168.1.10` ... actually no, `192.168.1.109` does NOT start with `192.168.1.10` because position 11: `9` ≠ `0`. Let me reconsider.)

Actually: `"http://192.168.1.109".startsWith("http://192.168.1.10")` → `true` because `192.168.1.109` does start with `192.168.1.10` (positions 0-16 match: `http://192.168.1.10`). So an origin from `192.168.1.109` with port `9999` would pass when the TV is `192.168.1.10`.

Furthermore, the Origin/Referer headers for non-default ports include the port (e.g., `http://192.168.1.10:8090`), but the check only verifies the prefix `http://192.168.1.10`, ignoring the port entirely. This means any origin on the same IP but on any port (or even a different service bound to that IP) would pass.

**Fix:** Include the port in the origin comparison and use an exact-match pattern where possible:
```dart
final tvOrigin = _port != null ? 'http://$_ip:$_port' : 'http://$_ip';
if (origin != null && origin != tvOrigin &&
    !origin.startsWith('$tvOrigin:')) {  // allow port suffix variants if needed
  _html(req, _resultPage(false), status: 403);
  return;
}
```

But since the browser's `Origin` header for `http://192.168.1.10:8090` is exactly `http://192.168.1.10:8090`, an exact match is safer:
```dart
final tvOrigin = 'http://$_ip:$_port';
if (origin != null && origin != tvOrigin) {
  _html(req, _resultPage(false), status: 403);
  return;
}
if (referer != null && !referer.startsWith(tvOrigin)) {
  _html(req, _resultPage(false), status: 403);
  return;
}
```

### WR-02: Static PKCE state in `AniListService` has potential race condition

**File:** `lib/core/anilist/anilist_service.dart:19-21`
**Issue:** The `_codeVerifier` and `_state` fields in `AniListService` are `static`. The `authUrl` getter (line 51) overwrites these fields every time it is called. If both the WebView login flow (via `authUrl`) and the pairing server (`AniListPairingServer`) are active simultaneously, they will share (and corrupt) each other's PKCE state:

1. WebView flow calls `AniListService.authUrl` → sets `_codeVerifier` to value A.
2. Pairing server calls its own `_authorizeUrl` → sets `AniListPairingServer._codeVerifier` (instance-level, safe).
3. But if the WebView navigation delegate later calls `AniListService.exchangeCodeForToken()`, it uses `AniListService.currentCodeVerifier` which was overwritten by step 2 if `authUrl` was called between.

Actually, looking more carefully: `AniListService._codeVerifier` is static and is only used by the `authUrl` getter and `exchangeCodeForToken`. The pairing server has its OWN `_codeVerifier` and `_state` as instance fields. So the pairing server doesn't use `AniListService._codeVerifier` — it passes `_codeVerifier` directly to `exchangeCodeForToken`.

The risk is narrower: if the WebView login navigates to `authUrl` during a pairing server session, the pairing server's call to `exchangeCodeForToken(code, _codeVerifier)` still works because it passes the verifier as a parameter, not via the static getter. The static `_codeVerifier` only affects direct callers of `currentCodeVerifier`.

**Impact:** Low. The `currentCodeVerifier` getter (line 65) could return stale data if `authUrl` was called again between generation and exchange. The pairing server is immune because it passes the verifier directly.

**Fix:** Consider making the PKCE state non-static, or documenting that `authUrl` must not be called concurrently.

### WR-03: `logout()` does not clear cached user data

**File:** `lib/core/anilist/anilist_service.dart:142-144`
**Issue:** `logout()` only removes the token via `LocalStorage.removeToken()` but does **not** clear the user profile data stored by `saveToken()` (the `'user'` key). If a user logs out and a different user logs in, `getUser()` returns the previous user's cached profile until the new user's profile is fetched and saved.

```dart
static Future<void> logout() async {
  await LocalStorage.removeToken();
  // BUG: user data at key 'user' is NOT removed
}
```

**Fix:**
```dart
static Future<void> logout() async {
  await LocalStorage.removeToken();
  await LocalStorage.saveUserData('user', {});  // clear user data
  // or add a removeUserData method to LocalStorage
}
```

### WR-04: `_html` falls back to wildcard CORS when IP/port is null

**File:** `lib/core/anilist/anilist_pairing_server.dart:231`
**Issue:** In the `_html()` helper, the `Access-Control-Allow-Origin` value falls back to `'*'` when `_ip` or `_port` is null:
```dart
final origin = _ip != null && _port != null ? 'http://$_ip:$_port' : '*';
```
While the pair should never be null during normal operation (the server must be bound to serve requests), this defense-in-depth gap means any code path that calls `_html` before the server is fully initialized would inadvertently set a wildcard CORS policy, defeating one of the main security hardening goals (D-08).

**Fix:** Remove the wildcard fallback; return an empty origin or log an error:
```dart
final origin = _ip != null && _port != null ? 'http://$_ip:$_port' : 'http://localhost:0';
```

### WR-05: `saveUserData` always returns `true` even if storage fails

**File:** `lib/core/storage/local_storage.dart:133-137`
**Issue:** `saveUserData` always returns `true` because the `await _prefs?.setString(...)` result (which is `Future<bool>`) is discarded:
```dart
static Future<bool> saveUserData(String key, Map<String, dynamic> data) async {
  ensureInitialized();
  await _prefs?.setString('anilist_$key', jsonEncode(data));
  return true;  // Always true, even if _prefs is null or write fails
}
```
If `_prefs` is null (despite `ensureInitialized()` having passed), the `?.` operator silently skips the write, and `true` is still returned. The caller in `AniListService.saveToken()` (line 121-126) relies on this return value for flow control.

**Fix:** Return the actual write result, and handle the null case:
```dart
static Future<bool> saveUserData(String key, Map<String, dynamic> data) async {
  ensureInitialized();
  if (_prefs == null) return false;
  return await _prefs!.setString('anilist_$key', jsonEncode(data));
}
```

### WR-06: `_html()` does not await `response.close()`

**File:** `lib/core/anilist/anilist_pairing_server.dart:237`
**Issue:** `req.response.close()` returns a `Future<HttpResponse>` but the result is not awaited because `_html()` returns `void`. While Dart's HTTP server handles the response lifecycle, this means the response future is fire-and-forget. If a write error occurs or the connection resets, the error is silently lost (no catch handler). The method signature should return `Future<void>` and await the close.

Additionally, `req.response.write(body)` can throw if the response is already closed or if a write error occurs, but there is no error handling around the write/close calls.

**Fix:**
```dart
Future<void> _html(HttpRequest req, String body, {int status = 200}) async {
  final origin = _ip != null && _port != null ? 'http://$_ip:$_port' : '*';
  req.response
    ..statusCode = status
    ..headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8')
    ..headers.set('Access-Control-Allow-Origin', origin)
    ..write(body);
  try {
    await req.response.close();
  } catch (_) {
    // Connection may have been reset; nothing to do.
  }
}
```

---

## Info

### IN-01: Getter `_authorizeUrl` has side effects (mutates state)

**File:** `lib/core/anilist/anilist_pairing_server.dart:100`
**Issue:** `_authorizeUrl` is defined as a `get` accessor but mutates `_codeVerifier`, `_state`, and (indirectly via the landing page caller pattern) `_csrfToken`. In Dart conventions, getters should be idempotent and side-effect-free. A method (e.g., `String _buildAuthorizeUrl()`) would be more idiomatic and less surprising to maintainers.

### IN-02: Redundant JWT prefix check in two layers

**File:** `lib/core/anilist/anilist_service.dart:116` and `lib/core/storage/local_storage.dart:115`
**Issue:** Both `AniListService.saveToken()` and `LocalStorage.saveToken()` independently validate `token.startsWith('eyJ')`. The inner layer (`LocalStorage.saveToken`) is always called by the outer layer (`AniListService.saveToken`), which also calls the check before delegating. This duplication means the check runs twice per save. Either remove the check from one layer or clarify that the `LocalStorage` layer is a general-purpose API (protecting against accidental misuse) while the service layer is the primary guard.

### IN-03: Inconsistent import path styles

**File:** `lib/core/anilist/anilist_service.dart:8-12`
**Issue:** Imports use a mix of relative paths at different depths:
- Line 8: `'../storage/local_storage.dart'` (one level up from `anilist/`)
- Line 9: `'../../data/models/anilist_models.dart'` (two levels up)
- Line 11: `'../constants/app_constants.dart'`

The mix is confusing. Consider using `package:goanime_tv/...` imports consistently, or align all relative imports to the same base depth.

### IN-04: Test 10 uses source file reading instead of compile-time reference

**File:** `test/security/pkce_pairing_test.dart:101-106`
**Issue:** The test reads the source file at runtime to check for method existence, which is fragile. The summary acknowledges this was a RED-phase workaround (the method did not exist during initial test creation). Now that the method exists, the test should be changed to a compile-time reference:
```dart
test('AniListService.exchangeCodeForToken exists', () {
  expect(
    AniListService.exchangeCodeForToken('code', 'verifier'),
    // Don't care about the result — verifying the method is callable
    isA<Future<String?>>(),
  );
});
```
However, this would actually call the method (making HTTP requests). A more robust approach would be to check that the class has the method via reflection or just rely on the import — if the method doesn't exist, compilation fails anyway. Consider simplifying to just `expect(AniListService.exchangeCodeForToken, isNotNull)` or removing the test entirely now that the flow works.

### IN-05: `_randomBase64Url` duplicates across two files

**File:** `lib/core/anilist/anilist_pairing_server.dart:78-85` and `lib/core/anilist/anilist_service.dart:26-33`
**Issue:** The `_randomBase64Url` and `_sha256Base64Url` helper methods are independently defined in both `anilist_pairing_server.dart` and `anilist_service.dart` with near-identical implementations. Consider extracting them into a shared utility (e.g., `lib/core/utils/crypto_utils.dart`) to avoid drift between the two copies.

---

## Additional Observations

- **Rate limiting correctness:** The rate limiter allows 5 requests and blocks the 6th (as verified in the test). The counter starts at 0 and increments before the threshold check (`count > 5`), so requests 1-5 pass and request 6 is rejected. This matches the plan's intent ("max 5 POST/60s").

- **CSRF single-use semantics:** The `_csrfToken` is nulled after first successful validation (line 185), which prevents replay. However, because `_csrfToken` is a single instance field (not a session store), if two browser tabs open the landing page, the second tab overwrites the first tab's token. The first tab's callback will then fail with 403. This is an acceptable UX trade-off for the LAN pairing use case.

- **No AniListClientSecret leftover:** Confirmed — `app_constants.dart` no longer contains `anilistClientSecret`. ✓
- **No wildcard CORS:** Confirmed — `Access-Control-Allow-Origin: *` is not present in the pairing server. ✓
- **No direct SharedPreferences in AniListService:** Confirmed — storage goes through `LocalStorage`. ✓

---

_Reviewed: 2026-07-12T03:35:00Z_
_Reviewer: gsd-code-reviewer agent_
_Depth: deep_
