# Phase 1: Security Hardening - Context

**Gathered:** 2026-07-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Eliminate CRITICAL/HIGH security vulnerabilities in the AniList OAuth integration and pairing server. Three requirements: SEC-01 (hardcoded client secret), SEC-02 (pairing server binds to 0.0.0.0 with no TLS), SEC-03 (no auth on /token endpoint).

The pairing server's LAN-based phone-to-TV OAuth flow must remain functional — security improvements cannot break the existing login UX.

</domain>

<decisions>
## Implementation Decisions

### OAuth Flow Modernization
- **D-01:** Switch AniList OAuth from Implicit Grant (`response_type=token`) to **PKCE** (Proof Key for Code Exchange). This eliminates the need for the hardcoded `client_secret` entirely and is OAuth 2.0 best practice for native/mobile apps. SEC-01 is resolved by removing the secret, not documenting it.
- **D-02:** The pairing server callback URL will use the PKCE authorization code flow: AniList redirects with a `code` instead of an access token fragment; the pairing server exchanges the code using the PKCE verifier stored during initial page load.

### Pairing Server Network Security
- **D-03:** Keep LAN access (0.0.0.0 binding) — the phone must reach the TV over LAN for the pairing flow. TLS with a self-signed certificate is impractical (mobile browsers reject it).
- **D-04:** Document the LAN-security boundary in the pairing page and the code: "This server is intended for local network use only. The access token is transmitted over HTTP on your local network."

### /token Endpoint Protection
- **D-05:** Replace the unprotected /token POST with a **CSRF token** flow: the landing page embeds a cryptographically random token in the HTML; the callback JS must include this token in the POST body. Server validates before accepting.
- **D-06:** Add **Origin/Referer header validation** — reject POSTs without a matching Origin or Referer header from the TV's own IP.
- **D-07:** Add basic **rate limiting** — max 5 POST attempts per 60s per client IP to the /token endpoint.
- **D-08:** Remove `Access-Control-Allow-Origin: *` — restrict to the TV's own origin only.

### Token Storage Migration
- **D-09:** Migrate `AniListService` to use `LocalStorage` (SharedPreferences wrapper) instead of calling `SharedPreferences.getInstance()` directly. This addresses the CONCERNS.md finding about inconsistent storage patterns and is a natural part of touching token handling code.

### the agent's Discretion
- The CSRF token generation mechanism (Dart `Random.secure()` vs package) is implementation detail — planner can choose
- Rate limit window/exact count can be tuned during planning
- PKCE code challenge method (S256 vs plain) — S256 recommended, planner confirms

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Security requirements
- `.planning/REQUIREMENTS.md` — SEC-01, SEC-02, SEC-03 (v1 requirements)
- `.planning/codebase/CONCERNS.md` — Security section with CRITICAL/HIGH findings

### Source files (current state, will be modified)
- `lib/core/constants/app_constants.dart` — Hardcoded `anilistClientSecret` (line 13) and `anilistClientId` (line 12)
- `lib/core/anilist/anilist_pairing_server.dart` — Full pairing server: HTTP binding (line 43), no-auth /token (line 91), CORS wildcard (line 113), Implicit Grant flow (lines 61-67)
- `lib/core/anilist/anilist_service.dart` — Token storage via direct SharedPreferences (lines 21-46), OAuth auth URL generation (lines 15-19)
- `lib/core/storage/local_storage.dart` — Storage abstraction that AniListService currently bypasses

### OAuth 2.0 PKCE reference
- PKCE RFC 7636 — Standard for native app OAuth: https://datatracker.ietf.org/doc/html/rfc7636
- AniList OAuth docs: https://anilist.gitbook.io/anilist-apiv2-docs/overview/oauth

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `LocalStorage` (`lib/core/storage/local_storage.dart`) — Existing SharedPreferences wrapper that AniListService should migrate to
- `AppCaches` (`lib/core/cache/app_caches.dart`) — TTL cache pattern could be used for rate limiting state
- Inline HTML/JS generation pattern in `anilist_pairing_server.dart` — the existing callback flow structure will be adapted for PKCE + CSRF

### Established Patterns
- Static utility classes (e.g., `AniListService` with static methods) — consistent with existing pattern but may need instance-based state for PKCE verifier
- `AppConstants` for configuration values — the client_secret will be removed from here

### Integration Points
- `lib/core/anilist/anilist_pairing_server.dart` — All three security concerns converge here. Full rewrite of OAuth flow, endpoint protection, and binding behavior.
- `lib/core/constants/app_constants.dart` — Remove `anilistClientSecret` after PKCE migration
- `lib/core/anilist/anilist_service.dart` — Update token storage to use LocalStorage; update `authUrl` for PKCE
- `lib/features/home/home_screen.dart` — Pairing dialog triggers the flow; verify no breaking changes to pairing UI

</code_context>

<specifics>
## Specific Ideas

### PKCE Integration Sketch
1. Landing page generates a `code_verifier` (random 128-byte) and stores it in server memory keyed by a `state` parameter
2. Landing page computes `code_challenge = base64url(sha256(code_verifier))` (S256)
3. Authorize URL includes `code_challenge`, `code_challenge_method=S256`, and `state`
4. AniList redirects to `/callback?code=...&state=...`
5. Server validates `state`, then exchanges `code` + `code_verifier` for token via AniList's token endpoint
6. Server saves token and notifies the app

### CSRF Token Sketch
1. Landing page generates `csrf_token = Random.secure()`, embeds in HTML as a meta tag
2. Callback JS reads meta tag, includes `csrf_token` in POST body
3. Server validates token before accepting the POST
4. Token is single-use (invalidated after first POST or timeout)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 1-Security Hardening*
*Context gathered: 2026-07-11*
