# Integrations: GoAnime TV

**Date:** 2026-07-11
**Last updated:** 2026-07-11

## External APIs

| API | Authentication | Endpoint | Usage |
|-----|---------------|----------|-------|
| **AniList GraphQL** | Bearer token (OAuth implicit grant) | `https://graphql.anilist.co` | Catalog discovery (trending, popular, seasonal), user anime list sync, media enrichment (description, score, genres, status) |
| **AniList OAuth** | OAuth 2.0 implicit grant (`client_id=44217`) | `https://anilist.co/api/v2/oauth/authorize` | User login via WebView or LAN pairing server |
| **SuperFlix** | CSRF tokens extracted from HTML + `X-Page-Token` | `https://superflixapi.best` | PT-BR anime search, episode listing, stream URL resolution (bootstrap → source → redirect → getVideo) |
| **AllAnime GraphQL** | None (referer-based) | `https://api.allanime.day/api` | International anime search, episode listing, stream URL resolution (requires AES-256-CTR decryption of `tobeparsed` blobs) |
| **AnimeFire** | None (HTML scraping) | `https://animefire.io` | PT-BR search, episode listing, multi-quality video extraction (Blogger, Google Video) |
| **Goyabu WordPress REST API** | Nonce token from homepage | `https://goyabu.io/wp-json/animeonline/search` | PT-BR anime search by keyword |
| **Goyabu Blogger Decode** | None | `https://goyabu.io/wp-admin/admin-ajax.php` | Decodes `blogger_token` into playable video URLs with quality options |
| **TMDB Image CDN** | None (indirect) | `https://image.tmdb.org/t/p/` | Poster and banner images proxied through SuperFlix search results |
| **Blogger Video** | None | `https://www.blogger.com/video.g` | Video source fallback for AnimeFire |
| **Google Video CDN** | None | `googlevideo.com`, `googleusercontent.com`, `redirector.googlevideo.com`, `videoplayback` | Direct .mp4/.m3u8 video URLs from Blogger redirects |

## External Services

| Service | Purpose |
|---------|---------|
| **AniList** | OAuth identity provider + GraphQL metadata catalog. Provides trending/popular anime curation, user list sync, and per-title enrichment. |
| **SuperFlix** | PT-BR streaming aggregator. Content is accessed via Cloudflare Turnstile-gated player pages; the Go FFI bridge uses TLS fingerprinting (`utls`) and HTTP/2 to bypass, while a WebView fallback renders the page to pass the challenge. |
| **AllAnime** | International anime streaming platform. Provides a GraphQL API for search/episodes and AES-encrypted stream URLs. Currently CAPTCHA-gated for stream resolution. |
| **AnimeFire** | PT-BR anime streaming site. Scraped via HTML parsing. Video extraction supports multiple strategies: JSON video API, `data-video-src` attributes, `<video>` elements, Blogger iframes, and regex fallbacks. |
| **Goyabu** | PT-BR WordPress-based anime streaming site. Search via WP REST API + HTML fallback, episode listing from JS arrays, stream resolution via Blogger token decode AJAX endpoint. |

## Data Stores

| Storage | Purpose |
|---------|---------|
| **SharedPreferences** (local key-value) | AniList OAuth token & user profile; watch progress per anime; watch history (last 50 entries); favorites list. Persists across app restarts. |
| **In-memory TTL Cache** (`TtlCache`) | Search results (30 min TTL), episode lists (1 h), AniList enrichment metadata (24 h), raw HTTP GET responses (5 min). Cleared on app restart. |
