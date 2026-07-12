---
phase: 2
slug: home-screen-refactor
status: draft
framework: flutter
created: 2026-07-12
---

# Phase 2 — UI Design Contract

> **⚠️ ZERO-VISUAL-CHANGE PHASE.** This phase is a pure structural refactor that extracts code from a 1320-line monolithic file into separate component files. **All visual design, spacing, typography, colors, interactions, copywriting, and component behavior must remain identical to the current implementation.** This contract documents existing state that must be preserved.

---

## Design System

| Property | Value |
|----------|-------|
| Framework | Flutter (Material 3) |
| Theme engine | `ThemeData` + custom `ThemeConstants` class |
| Component library | In-house Flutter widgets in `lib/shared/widgets/` |
| Icon library | Flutter `Icons.*` (Material Icons) |
| Font | System default (Roboto on Android TV) |
| State management | `StatefulWidget` + `setState` (no state library) |
| Navigation | `Navigator.push(MaterialPageRoute(...))` |

---

## Spacing Scale

**Contract: PRESERVE ALL EXISTING SPACING VALUES.** Spacing is not tokenized; all values are inline `EdgeInsets` doubles. The project uses a de facto multiples-of-2 scale extracted from the codebase. No changes allowed.

| Token (if extracted) | Value | Usage Context |
|-|-|-|
| xs | 4px | Icon-to-text gaps, avatar-to-name gaps |
| sm | 8px | Compact element spacing, container padding edges |
| md | 12px | SectionHeader padding, spacing between buttons |
| lg | 16px | Default padding (top bar, dialog content), card spacing |
| xl | 20px | Anilist banner inner padding, spacing in dialogs |
| 2xl | 24px | Screen outer padding (horizontal: `EdgeInsets.symmetric(horizontal: 24)`) |
| 3xl | 32px | Bottom section spacing, top bar top padding + status bar |
| 4xl | 40px | Dialog inset padding (vertical) |
| 5xl | 48px | Bottom of ListView spacing |

**Exceptions:** Touch targets on Android TV use focus-based navigation, not pointer targets. The existing focus scale animation (1.08× on `AnimatedScale`) in `FocusableCard` must be preserved.

---

## Typography

**Contract: PRESERVE ALL EXISTING TEXT STYLES.** Defined in `AppTheme.darkTheme.textTheme` (Material TextTheme) with overrides in individual widgets. No changes allowed.

### Material TextTheme (Global)

| Role | Size | Weight | Color | Line Height |
|------|------|--------|-------|-------------|
| `headlineLarge` | 32px | bold (700) | `Colors.white` | system (default) |
| `headlineMedium` | 24px | bold (700) | `Colors.white` | system |
| `titleLarge` | 20px | w600 (semibold) | `Colors.white` | system |
| `titleMedium` | 18px | w600 (semibold) | `Colors.white` | system |
| `bodyLarge` | 16px | regular (400) | `Colors.white` | system |
| `bodyMedium` | 14px | regular (400) | `#AAAAAA` (textSecondary) | system |
| `labelLarge` | 16px | w500 (medium) | `Colors.white` | system |

### Inline Overrides (must preserve)

These text styles are defined inline in widget `TextStyle` constructors and must survive extraction unchanged:

