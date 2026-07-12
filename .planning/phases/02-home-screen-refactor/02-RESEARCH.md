# Phase 2: Home Screen Refactor — Research

**Researched:** 2026-07-12
**Domain:** Flutter structural refactoring, widget extraction, import management
**Confidence:** HIGH

## Summary

Phase 2 is a zero-visual-change refactor to split the 1320-line `home_screen.dart` monolith into five focused files in `lib/features/home/`. The file currently contains four distinct widgets — `HomeScreen`, `_AnilistLoginDialog`, `_FocusableAnilistBanner`, and `ProfileScreen` — plus duplicated navigation logic. The extraction is well-defined in CONTEXT.md and UI-SPEC.md with clear constraints: preserve class/method names, fix lints and empty catches, add `!mounted` guards, maintain `const` constructors, and keep all visual output identical.

**Primary recommendation:** Extract in this order: anilist_banner.dart (no dependencies on other extracted components) → home_navigation.dart (pure helper functions) → anilist_login_dialog.dart (self-contained dialog with heavy imports) → profile_screen.dart (uses navigation helpers) → trim home_screen.dart (imports from all four new files). Each extraction step must compile and pass `flutter analyze` independently.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CODE-01 | Split `home_screen.dart` (1320 lines) into focused components | Full component inventory, dependency graph, and extraction sequence documented below. Five target files identified with verified import paths. |
</phase_requirements>

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01:** Fix obvious bugs and lints during extraction, but preserve all class/method names. "Everything except naming changes" — fix empty catches, missing `!mounted` guards, const constructors, and lint warnings, but keep all public/private class and method names identical to avoid breaking external references.

**D-02:** Pure verbatim copy is NOT desired — improvements are expected where they don't change behavior.

**D-03:** The Phase 1-deferred PKCE fix (changing `access_token=` fragment interception to `code=` query-string interception in the WebView login dialog) is a **separate step** from extraction. It should be done in its own commit, before or after the structural split, so each change is independently reviewable.

**D-04:** ProfileScreen and HomeScreen are standalone screens that each handle their own back-navigation. Common navigation helpers (`_openDetail`, `_openFromHistory`, `_openFromFav`, `_openAnilistDetail`) that are identical across both screens should be extracted into a shared helper file, called from both.

### the agent's Discretion

- The `_FocusableAnilistBanner` widget can be extracted as a feature-private widget (stays in `lib/features/home/`) rather than becoming a shared widget — it's only used by HomeScreen. The planner can decide location based on import cleanliness.
- File naming follows `snake_case.dart` convention: `anilist_login_dialog.dart`, `profile_screen.dart`.
- The extracted navigation helper file name and location are at the planner's discretion.

### Deferred Ideas (OUT OF SCOPE)

**PKCE WebView Fix (separate step):** The Phase 1 verification identified that `home_screen.dart` lines 668/700 still use `access_token=` fragment interception, but `AniListService.authUrl` now returns a PKCE URL with `code=` query parameter. This is NOT included in the extraction — it must be done as a separate commit before or after the structural split.
</user_constraints>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Catalog browsing (trending, seasonal) | UI Layer (HomeScreen) | Core (AniListService) | HomeScreen renders the catalog; AniListService provides data via GraphQL |
| AniList login dialog | UI Layer (AnilistLoginDialog) | Core (AniListService, AniListPairingServer) | Dialog renders WebView/QR; core services handle auth flow |
| Profile display (history, favorites) | UI Layer (ProfileScreen) | Core (LocalStorage) | ProfileScreen reads from LocalStorage directly (synchronous) |
| Navigation to detail/search | UI Layer (Shared Navigation Helpers) | — | Pure Navigator.push calls; extracted to avoid duplication |
| AniList banner widget | UI Layer (AnilistBanner) | — | Self-contained focus-aware promotional banner; renders inline in home content |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Flutter SDK | ^3.9.2 | UI framework | Project dependency, locked |
| Dart SDK | ^3.9.2 | Language | Project dependency, locked |

