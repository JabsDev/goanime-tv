# Phase 1: Security Hardening - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-11
**Phase:** 1-Security Hardening
**Areas discussed:** OAuth Flow, Pairing Server Network, Token Endpoint Protection, Token Storage

**Mode:** --auto (all decisions selected automatically from recommended defaults)

---

## OAuth Flow Modernization

[auto] — Q: "Should we switch from Implicit Grant to PKCE?" → Selected: "Yes, switch to PKCE" (recommended — eliminates client_secret requirement entirely)

| Option | Description | Selected |
|--------|-------------|----------|
| Keep Implicit Grant, document secret | Keep current flow, acknowledge secret is public-insecure | |
| Switch to PKCE | Modern OAuth 2.0 best practice for native apps, removes need for client_secret | ✓ |
| Server-side proxy | Route OAuth through an external backend | |

**User's choice:** PKCE (auto-selected)
**Notes:** PKCE eliminates SEC-01 root cause. AniList supports PKCE per their OAuth docs. Requires modifying the pairing server to handle the code exchange flow.

---

## Pairing Server Network Security

[auto] — Q: "How to handle pairing server LAN access?" → Selected: "Keep LAN access + add protections" (recommended — localhost breaks pairing UX)

| Option | Description | Selected |
|--------|-------------|----------|
| Bind to localhost only | Most secure, but breaks phone→TV QR pairing flow | |
| Keep LAN + CSRF + origin validation | Maintains UX, adds meaningful protections | ✓ |
| Keep LAN + TLS with self-signed cert | Technically complex, mobile browsers reject self-signed | |

**User's choice:** Keep LAN + CSRF + origin validation (auto-selected)
**Notes:** TLS is infeasible for local IP addresses. Origin/referer validation and CSRF are the practical mitigations.

---

## /token Endpoint Protection

[auto] — Q: "What authentication for the /token POST endpoint?" → Selected: "CSRF token + origin validation + rate limiting" (recommended — defense in depth)

| Option | Description | Selected |
|--------|-------------|----------|
| CSRF token in landing page + origin validation | Defense in depth, standard web security patterns | ✓ |
| Pre-shared secret displayed on TV | User must enter code on phone, extra friction | |
| Rate limiting only | Minimal protection, no auth | |

**User's choice:** CSRF + origin validation + rate limiting (auto-selected)
**Notes:** Three layers: CSRF token prevents cross-page attacks, origin validation prevents arbitrary POSTs, rate limiting prevents brute force.

---

## Token Storage Migration

[auto] — Q: "Should AniListService migrate to LocalStorage?" → Selected: "Yes, migrate now" (recommended — consistent pattern, natural time to do it)

| Option | Description | Selected |
|--------|-------------|----------|
| Migrate to LocalStorage | Consistent with rest of codebase, easier future migration | ✓ |
| Leave as direct SharedPreferences | Lower risk of regression, defer cleanup | |

**User's choice:** Migrate to LocalStorage (auto-selected)
**Notes:** Token handling code is being modified anyway for PKCE. Low additional risk to fix the storage pattern at the same time.

---

## the agent's Discretion

- CSRF token generation algorithm (cryptographically random via Dart's `Random.secure()`)
- Rate limit window and max attempts (suggested: 5 attempts per 60s per IP)
- PKCE challenge method (S256 recommended over plain)
- HTML/CSS styling of login pages (keep existing design, minimal changes)

## Deferred Ideas

None — discussion stayed within phase scope.
