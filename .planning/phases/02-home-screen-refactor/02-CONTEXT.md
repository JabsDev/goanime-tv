# Phase 2: Home Screen Refactor - Context

**Gathered:** 2026-07-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Split the 1320-line `home_screen.dart` into focused, maintainable component files. Three target files identified by the codebase concerns audit:

- `lib/features/home/home_screen.dart` (keep ~400 lines — catalog browsing logic)
- `lib/features/home/anilist_login_dialog.dart` (WebView login, QR pairing, manual token entry)
- `lib/features/home/profile_screen.dart` (history + favorites display)

Also extract private helper widgets (`_FocusableAnilistBanner`) into appropriate locations.

All existing functionality must be preserved — no regressions in catalog browsing (trending, seasonal, AniList lists), history, favorites, navigation to search/detail, or AniList login flow. Each extracted component must compile independently with correct imports.

</domain>

<decisions>
## Implementation Decisions

### Extraction Depth & Code Quality
- **D-01:** Fix obvious bugs and lints during extraction, but preserve all class/method names. "Everything except naming changes" — fix empty catches, missing `!mounted` guards, const constructors, and lint warnings, but keep all public/private class and method names identical to avoid breaking external references.
- **D-02:** Pure verbatim copy is NOT desired — improvements are expected where they don't change behavior.

### PKCE WebView Fix Timing
- **D-03:** The Phase 1-deferred PKCE fix (changing `access_token=` fragment interception to `code=` query-string interception in the WebView login dialog) is a **separate step** from extraction. It should be done in its own commit, before or after the structural split, so each change is independently reviewable.

### Navigation Pattern
- **D-04:** ProfileScreen and HomeScreen are standalone screens that each handle their own back-navigation. Common navigation helpers (`_openDetail`, `_openFromHistory`, `_openFromFav`, `_openAnilistDetail`) that are identical across both screens should be extracted into a shared helper file, called from both.

### the agent's Disposition
- The `_FocusableAnilistBanner` widget can be extracted as a feature-private widget (stays in `lib/features/home/`) rather than becoming a shared widget — it's only used by HomeScreen. The planner can decide location based on import cleanliness.
- File naming follows `snake_case.dart` convention: `anilist_login_dialog.dart`, `profile_screen.dart`.
- The extracted navigation helper file name and location are at the planner's discretion.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope & requirements
- `.planning/ROADMAP.md` — Phase 2 definition, goal, success criteria, CODE-01 requirement mapping
- `.planning/REQUIREMENTS.md` — CODE-01 requirement (split home_screen.dart)

### Codebase analysis
- `.planning/codebase/CONCERNS.md` — [HIGH] technical debt: home_screen.dart 1320 lines, the specific split recommendation
- `.planning/codebase/STRUCTURE.md` — File layout, feature directories, existing shared widgets
- `.planning/codebase/CONVENTIONS.md` — Dart code style, import organization, TV widget patterns
- `.planning/codebase/ARCHITECTURE.md` — Data flow, UI layer organization, navigation patterns

### Phase 1 — deferred PKCE fix context
- `.planning/phases/01-security-hardening/01-VERIFICATION.md` — "Deferred Items" section documents the home_screen.dart WebView still using `access_token=` fragment interception while `authUrl` returns PKCE URL with `code=` query param. The key link `home_screen.dart → anilist_service.dart` via `code=|exchangeCode` is NOT wired.

### Prior decisions (Phase 1 carryforward)
- `.planning/phases/01-security-hardening/01-CONTEXT.md` — D-09: AniListService migrated to LocalStorage for token persistence; existing login dialog is compatible.