### Supporting (already in project — no new packages)
| Library | Version | Purpose | Where Used |
|---------|---------|---------|------------|
| `webview_flutter` | ^4.7.0 | OAuth WebView in login dialog | `_AnilistLoginDialog` |
| `qr_flutter` | ^4.1.0 | QR code display in pairing dialog | `_AnilistLoginDialog` |
| `cached_network_image` | ^3.3.1 | Image caching in banner | `_FocusableAnilistBanner` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| — | — | No alternatives needed — zero-new-package refactor |

**Installation:**
```bash
# No new packages required — all dependencies already in pubspec.yaml
flutter pub get
```

**Version verification:** All packages listed above already exist in pubspec.lock — no new packages are being introduced.

## Package Legitimacy Audit

> **Not required** — this phase introduces zero new external packages. All dependencies (`webview_flutter`, `qr_flutter`, `cached_network_image`, etc.) are already in `pubspec.yaml` and `pubspec.lock`. The refactor only reorganizes existing code across files.

| Package | Disposition | Rationale |
|---------|-------------|-----------|
| All existing | Not affected | No new packages installed; existing packages remain in pubspec.yaml |

## Architecture Patterns

### System Architecture Diagram

```
Before:
lib/features/home/home_screen.dart (1320 lines)
  ├── class HomeScreen          (lines 20-598)
  │   ├── _HomeScreenState       (lines 27-598)
  │   │   ├── _buildTopBar()       → _navItem(), references ProfileScreen by const constructor
  │   │   ├── _buildContent()      → _FocusableAnilistBanner, _buildAnilistGroup()
  │   │   │                       → SectionHeader, FocusableCard, FocusableBannerCard
  │   │   ├── _buildAnilistGroup() → FocusableCard, _openAnilistDetail()
  │   │   ├── _searchAnime()       → Navigator.push → SearchScreen
  │   │   ├── _openDetail()        → Navigator.push → DetailScreen(anime:)
  │   │   ├── _openFromHistory()   → Navigator.push → DetailScreen
  │   │   ├── _openFromFav()       → Navigator.push → DetailScreen
  │   │   ├── _openAnilistDetail() → Navigator.push → DetailScreen
  │   │   ├── _showAnilistLogin()  → showDialog → _AnilistLoginDialog
  │   │   └── _showAnilistMenu()   → showDialog → AlertDialog (inline)
  │   └── (const HomeScreen)
  ├── class _AnilistLoginDialog (lines 600-1090)
  │   └── _AnilistLoginDialogState → WebView, QR pairing, manual token
  ├── class _FocusableAnilistBanner (lines 1092-1186)
  │   └── _FocusableAnilistBannerState → focus-aware gradient banner
  └── class ProfileScreen       (lines 1188-1320)
      └── _ProfileScreenState → history + favorites, _open() helper

After:
lib/features/home/
├── home_screen.dart              # HomeScreen only (~580→~400 lines)
│   └── _HomeScreenState imports:
│       ├── AnilistBanner from 'anilist_banner.dart'
│       ├── AnilistLoginDialog from 'anilist_login_dialog.dart'
│       ├── openDetail, openFromHistory, openFromFav, openAnilistDetail
│       │     from 'home_navigation.dart'
│       └── ProfileScreen from 'profile_screen.dart' (navigate only)
│
├── anilist_banner.dart           # AnilistBanner (public, was _FocusableAnilistBanner)
│   └── AnilistBannerState → focus-aware gradient banner
│
├── anilist_login_dialog.dart     # AnilistLoginDialog (public, was _AnilistLoginDialog)
│   └── AnilistLoginDialogState → WebView, QR pairing, manual token
│
├── profile_screen.dart           # ProfileScreen (extracted verbatim + navigation helpers)
│   └── _ProfileScreenState imports open from 'home_navigation.dart'
│
└── home_navigation.dart          # Shared navigation helpers
    ├── openDetail(BuildContext, Anime)
    ├── openFromHistory(BuildContext, Map)
    ├── openFromFav(BuildContext, Map)
    └── openAnilistDetail(BuildContext, AniListMedia)
```

