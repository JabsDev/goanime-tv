# goanime_tv

A new Flutter project.

## Fontes (AnimeSource)

Status dos provedores de stream/episódios:

- **AnimeFire** — OK. Busca, grade de episódios e vídeo por scraping HTML.
- **Goyabu** — OK. Busca HTML, episódios (JSON `allEpisodes` + fallback) e vídeo HLS.
- **BetterAnime / AnimesROLL / DooPlay** — OK. Mesmo adapter DooPlay (HTML + player API).
- **AnimePlayer** — OK. Mesma família DooPlay, domínio próprio.
- **AniList** — metadados apenas (títulos, episódios, nota, gêneros). Não participa da busca nem da reprodução de vídeo.
- **AllAnime** — desativado (requer captcha Cloudflare/Turnstile, externo ao app).
- **Removidos** — SuperFlix, AnimesDigital, Anikyuu, AnimeIto, AnimePlay, AnimeQ, Anitube, Dattebayo (não implementados, sem valor real ou com leak de conexão).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