| Widget / Context | Size | Weight | Color | Notes |
|-|-|-|-|-|
| App title "GoAnime TV" | 22px | bold | `Colors.white` | `_buildTopBar` |
| Anilist banner title "Conectar com AniList" | 20px | bold | `Colors.white` | `_FocusableAnilistBanner` |
| Anilist banner subtitle "Veja suas listas..." | 15px | regular | `Colors.white70` | `_FocusableAnilistBanner` |
| SectionHeader title | 18px | bold | `Colors.white` | `SectionHeader` widget |
| SectionHeader "Ver Todos" | 14px | w600 | `ThemeConstants.primary` | `SectionHeader` widget |
| Nav item labels ("Buscar", "Perfil", "AniList") | 14px | regular | `Colors.white` | `_buildTopBar` |
| Nav item icons | 28px | — | `Colors.white` | `_buildTopBar` |
| Dialog title "Conectar AniList" | 24px | bold | `Colors.white` | Login dialog |
| Dialog body text | 16px | regular | `Colors.white70` | Login dialog |
| Dialog secondary text | 14px | regular | `Colors.white70` | Login dialog |
| Token input hint | 16px | regular | `#AAAAAA` (50% alpha) | Login dialog |
| Token input text | 16px | regular | `Colors.white` | Login dialog |
| "Cancelar" button | 18px | regular | `ThemeConstants.textSecondary` | Login dialog |
| "Conectar" button | 18px | w600 | `Colors.white` | Login dialog |
| "Usar celular" link | 16px | regular | `ThemeConstants.primary` | Login dialog |
| Profile screen title "Meu Perfil" | 28px | bold | `Colors.white` | `ProfileScreen` |
| Empty state "Nenhum anime assistido ainda" | 18px | regular | `ThemeConstants.textSecondary` | `ProfileScreen` |
| Empty state "Nenhum favorito adicionado" | 18px | regular | `ThemeConstants.textSecondary` | `ProfileScreen` |
| Anilist user name (header) | 20px | bold | `Colors.white` | `_buildContent` |
| Anilist list count subtitle | 14px | regular | `ThemeConstants.textSecondary` | `_buildContent` |
| Error text | 14px | regular | `Colors.red` | Login dialog |
| Anilist menu items | 18px | regular | `Colors.white` / `Colors.red` | `_showAnilistMenu` |

---

## Color

**Contract: PRESERVE ALL EXISTING COLORS.** Defined in `lib/core/constants/theme_constants.dart` and used throughout. No changes allowed.

### Color Tokens (from `ThemeConstants`)

| Token | Hex | Role | Usage |
|-------|-----|------|-------|
| `background` | `#0A0A0F` | Scaffold background (dominant surface) | All screen backgrounds |
| `surface` | `#1A1A2E` | Card/surface/dialog background (secondary) | Dialog background, Anilist menu background |
| `surfaceLight` | `#252540` | Lighter surface variant | Used in widget decorations |
| `primary` | `#00E5FF` | Accent (accent) | Play button, SectionHeader accent bar, focus borders, TVButton primary, circular progress, link text, QR border |
| `primaryLight` | `#66F5FF` | Hover/glow variant | Used in gradient decorations |
| `primaryDark` | `#00B8CC` | Pressed variant | Used in gradient decorations |
| `accent` | `#FF6B6B` | Secondary accent | Destructive actions only (logout icon/text in Anilist menu) |
| `white` | `#FFFFFF` | Primary text | All headings, labels, body text |
| `textSecondary` | `#AAAAAA` | Secondary/muted text | Subtitles, metadata, empty states, cancel buttons |
| `textMuted` | `#777777` | Muted text | Low-priority information |

### Color Distribution (60/30/10)

- **Dominant (60%)**: `#0A0A0F` (background) — all scaffold bodies
- **Secondary (30%)**: `#1A1A2E` (surface) — dialogs, menus, card backgrounds
- **Accent (10%)**: `#00E5FF` (primary) — reserved EXCLUSIVELY for:
  - Play floating action button
  - SectionHeader accent bar (3px left border)
  - "Ver Todos" link text
  - Focus indicator borders on cards/banners
  - TVButton primary background
  - Circular progress indicator
  - Login dialog "Usar celular" text
  - QR code container border
  - Anilist banner focus glow (`withValues(alpha: 0.4)`)
- **Destructive**: `#FF6B6B` (accent color) — reserved EXCLUSIVELY for:
  - "Desconectar" text and icon in Anilist menu dialog

### Gradient (must preserve)

The `_FocusableAnilistBanner` widget uses a specific gradient:
- Unfocused: `[#6C63FF, #3F51B5]` (LinearGradient, left-to-right implied)
- Focused: `[#7B73FF, #5C51E0]`