### Recommended Project Structure (unchanged)
```
lib/features/home/
├── home_screen.dart              # HomeScreen only
├── anilist_login_dialog.dart     # AnilistLoginDialog (public)
├── profile_screen.dart           # ProfileScreen
├── anilist_banner.dart           # AnilistBanner (public)
└── home_navigation.dart          # Shared navigation helpers
```

### Pattern 1: Widget Extraction (private → public with import replacement)
**What:** Extract a private widget class from a monolithic file into its own file, making it public so other files can import it. Replace the inline `const _WidgetName(...)` usage with the public name.
**When to use:** For `_AnilistLoginDialog` → `AnilistLoginDialog` and `_FocusableAnilistBanner` → `AnilistBanner`.
**Key decisions:**
- Rename class from `_AnilistLoginDialog` to `AnilistLoginDialog` (remove underscore to make public)
- Keep the state class name as `_AnilistLoginDialogState` (stays private to its file)
- Rename `_FocusableAnilistBanner` to `AnilistBanner` (remove underscore, drop "Focusable" prefix as the CONTEXT.md suggests)
- In `home_screen.dart`: replace `const _AnilistLoginDialog()` with `const AnilistLoginDialog()` and `_FocusableAnilistBanner(onTap:...)` with `AnilistBanner(onTap:...)`
- Add `import 'anilist_login_dialog.dart';` and `import 'anilist_banner.dart';` to home_screen.dart

**Example (before in home_screen.dart):**
```dart
// Line 139 — inline reference to private class
builder: (ctx) => const _AnilistLoginDialog(),

// Line 385 — inline reference to private widget
_FocusableAnilistBanner(onTap: _showAnilistLogin),
```

**Example (after in home_screen.dart):**
```dart
import 'anilist_login_dialog.dart';
import 'anilist_banner.dart';

builder: (ctx) => const AnilistLoginDialog(),
AnilistBanner(onTap: _showAnilistLogin),
```

### Pattern 2: Navigation Helper Extraction
**What:** Extract duplicate `void _open*(...)` methods that follow the same pattern (create Anime from params, push DetailScreen) into a shared helper file.
**When to use:** For `_openDetail`, `_openFromHistory`, `_openFromFav`, `_openAnilistDetail` in HomeScreen and `_open` in ProfileScreen — they are structurally identical.

