---
phase: 4
slug: testing-documentation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-13
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | flutter_test (SDK) + test (^1.25.0) |
| **Config file** | pubspec.yaml dev_dependencies |
| **Quick run command** | `flutter test test/` |
| **Full suite command** | `flutter test` |
| **Estimated runtime** | ~30 seconds (unit) / ~5 minutes (integration) |

---

## Sampling Rate

- **After every task commit:** Run `flutter test test/`
- **After every plan wave:** Run `flutter test test/` (unit) or full suite if device connected
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds (unit) / 5 minutes (integration)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | TEST-01 | T-04-01 / — | N/A — dev dependency install | unit | `grep mocktail pubspec.yaml` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | TEST-01 | — | N/A — pure logic | unit | `flutter test test/core/cache/ttl_cache_test.dart` | ❌ W0 | ⬜ pending |
| 04-01-03 | 01 | 1 | TEST-01 | — | N/A — pure logic | unit | `flutter test test/core/utils/text_utils_test.dart && flutter test test/data/models/anilist_models_test.dart` | ❌ W0 | ⬜ pending |
| 04-02-01 | 02 | 2 | TEST-01 | T-04-02 | Method visibility change — no security impact | unit | `flutter analyze && flutter test test/core/scraper/scraper_result_test.dart` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | TEST-01 | — | N/A — pure logic | unit | `flutter test test/core/scraper/anime_scraper_test.dart` | ❌ W0 | ⬜ pending |
| 04-02-03 | 02 | 2 | TEST-01 | — | N/A — pure logic | unit | `flutter test test/core/helpers/cloudflare_test.dart` | ❌ W0 | ⬜ pending |
| 04-03-01 | 03 | 2 | TEST-02 | T-04-03 | Queries real providers — existing trust boundary | integration | `grep IntegrationTestWidgetsFlutterBinding integration_test/search_detail_playback_test.dart` | ❌ W0 | ⬜ pending |
| 04-03-02 | 03 | 2 | CODE-04 | — | N/A — documentation only | manual | `grep "## Testing" AGENTS.md` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `test/core/cache/ttl_cache_test.dart` — stubs for TtlCache
- [ ] `test/core/utils/text_utils_test.dart` — stubs for TextUtils
- [ ] `test/data/models/anilist_models_test.dart` — stubs for AniListMediaDetail
- [ ] `test/core/scraper/anime_scraper_test.dart` — stubs for AnimeScraper
- [ ] `test/core/helpers/cloudflare_test.dart` — stubs for isCloudflareChallenge
- [ ] `test/core/scraper/scraper_result_test.dart` — stubs for ScraperResult
- [ ] `integration_test/search_detail_playback_test.dart` — integration test
- [ ] `AGENTS.md` — testing section
- [ ] Add `mocktail` dev dependency to `pubspec.yaml`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| AGENTS.md content review | CODE-04 | Documentation correctness requires human review | `cat AGENTS.md` — verify Build & Run, Project Structure, Testing sections present and accurate |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
