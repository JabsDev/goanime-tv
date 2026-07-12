# Phase 01 — UI Review

**Audited:** 2026-07-11
**Baseline:** Abstract 6-pillar standards (no UI-SPEC.md exists)
**Screenshots:** Not captured (Flutter Android TV app — no HTTP dev server)

---

## Pillar Scores

| Pillar | Score | Key Finding |
|--------|-------|-------------|
| 1. Copywriting | 3/4 | PT-BR consistent; raw exception leak in player error path |
| 2. Visuals | 3/4 | Strong focus system and hierarchy; see-all dead code; embedded ProfileScreen |
| 3. Color | 2/4 | Primary cyan overused across 15+ element types; hardcoded non-theme gradients |
| 4. Typography | 1/4 | 12 distinct font sizes, 6 outside declared TextTheme — no type ramp discipline |
| 5. Spacing | 2/4 | No formal spacing scale; inconsistent card gaps (10px vs 12px); arbitrary positions |
| 6. Experience Design | 2/4 | Loading states everywhere; error recovery missing on 3 screens; no Home empty state |

**Overall: 13/24**

---

## Top 3 Priority Fixes

1. **Typography chaos (BLOCKER)** — 12 distinct font sizes (32, 28, 24, 22, 20, 18, 16, 15, 14, 13, 12, 11) with 6 sizes outside the declared TextTheme — Consolidate to max 5 sizes, enforce via TextTheme exclusively, remove all inline `fontSize` overrides.

