# Phase 4: Testing & Documentation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-13
**Phase:** 4-testing-documentation
**Areas discussed:** Mocking & test framework, Test scope priority, Integration test expansion, AGENTS.md content depth

---

## Mocking & Test Framework

| Option | Description | Selected |
|--------|-------------|----------|
| Add mocktail | Lightweight Dart mocking library, zero boilerplate, no code generation | ✓ |
| Hand-rolled fakes | Write FakeApiClient, FakeCache — explicit but more code | |
| Static HTML fixtures | Store sample HTML responses as fixture files | |

**User's choice:** Add mocktail
**Notes:** Also decided to use fixture files for adapter parsing tests (capture real HTML, mock HTTP via mocktail but serve real HTML). Fixtures organized in test/fixtures/ per adapter/provider.

---

## Test Scope Priority

| Option | Description | Selected |
|--------|-------------|----------|
| Core utilities first | TtlCache, TextUtils, AniListMediaDetail.fromJson — pure logic, no mocking needed | ✓ |
| Scraper orchestration first | AnimeScraper._bestMatch, merge/dedup — complex logic, needs mocktail | |
| Adapter parsing first | Each adapter's core parsing methods — needs fixtures + mocktail | |

**User's choice:** Core utilities first

**Follow-up:** After core utilities, next priority is scraper orchestration, then adapter parsing. Test directory structure mirrors lib/ (e.g., test/core/cache/ttl_cache_test.dart).

---

## Integration Test Expansion

| Option | Description | Selected |
|--------|-------------|----------|
| Search → detail → playback E2E | Full flow matching success criterion directly | ✓ |
| Error handling paths | Test ScraperResult types with controlled failures | |
| Both — E2E + error paths | Comprehensive coverage of both areas | |

**User's choice:** Search → detail → playback E2E

**Follow-up:** Keep existing 4 integration tests as-is — no refactoring.

---

## AGENTS.md Content Depth

| Option | Description | Selected |
|--------|-------------|----------|
| Concise | ~50-80 lines, Build & Run + Project Structure | ✓ |
| Comprehensive | ~150+ lines including architecture, workflow, CI | |

**User's choice:** Concise format

**Follow-up:** Sections: Build & Run commands + Project Structure overview.

---

## the agent's Discretion

- Exact set of core utility files to test beyond TtlCache/TextUtils/AniListMediaDetail
- Whether TtlCache tests need mocktail or can use pure Dart assertions
- Specific fixture file format and naming convention
- Exact AGENTS.md file location (convention is project root)

## Deferred Ideas

- Coverage tooling (flutter test --coverage, Codecov) — natural extension, not in current scope
- CI pipeline setup — belongs in Phase 5 (Release Configuration)
