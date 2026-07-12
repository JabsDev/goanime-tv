# Phase 2: Home Screen Refactor - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-12
**Phase:** 2-Home Screen Refactor
**Areas discussed:** Pure extract vs improve-as-you-go

---

## Pure extract vs improve-as-you-go

| Option | Description | Selected |
|--------|-------------|----------|
| Pure split — verbatim copy | Extract each component as-is with zero changes (except import adjustments) | |
| Fix obvious issues while moving | Fix clear bugs (empty catch, missing !mounted guards) and add const constructors during extraction, but skip style-only changes | ✓ |
| Full cleanup | Fix all lints, add types, improve error messages, and modernize patterns during the split | |

**User's choice:** Fix obvious issues while moving
**Notes:** Selected "Everything except naming changes" when asked which issues count as obvious. Fix all bugs + const + lints, but keep class/method names identical.

### Follow-up: PKCE fix timing

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, fix it during extraction | Fixing the interception logic at the same time is natural | |
| Separate step | Do the PKCE fix in a dedicated commit before or after the extraction | ✓ |

**User's choice:** Separate step
**Notes:** The PKCE WebView fix (access_token= to code=) should be its own commit, independently reviewable.

### Follow-up: Navigation pattern

| Option | Description | Selected |
|--------|-------------|----------|
| Standalone with shared helpers | Each screen handles its own navigation. Extract common helpers into a shared utility. | ✓ |
| Light parent-child | HomeScreen owns common navigation; ProfileScreen receives callbacks. | |

**User's choice:** Standalone with shared helpers

---

## the agent's Discretion

- Location of extracted `_FocusableAnilistBanner` — can stay feature-private or become shared widget
- File names for extracted helpers — planner decides based on import structure
- Navigation helper file naming and location

## Deferred Ideas

- PKCE WebView fix (separate step from extraction) — the `access_token=` → `code=` interception change in the WebView login dialog

---

*Logged: 2026-07-12*