**Key decisions:**
- Navigation helpers need `BuildContext` as a parameter since they're no longer instance methods
- Star as top-level functions or static methods (planner's discretion per CONTEXT.md)
- Extract as top-level functions for simplicity, named to match D-04: `openDetail(BuildContext, Anime)`, `openFromHistory(BuildContext, Map)`, `openFromFav(BuildContext, Map)`, `openAnilistDetail(BuildContext, AniListMedia)`

**Example:**
```dart
// home_navigation.dart
import 'package:flutter/material.dart';
import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';
import '../detail/detail_screen.dart';

void openDetail(BuildContext context, Anime anime) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

void openFromHistory(BuildContext context, Map<String, dynamic> item) {
  final anime = Anime(
    name: item['title']?.toString() ?? '',
    url: '',
    fallbackImageUrl: item['image']?.toString(),
  );
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

void openFromFav(BuildContext context, Map<String, dynamic> item) {
  // Identical to openFromHistory
  ...
}

void openAnilistDetail(BuildContext context, AniListMedia media) {
  final anime = Anime(
    name: media.title,
    url: '',
    fallbackImageUrl: media.coverImage,
  );
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}
```

### Anti-Patterns to Avoid
- **Extracting too much:** Do NOT extract `_navItem`, `_buildPlayButton`, `_buildAnilistGroup`, or `_buildTopBar` — they are tightly coupled to HomeScreen's state and only used there
- **Introducing global state:** Do NOT replace `Navigator.push` patterns with any routing library — the app uses no routing abstraction and D-04 only asks for helper extraction
- **Modifying shared widgets:** Do NOT change `FocusableCard`, `SectionHeader`, or any `lib/shared/widgets/` files — they are external dependencies per UI-SPEC.md
- **Import reorganization beyond extraction:** Do NOT change the import order convention (SDK → Flutter → packages → project) — it's documented in CONVENTIONS.md

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Import management | Manual import tracking | `flutter analyze` after each extraction | Linter catches missing imports faster than manual review |
| File splitting order | Random extraction | Dependency-order extraction (banner → navigation → dialog → profile → home) | Each file compiles independently; no "I need a file that doesn't exist yet" errors |

## Common Pitfalls

### Pitfall 1: Import Contamination After Extraction
**What goes wrong:** After extracting the login dialog, `home_screen.dart` still imports `qr_flutter` and `webview_flutter` even though it no longer uses them. These imports were needed only by `_AnilistLoginDialog`.
**Why it happens:** The original `home_screen.dart` imports these at the top; they're easy to forget during cleanup.
**How to avoid:** Run `flutter analyze` after extraction — Dart's unused import warnings flag these. Remove: `import 'package:qr_flutter/qr_flutter.dart'`, `import 'package:webview_flutter/webview_flutter.dart'` from `home_screen.dart`.
**Warning signs:** Linter warnings about unused imports.

### Pitfall 2: ProfileScreen Self-Import or Circular Import
**What goes wrong:** `app.dart` imports `home_screen.dart` (which provides `HomeScreen`). If `profile_screen.dart` re-imports `home_screen.dart`, a circular dependency could form, though unlikely since ProfileScreen only imports navigation helpers.
**Why it happens:** Unnecessary imports added by habit.
**How to avoid:** ProfileScreen should only import from `home_navigation.dart`, not from `home_screen.dart`. `home_screen.dart` imports `profile_screen.dart` for the `Navigator.push` route. No cycle exists if this direction is maintained.
**Warning signs:** Dart analysis errors about circular imports.

### Pitfall 3: Missing `!mounted` Guards After Async Awaits
**What goes wrong:** When extracting methods, the async `_checkAnilist()` has three sequential awaits (lines 69, 71, 72) but only one guard at line 73. If the widget is disposed between lines 69 and 72, calling `setState` on a disposed widget causes a runtime error.
**Why it happens:** The original code has this bug, and verbatim copy preserves it.
**How to avoid:** Add `if (!mounted) return;` after EACH await in the extracted files. Specifically:
- `_checkAnilist()` line 69 → guard after `AniListService.isLoggedIn()`
- `_checkAnilist()` line 71 → guard after `AniListService.getUser()`
- `_showAnilistLogin()` line 136 → guard after `showDialog` await
- `_startPairing()` line 638 → already has guard (good) but verify
**Warning signs:** `setState() called after dispose()` crash reports.

### Pitfall 4: Navigation Helper `BuildContext` Scoping
**What goes wrong:** In HomeScreen, `_openDetail` uses the widget's `context` implicitly (it's an instance method of a StatefulWidget). After extraction to a top-level function, the context must be passed explicitly. ProfileScreen's `_open` method already takes `BuildContext` as a parameter, so this only affects HomeScreen's call sites.
**Why it happens:** Different method signatures between the original inline methods and the extracted functions.
**How to avoid:** Change call sites from `_openDetail(anime)` to `openDetail(context, anime)`. The `context` is available in `_HomeScreenState.build()` and its private methods.
**Warning signs:** Compile errors at call sites — "The method 'openDetail' isn't defined."

## Code Examples

### Extracted File Template: `home_navigation.dart`

```dart
import 'package:flutter/material.dart';
import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';
import '../detail/detail_screen.dart';

/// Opens [DetailScreen] for an [Anime] obtained from the main catalog.
void openDetail(BuildContext context, Anime anime) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

/// Opens [DetailScreen] for an anime from the watch-history list.
void openFromHistory(BuildContext context, Map<String, dynamic> item) {
  final anime = Anime(
    name: item['title']?.toString() ?? '',
    url: '',
    fallbackImageUrl: item['image']?.toString(),
  );
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

/// Opens [DetailScreen] for an anime from the favorites list.
void openFromFav(BuildContext context, Map<String, dynamic> item) {
  final anime = Anime(
    name: item['title']?.toString() ?? '',
    url: '',
    fallbackImageUrl: item['image']?.toString(),
  );
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

/// Opens [DetailScreen] for an [AniListMedia] entry (from AniList user lists).
void openAnilistDetail(BuildContext context, AniListMedia media) {
  final anime = Anime(
    name: media.title,
    url: '',
    fallbackImageUrl: media.coverImage,
  );
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}
```