---

## Copywriting Contract

**Contract: PRESERVE ALL EXISTING COPY.** All text is in Brazilian Portuguese. No changes allowed. Below is the complete inventory of copy that must survive extraction.

| Element | Copy (PT-BR) | Location |
|---------|--------------|----------|
| App title | GoAnime TV | `_buildTopBar` |
| Nav: search | Buscar | `_buildTopBar` |
| Nav: profile | Perfil | `_buildTopBar` |
| Nav: anilist login | AniList | `_buildTopBar` |
| Anilist banner title | Conectar com AniList | `_FocusableAnilistBanner` |
| Anilist banner subtitle | Veja suas listas de animes aqui | `_FocusableAnilistBanner` |
| Section: trending | Em Alta | `_buildContent` |
| Section: seasonal | Populares da Temporada | `_buildContent` |
| Section: history | Continuar Assistindo | `_buildContent` |
| Section: favorites | Favoritos | `_buildContent` |
| Section: AniList group | AniList: {group.name} | `_buildAnilistGroup` |
| Section: see all | Ver Todos | `SectionHeader` |
| Profile title | Meu Perfil | `ProfileScreen` |
| Profile section: history | Assistidos | `ProfileScreen` |
| Profile section: favorites | Favoritos | `ProfileScreen` |
| Empty state: history | Nenhum anime assistido ainda | `ProfileScreen` |
| Empty state: favorites | Nenhum favorito adicionado | `ProfileScreen` |
| Dialog title | Conectar AniList | `_AnilistLoginDialog` |
| Dialog body: webview | Faça login no AniList usando o controle remoto | Login dialog |
| Dialog body: webview sub | Depois de autorizar, o login será feito automaticamente | Login dialog |
| Dialog: phone option | Usar celular | Login dialog |
| Dialog: cancel | Cancelar | Login dialog |
| Dialog: connect | Conectar | Login dialog |
| Dialog: token hint | Token (começa com eyJ...) | Login dialog |
| Dialog: pairing step 1 | 1. Escaneie o QR code com a câmera do celular | Login dialog (pairing) |
| Dialog: pairing step 2 | 2. Toque em "Entrar com AniList" e autorize | Login dialog (pairing) |
| Dialog: pairing step 3 | 3. O login na TV acontece sozinho — sem digitar nada | Login dialog (pairing) |
| Dialog: pairing waiting | Aguardando login no celular... | Login dialog (pairing) |
| Dialog: pairing preparing | Preparando pareamento... | Login dialog (pairing) |
| Dialog: QR fallback | Escaneie o QR, autorize e cole o token abaixo: | Login dialog (no LAN) |
| Dialog: refresh lists | Atualizar listas | Anilist menu |
| Dialog: disconnect | Desconectar | Anilist menu |
| Error: invalid token | Token inválido. Tente novamente. | Login dialog |
| Error: empty token | Insira o token do AniList | Login dialog |
| Error: bad token prefix | Token inválido. Deve começar com "eyJ..." | Login dialog |
| Error: expired token | Token inválido ou expirado. Tente novamente. | Login dialog |

### Empty States

| Screen | State | Copy |
|--------|-------|------|
| ProfileScreen | No history | "Nenhum anime assistido ainda" (centered, textSecondary, 18px) |
| ProfileScreen | No favorites | "Nenhum favorito adicionado" (centered, textSecondary, 18px) |

### Error States

| Screen | State | Copy |
|--------|-------|------|
| Login dialog | Token save failed | "Token inválido. Tente novamente." (red, 14px) |
| Login dialog | Empty token submission | "Insira o token do AniList" (red, 14px) |
| Login dialog | Bad token format (missing `eyJ` prefix) | `Token inválido. Deve começar com "eyJ..."` (red, 14px) |
| Login dialog | Token expired | "Token inválido ou expirado. Tente novamente." (red, 14px) |

### Destructive Actions

