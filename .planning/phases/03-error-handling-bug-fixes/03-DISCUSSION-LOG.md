# Phase 3: Error Handling & Bug Fixes - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-12
**Phase:** 3-error-handling-bug-fixes
**Areas discussed:** Error type design, Error recovery per type, Cloudflare detection robustness, Error propagation to UI, SuperFlix domain fix, Episode sorting fix

---

## Error Type Design

| Option | Description | Selected |
|--------|-------------|----------|
| Sealed class (Recommended) | ScraperResult<T> sealed class with Loading, Success(T), Failure(ScraperError) variants | ✓ |
| Enum-based error codes | ScraperErrorCode enum on a custom Exception — simpler but less exhaustive-check safety | |
| Keep as-is | Existing catch → debugPrint → return [] pattern | |

**User's choice:** Sealed class (Recommended)
**Notes:** Type-safe exhaustive matching preferred

**Follow-up — Error variants:**

| Option | Description | Selected |
|--------|-------------|----------|
| timeout, parseFailure, cloudflare, emptyResult, unknown | Five variants covering all CONCERNS.md findings | ✓ |
| Just timeout, parseFailure, cloudflare | Three variants from the HIGH concern | |

**User's choice:** timeout, parseFailure, cloudflare, emptyResult, unknown

**Follow-up — Error data:**

| Option | Description | Selected |
|--------|-------------|----------|
| Message + source + duration (Recommended) | Every variant gets message, AnimeSource, operationDuration. Cloudflare gets detection pattern. Timeout gets timeout value. ParseFailure gets snippet. | ✓ |
| Message only | Simpler — just a string message | |

**User's choice:** Message + source + duration (Recommended)

---

## Error Recovery Per Type

**Timeout:**

| Option | Description | Selected |
|--------|-------------|----------|
| Retry once, then return Failure(timeout) | Single retry with the same timeout. If both fail, propagate error. | ✓ |
| No retry — return immediately | Fail fast — orchestrator fans out to 4 sources anyway | |
| Retry with longer timeout | First attempt 15s, retry 30s | |

**User's choice:** Retry once, then return Failure(timeout)

**Parse failure:**

| Option | Description | Selected |
|--------|-------------|----------|
| Return Failure(parseFailure) with debug info | Log parsing error with snippet — no retry | ✓ |
| Return empty list silently | Same as current debugPrint → return [] | |

**User's choice:** Return Failure(parseFailure) with debug info

**Cloudflare:**

| Option | Description | Selected |
|--------|-------------|----------|
| Return Failure(cloudflare) — let orchestrator fall through | Adapter returns Cloudflare error; AnimeScraper tries other sources | ✓ |
| Return Failure(cloudflare) AND trigger WebView bypass | For SuperFlix: automatically escalate to WebView | |

**User's choice:** Return Failure(cloudflare) — let orchestrator fall through

**Empty results:**

| Option | Description | Selected |
|--------|-------------|----------|
| Return Failure(emptyResult) — keep it explicit | Empty results are a distinct error variant | ✓ |
| Return empty list — not an error | Empty results are a valid state | |

**User's choice:** Return Failure(emptyResult) — keep it explicit

---

## Cloudflare Detection Robustness

| Option | Description | Selected |
|--------|-------------|----------|
| Multi-pattern check (Recommended) | Check for 'Verificação', 'cf-browser-verification', 'cf-challenge', status 403/503, CF-Ray headers | ✓ |
| Keep as-is, document fragility | Single string check with doc comment | |

**User's choice:** Multi-pattern check (Recommended)

**Follow-up — Scope:**

| Option | Description | Selected |
|--------|-------------|----------|
| Include in Phase 3 | Part of CODE-02 — directly improves error type accuracy | ✓ |
| Defer to later phase | Keep scope small | |

**User's choice:** Include in Phase 3

---

## Error Propagation to UI

| Option | Description | Selected |
|--------|-------------|----------|
| Stay in log layer (Recommended) | Errors remain as typed Failure results internally. UI still sees empty states. | ✓ |
| Surface to user | Show error banners/toasts for network failures and Cloudflare blocks | |

**User's choice:** Stay in log layer (Recommended)

---

## SuperFlix Domain Fix (CODE-03)

| Option | Description | Selected |
|--------|-------------|----------|
| Use app_constants.dart as source of truth (Recommended) | Replace hardcoded .pro with AppConstants.superFlixBase | ✓ |
| Make it configurable | Read from AppConstants but allow override | |

**User's choice:** Use app_constants.dart as source of truth (Recommended)

---

## Episode Sorting Fix (BUG-01)

| Option | Description | Selected |
|--------|-------------|----------|
| Sort unparseable to end via sentinel (Recommended) | Use double.infinity/int.maxValue as default sort value | ✓ |
| Same approach but extract helper | Create utility function parseEpisodeNumber(String?) → double | |

**User's choice:** Sort unparseable to end via sentinel (Recommended)

---

## the agent's Discretion

- Exact sealed class file location (planner decides)
- Whether to convert all adapter methods or wrap at orchestrator level
- Shared utility for episode sorting or inline sentinel
- Specific Cloudflare detection pattern set

## Deferred Ideas

- PKCE WebView fix (access_token= → code=) remains deferred from Phase 2