2. **Primary color overuse (BLOCKER)** — `ThemeConstants.primary` (#00E5FF cyan) referenced 55 times across 15+ element types — Reserve primary for focus indicators and key CTAs only; use `textSecondary`/`textMuted`/white for secondary elements.

3. **Silent error swallowing on 3 screens (WARNING)** — Home, Search, and Detail screens catch errors with no retry UI — Add error state with retry button to each.

---

## Detailed Findings

### Pillar 1: Copywriting (3/4)

**Strengths:**
- All UI strings are in PT-BR — no English leakage. CTA labels like "Em Alta", "Populares da Temporada", "Continuar Assistindo", "Favoritos" are culturally appropriate for the Brazilian audience.
- Empty states are well-worded: "Nenhum anime assistido ainda" (profile), "Nenhum favorito adicionado" (profile), "Nenhum episódio encontrado" (detail), "Use o teclado para buscar animes" (search initial).
- Error messages are mostly user-friendly: "Não foi possível carregar o vídeo. Tente outra fonte.", "Token inválido. Tente novamente.", "O servidor não está respondendo. Tente novamente.".

**Issues:**

| Severity | File:Line | Finding |
|----------|-----------|---------|
| WARNING | `player_screen.dart:153` | Raw exception exposed to user: `_error = 'Erro ao reproduzir: $e'` — the `$e` interpolation leaks internal error details. Should use a static message. |
| INFO | `detail_screen.dart:628` | Error dialog shows `'Erro ao carregar: $e'` — same raw exception exposure pattern. |
| INFO | `player_screen.dart:201` | "Erro de reprodução: Verifique o vídeo." — slightly vague; could suggest specific actions. |

**Recommendations:**
1. Replace `$e` interpolation in `player_screen.dart:153` and `detail_screen.dart:628` with static, user-friendly messages.
2. Consider adding a copywriting contract file to maintain consistent tone across future phases.

---

### Pillar 2: Visuals (3/4)

**Strengths:**
- Strong dark-theme consistency: scaffold background `#0A0A0F`, surfaces `#1A1A2E`, layered with `#252540` for depth.
- TV remote focus system thoroughly implemented: every interactive widget wraps `Focus` + `InkWell` with animated scale (1.05x-1.08x), animated border (cyan glow), and animated box shadow.
- Clear visual hierarchy: large banner cards (260-320px) -> poster cards (130-150px) -> compact episode cards.
- Section headers differentiated by accent bar on the left — good scannability.
- SliverAppBar with parallax on detail screen creates premium feel.
- Video player overlay uses gradient (black -> transparent -> black) for legible controls.
- Auto-next overlay and FAB with cyan glow effect are polished.

**Issues:**

| Severity | File:Line | Finding |
|----------|-----------|---------|
| WARNING | `section_header.dart:8` | `onSeeAll` parameter is defined but **never wired** on any screen — dead code. All 6 `SectionHeader` usages in `home_screen.dart` pass no `onSeeAll`. Missing interaction pattern. |
| WARNING | `home_screen.dart:1188-1320` | `ProfileScreen` class defined inline inside `home_screen.dart` — 1320-line file with two screens mixed together violates separation of concerns. |
| INFO | `home_screen.dart:335-336` | FAB positioned at `bottom: 100, right: 24` — arbitrary pixel values with no responsive consideration for different TV resolutions. |
| INFO | `focusable_card.dart` | No visual distinction between watched and unwatched episodes. TV apps typically show a progress indicator or checkmark. |
| INFO | `player_screen.dart:448` | Play/pause button icon size is static 72px — should scale with screen. |

**Recommendations:**
1. Wire `onSeeAll` callbacks to proper navigation (e.g., full list screens) or remove the parameter.
2. Extract `ProfileScreen` into its own file (`lib/features/profile/profile_screen.dart`).
3. Add watched-progress indicators to episode cards and history items.

---

### Pillar 3: Color (2/4)

**Strengths:**
- Dark theme palette is cohesive: deep backgrounds (`#0A0A0F`, `#1A1A2E`, `#252540`) with cyan primary (`#00E5FF`) and coral accent (`#FF6B6B`).
- Color tokens centralized in `ThemeConstants` (10 constants) — good foundation.

**Issues:**

| Severity | File:Line | Finding |
|----------|-----------|---------|
| BLOCKER | Throughout | **Primary cyan overused**: 55 references to `ThemeConstants.primary` across the codebase. Used on: top bar icon, search icon, section header bars, focus borders (2 card types), focus shadows (4 components), FAB background, loading spinners (5+ instances), progress bar, source selector, genre chips (background + text), source badges, quality dialog highlights, next overlay action button, player quality button, etc. — 15+ distinct element types. The 10% accent rule is violated. |
| WARNING | `home_screen.dart:1119-1125` | **Hardcoded gradient colors**: `Color(0xFF6C63FF)`, `Color(0xFF3F51B5)`, `Color(0xFF7B73FF)`, `Color(0xFF5C51E0)` — purple/indigo gradient in AniList banner does not match any theme constant. |
| WARNING | `main.dart:19` | Hardcoded `Color(0xFF0A0A0F)` instead of `ThemeConstants.background`. |
| WARNING | `detail_screen.dart:263-264` | **Accent (#FF6B6B) underused**: only 1 reference (favorite toggle). The coral accent was designed as the secondary brand color but barely appears. |

**Color distribution analysis (60/30/10):**
- 60% background: `#0A0A0F` — dominant, correct
- 30% surfaces: `#1A1A2E`, `#252540` — well implemented
- 10% accent: `#00E5FF` — used on 15+ element types, overused
- Secondary accent: `#FF6B6B` — used 1x, underused

**Recommendations:**
1. Audit each `ThemeConstants.primary` reference and replace decorative/non-interactive uses with `textSecondary`, `textMuted`, or surface variants.
2. Replace hardcoded AniList banner gradient colors with theme-consistent values.
3. Use accent (`#FF6B6B`) for at least 2-3 more purposes (e.g., active tab indicator, continue-watching badge).
4. Fix `main.dart:19` to use `ThemeConstants.background`.

---

### Pillar 4: Typography (1/4)

**Strengths:**
- `AppTheme` defines a `TextTheme` with 7 size/weight variants (32px bold -> 14px regular).

**Issues:**

| Severity | File:Line | Finding |
|----------|-----------|---------|
| BLOCKER | Throughout | **12 distinct font sizes in actual use**: 32, 28, 24, 22, 20, 18, 16, 15, 14, 13, 12, 11. Abstract standards suggest <=4. Six of these (28, 22, 15, 13, 12, 11) are **not declared in TextTheme** — all hardcoded inline. |
| BLOCKER | Throughout | **No TextTheme enforcement**: Components use inline `TextStyle(fontSize:)` instead of `Theme.of(context).textTheme.headlineMedium` etc. Global typography changes impossible without editing every file. |
| WARNING | `detail_screen.dart:278` | Font size 11px for status text — too small for TV viewing at typical distances (10ft UI guideline: minimum 14px for secondary text). |
| WARNING | `focusable_card.dart:99` | Card title at font size 12px — also below TV readability minimums. |
| INFO | `app_theme.dart` | No `fontFamily` specified — uses platform default. A branded TV app would benefit from a dedicated font family. |

**Font size distribution:**

| Size | In TextTheme? | Usage Locations |
|------|---------------|-----------------|
| 32 | Yes | headlineLarge — used correctly |
| 28 | **No** | `search_screen.dart:83`, `home_screen.dart:1227` |
| 24 | Yes | headlineMedium — dialog titles |
| 22 | **No** | `home_screen.dart:184`, `search_screen.dart:118` |
| 20 | Yes | titleLarge — detail description |
| 18 | Yes | titleMedium — 12+ locations |
| 16 | Yes | bodyLarge/labelLarge — used widely |
| 15 | **No** | `detail_screen.dart:333`, `home_screen.dart:1170` |
| 14 | Yes | bodyMedium — secondary text |
| 13 | **No** | `detail_screen.dart:359` (genre chips) |
| 12 | **No** | `detail_screen.dart:230`, `focusable_card.dart:99`, `home_screen.dart:957` |
| 11 | **No** | `detail_screen.dart:278` (status text) |

**Font weights:** 4 weights used: `bold`, `w600`, `w500`, regular — acceptable.

**Recommendations:**
1. **Critical**: Define a strict type ramp of <=5 sizes and refactor every inline `TextStyle(fontSize:)` to use `Theme.of(context).textTheme.*`.
2. Remove font sizes 28, 22, 15, 13, 12, 11 — map to nearest theme token.
3. Set minimum font size to 14px for TV 10ft UI compliance.
4. Add a `fontFamily` to the theme.

---

### Pillar 5: Spacing (2/4)

**Strengths:**
- Horizontal margin of 24px is used consistently across all screens (home, search, detail, profile).
- Vertical rhythm of 8/12/16px for padding between elements is generally maintained.

**Issues:**

| Severity | File:Line | Finding |
|----------|-----------|---------|
| WARNING | — | **No formal spacing scale defined**. No `SpacingConstants` class or tokens. Values are scattered as magic numbers. |
| WARNING | `home_screen.dart:438` vs `home_screen.dart:459,482,506,540` | **Inconsistent card gaps**: Banner cards use `right: 12` but poster cards use `right: 10`. Same purpose — should be identical. |
| WARNING | `home_screen.dart:335`, `player_screen.dart:555` | **Arbitrary positioning**: FAB at `bottom: 100`, next overlay at `bottom: 80` — not on any recognizable scale, may break on different TV resolutions. |
| INFO | Throughout | 10 unique spacing values in use: 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, plus outliers 80 and 100. With a defined scale this could be reduced to 5-6 values. |
| INFO | `home_screen.dart:756` | Dialog `insetPadding` uses 40px horizontal — unique pattern not used elsewhere. |

**Recommendations:**
1. Create a `SpacingConstants` class with 6 values (e.g., xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 48).
2. Standardize card spacing to a single value (recommend `right: 12` for all horizontal lists).
3. Replace FAB `bottom: 100` with a responsive calculation based on safe area and spacing constants.
4. Audit all inline padding values and replace with constants.

---

### Pillar 6: Experience Design (2/4)

**Strengths:**
- **Loading states**: Present on all 5 screens — Home spinner, Search spinner, Detail spinner, Player loading with quality label, SuperFlix overlay.
- **Empty states**: Well-implemented on Search (initial + no results), Detail (no episodes), Profile (no history, no favorites).
- **Player polish**: Progress saving/restoring, auto-next episode with countdown and cancel/skip, source quality switching during playback.
- **Focus system**: `Focus` widget + `InkWell` pattern applied across `FocusableCard`, `FocusableBannerCard`, `TVButton`, `_EpisodeCard`, `_FocusableAnilistBanner` — good TV remote navigation.
- **Error handling**: Player has proper error state with retry button (`_buildErrorState`). SuperFlix resolver handles Cloudflare challenge gracefully with user prompt.

**Issues:**

| Severity | File:Line | Finding |
|----------|-----------|---------|
| BLOCKER | `home_screen.dart:62-65` | **No error recovery on Home**: `_loadDataWithTimeout` catches all errors silently. On failure user sees a blank screen with no feedback or retry option. |
| BLOCKER | `search_screen.dart:40-41` | **No error recovery on Search**: Search errors caught and printed to debug only. User sees empty state with no indication search failed. |
| WARNING | `detail_screen.dart:54-56` | **No error recovery on Detail**: Episode load errors silently swallowed. User sees "Nenhum episódio encontrado" instead of actionable error. |
| WARNING | `home_screen.dart:371-521` | **No empty state on Home**: If all data sources fail (no trending, no season, no history, no favorites), content area is blank. Should show a welcome or retry prompt. |
| WARNING | `tv_button.dart` | **TVButton missing disabled/loading variant**: Button cannot show loading state. Only one location uses manual opacity for disabled state. |
| INFO | `detail_screen.dart:406-434` | **Dropdown source selector has no focus indicator**: TV remote users need visual focus feedback on dropdown interactions. |
| INFO | `home_screen.dart:1188` | **ProfileScreen embedded in home_screen.dart**: Code organization issue affecting maintainability and discoverability. |

**Recommendations:**
1. Add error state with retry button to Home (`_loadDataWithTimeout` catch block), Search (`_performSearch` catch block), and Detail (`_loadEpisodes` catch block).
2. Add a fallback empty state to Home's `_buildContent()` when all sections are empty.
3. Add `isLoading`/`disabled` parameters to `TVButton` with appropriate visual treatment.
4. Add `Focus` wrapping to the dropdown source selector in Detail screen.

---

## Files Audited

| File | Lines | Role |
|------|-------|------|
| `lib/shared/theme/app_theme.dart` | 56 | Theme configuration |
| `lib/core/constants/theme_constants.dart` | 18 | Color and size constants |
| `lib/core/constants/app_constants.dart` | 18 | App-level constants |
| `lib/app.dart` | 17 | App entry point |
| `lib/features/home/home_screen.dart` | 1320 | Home screen + AniList login + ProfileScreen |
| `lib/features/search/search_screen.dart` | 209 | Search screen |
| `lib/features/detail/detail_screen.dart` | 785 | Detail screen with episode grid |
| `lib/features/player/player_screen.dart` | 673 | Video player screen |
| `lib/features/superflix/superflix_web_screen.dart` | 302 | SuperFlix WebView resolver |
| `lib/shared/widgets/focusable_card.dart` | 273 | FocusableCard + FocusableBannerCard |
| `lib/shared/widgets/cached_image.dart` | 54 | Cached network image widget |
| `lib/shared/widgets/section_header.dart` | 63 | Section header with accent bar |
| `lib/shared/widgets/play_icon.dart` | 60 | Custom painted play icon |
| `lib/shared/widgets/tv_button.dart` | 86 | TV remote-friendly button |