| Action | Confirmation | UI |
|--------|-------------|----|
| AniList logout ("Desconectar") | No confirmation dialog — immediate execution | Row with `Icons.logout` + "Desconectar" text, both colored `#FF6B6B` |

---

## Component Inventory (Extraction Targets)

These widgets currently live in `home_screen.dart` and will be extracted to separate files. Their **visual and interaction contracts must be preserved exactly**:

### 1. HomeScreen (→ `lib/features/home/home_screen.dart`)
- **Type:** `StatefulWidget` with `_HomeScreenState`
- **Layout:** `Scaffold` + `Stack` (Column body + Positioned play button)
- **Children:** `_buildTopBar` (nav row), `_buildContent` (ListView with sections)
- **Data loading:** `_loadDataWithTimeout` (12s timeout, `Future.wait` on `_loadAnimeLists` + `_checkAnilist`)
- **Sections in order:** Anilist banner/greeting → Anilist list groups → "Em Alta" (horizontal banner scroll) → "Populares da Temporada" (horizontal card scroll) → "Continuar Assistindo" (history) → "Favoritos" (favorites)
- **States:** Loading (centered `CircularProgressIndicator`), loaded, error (silent — shows whatever loaded before timeout)
- **Navigation actions:** `_openDetail`, `_openFromHistory`, `_openFromFav`, `_openAnilistDetail`, `_searchAnime`, `_showAnilistLogin`, `_showAnilistMenu`

### 2. AnilistLoginDialog (→ `lib/features/home/anilist_login_dialog.dart`)
- **Type:** `StatefulWidget` present state (currently `_AnilistLoginDialog`)
- **Layout:** `Dialog` → `Padding` → `Column` with WebView or manual token entry
- **Three sub-states:**
  - WebView login (default): `WebViewWidget` loading AniList auth URL + inline navigation bar
  - Phone pairing: QR code (`QrImageView`) from `AniListPairingServer.pairUrl` + progress indicator + URL display
  - Manual token paste: QR of auth URL + `TextField` for token + "Conectar" button
- **Token interception pattern:** `access_token=` fragment from WebView URL (RegExp) → `AniListService.saveToken()` — this will be updated to `code=` in a separate PKCE commit (see D-03 in CONTEXT.md)
- **Return:** `Navigator.pop(context, true)` on success, `false` on cancel

### 3. ProfileScreen (→ `lib/features/home/profile_screen.dart`)
- **Type:** `StatefulWidget` with `_ProfileScreenState`
- **Layout:** `Scaffold` → `Column` (top bar with back arrow + "Meu Perfil" title + ListView with "Assistidos" and "Favoritos" sections)
- **Data source:** `LocalStorage.getHistory()`, `LocalStorage.getFavorites()` (reads synchronously)
- **States:** Happy path (horizontal card rows), empty (centered text per section)
- **Navigation:** Back arrow `Navigator.pop(context)`, card tap opens `DetailScreen`

### 4. AnilistBanner (→ `lib/features/home/anilist_banner.dart`)
- **Type:** `StatefulWidget` with focus state (currently `_FocusableAnilistBanner`)
- **Layout:** `Focus` → `Semantics` → `Material` → `InkWell` → `AnimatedContainer` with gradient
- **Focus interaction:** `onFocusChange` toggles `_isFocused`, drives gradient shift, border color, box shadow
- **Dimensions:** `padding: EdgeInsets.all(20)`, rounded corners 14px, border width 2px on focus
- **Visual contract:** Unfocused `[#6C63FF → #3F51B5]`, Focused `[#7B73FF → #5C51E0]` + primary border + primary glow shadow

