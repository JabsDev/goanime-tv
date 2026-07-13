---
phase: 05-release-configuration
plan: 03
subsystem: release-docs
tags: [release, play-store, privacy, docs]
key-files:
  created:
    - docs/RELEASE_CHECKLIST.md
    - assets/store/screenshot_specs.md
    - assets/privacy_policy.md
  modified:
    - AGENTS.md
metrics:
  tasks: 3/3
  commits: 1
  deviations: 0
---

## Summary

Created release checklist (9 sections covering prerequisites through post-release), Play Store asset specs (screenshots, TV banner, feature graphic), privacy policy covering AniList OAuth and scraper data, and updated AGENTS.md with CI/CD section and release checklist reference.

## Commits

| # | Commit | Description |
|---|--------|-------------|
| 1 | `8a775b6` | Create release checklist, Play Store assets, privacy policy, update AGENTS.md |

## Deviations

None.

## Self-Check

- [x] `docs/RELEASE_CHECKLIST.md` exists with 9 sections and `- [ ]` checklist items
- [x] `assets/store/screenshot_specs.md` documents all image requirements
- [x] `assets/privacy_policy.md` covers AniList + scraper data collection
- [x] `AGENTS.md` updated with `## CI/CD` section and `RELEASE_CHECKLIST.md` reference
- [x] All existing AGENTS.md content preserved

**Self-Check: PASSED**