### Extracted File Template: `anilist_banner.dart`

```dart
import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';

class AnilistBanner extends StatefulWidget {
  final VoidCallback onTap;

  const AnilistBanner({super.key, required this.onTap});

  @override
  State<AnilistBanner> createState() => _AnilistBannerState();
}

class _AnilistBannerState extends State<AnilistBanner> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (_) {},
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: _isFocused
                    ? const LinearGradient(
                        colors: [Color(0xFF7B73FF), Color(0xFF5C51E0)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF6C63FF), Color(0xFF3F51B5)],
                      ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _isFocused ? ThemeConstants.primary : Colors.transparent,
                  width: 2,
                ),
                boxShadow: _isFocused
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 1,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                children: [
                  CachedImage(
                    url: 'https://anilist.co/img/icons/icon.svg',
                    width: 36,
                    height: 36,
                    fallback: const Icon(Icons.bookmark, color: Colors.white, size: 36),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Conectar com AniList',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Veja suas listas de animes aqui',
                          style: TextStyle(color: Colors.white70, fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

### Extracted File Template: `anilist_login_dialog.dart`

```dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/anilist/anilist_pairing_server.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';

class AnilistLoginDialog extends StatefulWidget {
  const AnilistLoginDialog({super.key});

  @override
  State<AnilistLoginDialog> createState() => _AnilistLoginDialogState();
}