### Source files to modify
- `lib/features/home/home_screen.dart` — Current monolithic file (1320 lines). Contains HomeScreen, _AnilistLoginDialog, _FocusableAnilistBanner, and ProfileScreen.
- `lib/core/anilist/anilist_service.dart` — authUrl, exchangeCodeForToken, saveToken (used by login dialog)
- `lib/core/storage/local_storage.dart` — Token and history/favorites persistence
- `lib/shared/widgets/focusable_card.dart` — Reused card component
- `lib/shared/widgets/section_header.dart` — Section header component
- `lib/features/detail/detail_screen.dart` — Navigation target for anime detail
- `lib/features/search/search_screen.dart` — Navigation target for search

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `FocusableCard` / `FocusableBannerCard` (`lib/shared/widgets/focusable_card.dart`) — TV-optimized poster cards with focus animation, used by all horizontal scroll rows
- `SectionHeader` (`lib/shared/widgets/section_header.dart`) — Row title with accent bar and optional "See All"
- `CachedImage` (`lib/shared/widgets/cached_image.dart`) — Disk/memory cached image widget with fallback
- `PlayIcon` (`lib/shared/widgets/play_icon.dart`) — Custom-painted play triangle icon
- `TVButton` pattern — `InkWell` + `Semantics(button: true)` with focus-responsive styling

### Established Patterns
- Feature files in `lib/features/{name}/` contain one main screen per file, with tightly-coupled private widgets
- Navigation via `Navigator.push(MaterialPageRoute(...))` — no global state management
- `!mounted` guard after every `await` in StatefulWidget async methods
- `const` constructors on all stateless widgets
- Focus-based TV navigation via `Focus` + `onFocusChange` + `AnimatedContainer`/`AnimatedScale`
- Imports: SDK → Flutter → packages → relative project paths, grouped by blank lines

### Integration Points
- `HomeScreen` calls `AnilistService.isLoggedIn()`, `AnilistService.getUser()`, `AnilistService.getUserAnimeList()` for AniList data
- `_AnilistLoginDialog` calls `AnilistService.authUrl`, `AnilistService.saveToken()`, `AniListPairingServer`
- `ProfileScreen` reads `LocalStorage.getHistory()`, `LocalStorage.getFavorites()`
- Both screens navigate to `DetailScreen(anime: anime)` and `SearchScreen()`
- `_FocusableAnilistBanner` triggers `_showAnilistLogin()` which opens `_AnilistLoginDialog` via `showDialog`

</code_context>

<specifics>
## Specific Ideas

### Extraction File Structure
```
lib/features/home/
├── home_screen.dart              # HomeScreen only (~400 lines)
├── anilist_login_dialog.dart     # AnilistLoginDialog (formerly _AnilistLoginDialog)
├── profile_screen.dart           # ProfileScreen
├── anilist_banner.dart           # AnilistBanner (formerly _FocusableAnilistBanner)
└── home_navigation.dart          # Shared navigation helpers
```

### Fixes to Apply During Extraction
- Replace empty `catch (_) { }` in `_loadDataWithTimeout()` with `catch (e) { debugPrint('[Home] Timeout: $e'); }`
- Add `!mounted` guards missing on async paths in `_loadDataWithTimeout`
- Add `const` constructors where eligible across all extracted files
- Fix any lint warnings from `flutter analyze`

### What NOT to Touch
- Class names (`HomeScreen`, `_HomeScreenState`, `ProfileScreen`, `_ProfileScreenState`, etc.) — keep identical
- Method signatures — don't rename public/private methods
- No behavior changes — extraction + fixes only, no new features

</specifics>

<deferred>
## Deferred Ideas

### PKCE WebView Fix (separate step)
The Phase 1 verification identified that `home_screen.dart` lines 668/700 still use `access_token=` fragment interception, but `AniListService.authUrl` now returns a PKCE URL with `code=` query parameter. This is NOT included in the extraction — it must be done as a separate commit before or after the structural split. The relevant code sections:
- Line 668: `if (request.url.contains('access_token'))`
- Line 700: `RegExp(r'access_token=([^&]+)').firstMatch(url)`
- These need to become: `request.url.contains('code=')` and `RegExp(r'code=([^&]+)').firstMatch(url)`, with the token exchange flowing through `AniListService.exchangeCodeForToken()` instead of `AniListService.saveToken()`.

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 2-Home Screen Refactor*
*Context gathered: 2026-07-12*