### 5. HomeNavigation (→ `lib/features/home/home_navigation.dart`)
- **Type:** Static helper functions or extension methods (exact form at planner's discretion)
- **Methods to extract:** `_openDetail`, `_openFromHistory`, `_openFromFav`, `_openAnilistDetail` — these are identical in `HomeScreen` and `ProfileScreen`
- **Must preserve:** Method signatures identical (`Anime` → `DetailScreen` navigation)

---

## Existing Shared Widgets (External Dependencies)

These are already in `lib/shared/widgets/` and used by the home screen. They must NOT be modified:

| Widget | File | Used By |
|--------|------|---------|
| `FocusableCard` | `focusable_card.dart` | All card rows (trending, seasonal, history, favorites, AniList groups) |
| `FocusableBannerCard` | `focusable_card.dart` | "Em Alta" trending banners |
| `SectionHeader` | `section_header.dart` | All section titles |
| `CachedImage` | `cached_image.dart` | Banner, card images, dialog icons |
| `PlayIcon` | `play_icon.dart` | FAB play button |

---

## Interaction Contract

**Contract: PRESERVE ALL EXISTING INTERACTION PATTERNS.** No new interactions. No changes to existing interactions.

| Interaction | Pattern | Existing Behavior |
|-------------|---------|-------------------|
| Card focus | `Focus` + `onFocusChange` + `AnimatedScale(1.08×)` | FocusableCard / FocusableBannerCard |
| Button press | `InkWell` + `onTap` with `Semantics(button: true)` | TVButton, nav items, all interactive elements |
| Navigation | `Navigator.push(MaterialPageRoute(...))` | Home → Search, Home → Detail, Home → Profile |
| Dialog open | `showDialog` builder pattern | Anilist login dialog, Anilist menu |
| Dialog close | `Navigator.pop(context, result)` | Post-login, cancel, menu selection |
| Data loading | `setState(() => _isLoading = true/false)` with `CircularProgressIndicator` | Full-screen centered spinner |
| Error handling | Empty `catch` (to be fixed to debugPrint) | Silent fail, whatever loaded before timeout stays |
| Mount guard | `if (!mounted) return;` after each `await` | Must be added where missing (fix during extraction) |
| Const constructors | `const` on all StatelessWidgets | Must be added where missing (fix during extraction) |

### No New Interactions Introduced

- No new buttons, gestures, or input methods
- No new navigation flows
- No new dialog patterns
- No new animations or transitions

---

## Registry Safety

| Component | Source | Safety Gate |
|-----------|--------|-------------|
| All widgets | Existing in `lib/` | Not applicable — no external registries used |
| All packages | `pubspec.yaml` (Flutter packages) | Not applicable — no third-party UI registries |

---

## Checker Sign-Off

- [ ] **Dimension 1 Copywriting: PASS** — All PT-BR copy preserved verbatim. No new copy introduced.
- [ ] **Dimension 2 Visuals: PASS** — Zero visual changes. Layouts, gradients, focus animations unchanged.
- [ ] **Dimension 3 Color: PASS** — All `ThemeConstants` colors preserved. No new color values.
- [ ] **Dimension 4 Typography: PASS** — All TextTheme + inline styles preserved. No new font sizes/weights.
- [ ] **Dimension 5 Spacing: PASS** — All inline padding values preserved. No spacing scale changes.
- [ ] **Dimension 6 Registry Safety: PASS** — No external registries used. All components are in-house Flutter widgets.

**Approval:** {pending}

---

## Appendix: Diff Reference

### File Structure Before
```
lib/features/home/home_screen.dart  (1320 lines — HomeScreen, _AnilistLoginDialog, _FocusableAnilistBanner, ProfileScreen)
```

### File Structure After (must compile independently, same visual output)
```
lib/features/home/
├── home_screen.dart              # HomeScreen only (~400 lines)
├── anilist_login_dialog.dart     # AnilistLoginDialog
├── profile_screen.dart           # ProfileScreen
├── anilist_banner.dart           # AnilistBanner (formerly _FocusableAnilistBanner)
└── home_navigation.dart          # Shared navigation helpers (_openDetail etc.)
```

### Verifying Zero Visual Regression

To verify no visual changes occurred after extraction:

1. `flutter run` on Android TV emulator
2. Compare each screen side-by-side with screenshots from before refactor
3. Verify focus animations behave identically
4. Verify all navigation paths produce same results
5. Verify all dialog states produce same copy and layout