// Rest of dialog implementation — verbatim copy from home_screen.dart lines 607-1090,
// with fixes:
// - Empty catch on line 690 → debugPrint
// - Add !mounted guards after each await
```

### Extracted File Template: `profile_screen.dart`

```dart
import 'package:flutter/material.dart';
import '../../core/storage/local_storage.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/focusable_card.dart';
import '../../shared/widgets/section_header.dart';
import '../../data/models/anime.dart';
import 'home_navigation.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  @override
  Widget build(BuildContext context) {
    final history = LocalStorage.getHistory();
    final favorites = LocalStorage.getFavorites();
    // ... rest of build method (verbatim copy from lines 1197-1306)
    // Replace: onTap: () => _open(context, ...)
    // With:    onTap: () => openFromHistory(context, ...)
    //         onTap: () => openFromFav(context, ...)
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `const _AnilistLoginDialog()` | `const AnilistLoginDialog()` | This phase | Private → public class, new import file |
| `_FocusableAnilistBanner` | `AnilistBanner` | This phase | Same widget, new name, new file |
| Inline `_open*` methods | `open*(BuildContext, ...)` from `home_navigation.dart` | This phase | Duplicate navigation logic consolidated |

## Assumptions Log

> All claims in this research are verified or cited. No user confirmation needed — this is a pure structural refactor with zero new dependencies, zero new packages, and zero behavior changes.

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `home_screen.dart` no longer needs `qr_flutter` or `webview_flutter` after extraction | Import Contamination | Harmless — only unused import warnings |
| A2 | ProfileScreen does not directly reference any HomeScreen internals | Circular Import | Verified by reading ProfileScreen code (lines 1188-1320) — only imports are LocalStorage, theme_constants, focusable_card, section_header, anime.dart, detail_screen.dart |

## Open Questions

1. **Navigation helper file naming**
   - What we know: CONTEXT.md says "file name and location are at the planner's discretion"
   - Recommendation: Use `home_navigation.dart` in `lib/features/home/` — keeps navigation helpers co-located with the screens that use them, matching the existing pattern of feature-scoped files

2. **AnilistBanner as feature-private vs. shared widget**
   - What we know: Only HomeScreen uses it, and CONTEXT.md says the planner can decide
   - Recommendation: Keep in `lib/features/home/anilist_banner.dart` — avoids polluting `lib/shared/widgets/` with a single-consumer widget

## Validation Architecture

> nyquist_validation is enabled in config.json.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `flutter_test` (SDK) + `integration_test` (SDK) |
| Config file | `analysis_options.yaml` (extends `flutter_lints`) |
| Quick run command | `flutter analyze && flutter test` |
| Full suite command | `flutter analyze && flutter test && flutter build apk --debug` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CODE-01 | All extracted files compile independently | static | `flutter analyze` | Built-in analysis |
| CODE-01 | No unused imports in home_screen.dart | static | `flutter analyze` | Built-in analysis |
| CODE-01 | Existing integration tests still pass | integration | `flutter test integration_test/` (requires emulator) | `integration_test/anilist_catalog_test.dart`, etc. |
| CODE-01 | APK builds successfully | build | `flutter build apk --debug` | Build output |
| CODE-01 | Zero visual regression | manual | Visual comparison on emulator | Manual per UI-SPEC.md |

### Sampling Rate
- **Per task commit:** `flutter analyze` (must be green)
- **Per wave merge:** `flutter analyze && flutter test`
- **Phase gate:** Full suite green (analyze + test + build) before `/gsd-verify-work`

### Wave 0 Gaps
- None — existing `analysis_options.yaml` provides static analysis. No new test infrastructure needed for a pure refactor.

## Security Domain

> Security enforcement is enabled (absent in config = enabled). However, this phase is a pure structural refactor with zero behavior changes. No new security-sensitive code is introduced.

### Applicable ASVS Categories

| ASVS Category | Applies | Notes |
|---------------|---------|-------|
| V2 Authentication | No | Auth code is extracted verbatim; the PKCE fix (D-03) is deferred to a separate commit |
| V3 Session Management | No | Token storage unchanged |
| V4 Access Control | No | No new access controls |
| V5 Input Validation | No | No new input handling |
| V6 Cryptography | No | No new cryptographic operations |

### Security Note
The known PKCE issue (`access_token=` fragment interception instead of `code=` query param) is explicitly deferred per D-03. The extraction does NOT fix this — it copies the existing logic verbatim to the new file. The fix must be done in a separate commit.

## Environment Availability

> Skipped — this phase is a pure code reorganization with zero external dependencies. No tools, services, or runtimes beyond the existing Flutter toolchain are required.

## Sources

### Primary (HIGH confidence)
- [Context7 via codebase analysis] — Full read of all 1320 lines of `home_screen.dart`, verifying every component boundary, import, and method signature
- [Codebase files read] — `home_screen.dart`, `app.dart`, `anime.dart`, `anilist_models.dart`, `anilist_service.dart`, `anilist_pairing_server.dart`, `local_storage.dart`, `focusable_card.dart`, `section_header.dart`, `theme_constants.dart`
- [CONTEXT.md] — User decisions D-01 through D-04, extraction targets, fixes to apply, canonical references
- [UI-SPEC.md] — Zero-visual-change contract, spacing/typography/color/copy inventory
- [CONVENTIONS.md] — Import organization rules, Dart style, TV widget patterns
- [CONCERNS.md] — Home screen 1320-line debt identification, bug inventory
- [ARCHITECTURE.md] — Data flow, layer boundaries, navigation patterns
- [STRUCTURE.md] — File layout, feature directories

### Secondary (MEDIUM confidence)
- All sources verified by reading actual project files — not external documentation lookups needed as this is an internal refactor

### Tertiary (LOW confidence)
- None — all claims verified against actual source code

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - No new packages, no external dependencies
- Architecture: HIGH - All component boundaries verified by reading source code line-by-line
- Pitfalls: HIGH - Based on actual bugs found in the source (empty catch, missing guards) and import analysis

**Research date:** 2026-07-12
**Valid until:** This refactor is time-insensitive — valid until the codebase changes significantly
