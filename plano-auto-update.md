# Plano de Implementação — Auto-Update via GitHub Releases

> **Status:** proposta de arquitetura — nenhum código foi alterado.
> **Autor:** arquitetura (análise do repositório atual)
> **Alvo:** GoAnime TV (Android TV, Flutter)

---

## 1. Contexto

### 1.1 O projeto

- **App:** GoAnime TV — streaming de animes para **Android TV**, navegação 100% por D-pad/teclado.
- **Stack:** Flutter/Dart, `media_kit` (player HLS), `http` + `html` (scraping), `shared_preferences`, `path_provider`, `provider`.
- **Versão atual:** `pubspec.yaml` → `version: 1.0.0+1000000` (versionName `1.0.0`, versionCode `1000000`).
- **Repositório:** `github.com/JabsDev/goanime-tv` (público). **Sem** tags, sem releases e sem CI GitHub Actions hoje.
- **Manifesto:** `android/app/src/main/AndroidManifest.xml` — `applicationId: com.example.goanime_tv`, TV-only (`android.software.leanback required`), `usesCleartextTraffic=true`, armado via flag `MainActivity` com `launchMode=singleTop`, portrait bloqueado (`screenOrientation=landscape`).
- **Signing:** `android/app/build.gradle.kts` assina `release` com a **chave de debug** (`signingConfigs.getByName("debug")`).

### 1.2 O problema

O app é distribuído **fora da Play Store** (sideload via APK por `adb`/arquivo). Não existe hoje nenhum mecanismo de descobrir versões novas nem de se atualizar — o usuário precisa procurar manualmente um APK novo e reinstalar.

### 1.3 Objetivo (requisito do usuário)

1. Verificar no GitHub se houve **release novo**.
2. Se houver e não for ignorado: **atualizar automaticamente** ou **pedir permissão** ao usuário.
3. Funcionar sem degradar a UX de TV (sem toque, foco via D-pad, off-before-on no boot).

### 1.4 Fatos que já existem e serão reutilizados (não reinventar)

| Já existe | Uso no update |
|---|---|
| `package_info_plus` (**dependência transitiva** — já no `pubspec.lock` e no `build/`) | ler `versionName`/`versionCode` em runtime — basta promover a dependência direta |
| `http` + retry/backoff em `ApiClient` (`lib/core/network/api_client.dart`) | padrão de rede; o download binário fará `http` direto (ver seção 5.3) |
| `SharedPreferences` (via `SettingsService`) | throttle da checagem (1×/dia) e "ignorar versão" |
| `path_provider` | gravar o APK baixado em pasta externa do app |
| `AppConstants.userAgent` | header obrigatório na API do GitHub |
| Padrões de UI TV: `ThemeConstants`, `TvButton`, `FocusKeyHandler`, `AppTopBar`, diálogo do `anilist_login_dialog` | telas/diálogos do update |
| Testes com `mocktail` + `ApiClient.clientOverride` | testes da checagem sem rede real |

---

## 2. Decisões arquiteturais (com alternativas e porquê)

### 2.1 D1 — Fonte dos releases: API REST do GitHub

- `GET https://api.github.com/repos/JabsDev/goanime-tv/releases/latest`
- Retorna JSON: `tag_name`, `name`, `body` (changelog), `assets[]`, `prerelease`, `draft`.
- **Por que:** zero backend próprio (filosofia do app), repositório já existe e é público, endpoint sem auth.
- **Alternativas descartadas:**
  - **Play Store In-app update:** exige publicação na Play; o app não está lá e não quer depender disso.
  - **Servidor próprio + OTA:** contraria o "sem backend próprio" do projeto.
  - **Firebase App Distribution / outros:** mais infra do que o problema pede.

### 2.2 D2 — Identificação de versão: build number como chave monotônica

- O Flutter deriva `versionCode` da parte `+N` do `pubspec.yaml` (`1.0.0+1000000` → `versionCode=1000000`).
- **Convenção de tag de release:** `vMAJOR.MINOR.PATCH+BUILD`, ex.: `v1.0.1+1000001`.
- **Comparação:** a comparação autoritativa usa o **build number** inteiro (monotônico — não precisa de parser de semver para o caso comum). Se a tag não tiver `+N`, cai em comparação semver simples (MAJOR→MINOR→PATCH).
- **Por quê:** versionCode já é a fonte confiável de "novo > antigo" no Android; semver com prerelease é armadilha desnecessária.

### 2.3 D3 — Leitura da versão instalada: `package_info_plus`

- Promover a dependência transitiva para direta em `pubspec.yaml` (não adiciona plugin nativo novo — já compila no projeto).
- `PackageInfo.fromPlatform()` → `versionName` + `versionCode`.
- **Alternativa descartada:** constante hardcoded `AppConstants.appVersion` — uma utilidade a menos, mas **drifts** (todo build esqueceria de sincronizar).

### 2.4 D4 — Checagem: não-bloqueante, throttled, manual + automática

- **Automática:** na inicialização (disparada após a Home montar, em background). **Throttle:** no máximo 1 vez por dia por dispositivo (persistido em `SharedPreferences`), e nunca em modo rede indisponível.
- **Manual:** botão "Verificar atualizações" nas Configurações (força a checagem mesmo no mesmo dia).
- **Ignorar versão:** usuário pode fechar o aviso com "Agora não" e/ou "Ignorar esta versão" (persistido o `tag_name` ignorado).
- `prerelease` e `draft` **são ignorados**.
- Release sem asset de APK → tratado como "sem update" (log).
- **Rate limit GitHub (60 req/h sem token):** irrelevante com throttle de 1×/dia/horizonte não-opcional. Não usar AppCaches para o JSON de checagem — queremos sempre fresco.

### 2.5 D5 — Download: streaming direto, com progresso e cancelável

- `http.get(assetUrl, headers: User-Agent).stream` → gravar em `RandomAccessFile` na pasta **externa do app** (`getExternalFilesDir(null)`) com `simultaneousWrites=1`.
- Progresso = bytes recebidos / `contentLength` (o S3 envia `content-length` no redirect de `browser_download_url`).
- **Não usar `ApiClient.get`** para o APK: ele cacheia em memória (`AppCaches`), e um binário de dezenas de MB estouraria o cache do processo.
- Falha/interrupção → apagar arquivo parcial e oferecer "tentar novamente" (sem resume — YAGNI).
- Usar pasta externa (não `getApplicationSupportDirectory`): evita problemas de path interno com o instalador e deixa espaço mais barato; apagar o arquivo após instalação bem-sucedida.

### 2.6 D6 — Instalação: Platform Channel nativo mínimo (Android)

Não existe jeito 100% Dart de instalar APK no Android. Duas opções:

- **Opção A (recomendada):** `MethodChannel` próprio, ~80–120 linhas em Kotlin no `MainActivity` (`installApk(path)`), usando **`PackageInstaller` API** (sessões de instalação). Sem dependência externa, sem risco de plugin abandonado, comportamento sob nosso controle.
- **Opção B (alternativa):** plugin da comunidade (`package_installer`/`flutter_package_installer`). Menos código próprio, mas plugin externo Android-only com manutenção incerta.

**Decisão:** começar com a **Opção A** (chamada nativa curta e estável), usando `FileProvider` para expor o APK baixado com URI `content://` e `gra}.` — e fazer fallback para o jeito manual se a instalação automática falhar em algum device.

Todos os APKs da linha devem ser assinados com a **mesma chave** (hoje: debug). Caso contrário o instalador rejeita a atualização por assinatura divergente ("app não instalado / pacote conflitante") e o usuário precisaria desinstalar antes.

### 2.7 D7 — UX de TV (sequência de telas)

1. **Detecção (background):** sem bloquear o boot. Home carrega normalmente.
2. **Prompt:** diálogo TV-friendly — ícone, "Nova versão vX.Y.Z disponível", changelog (release `body`, até N linhas), botões **"Atualizar agora"** (primário), **"Agora não"**, opcional **"Ignorar esta versão"**.
3. **Progresso:** diálogo com `LinearProgressIndicator` (% , MB/mb), botão **"Cancelar"**.
4. **Concluído:** troca para status "Instalando..." e chama o canal nativo → Android abre a página de instalação do sistema → app reinicia `singleTop`.
5. **Falha de instalação** (ex.: unknown sources desabilitado): diálogo de erro com instrução manual + botão para abrir a pasta/arquivo na UI do sistema quando aplicável.

Todos os diálogos seguem o padrão visual existente (`ThemeConstants.surface`, foco `FocusKeyHandler` + `TvButton`), navegáveis 100% por setas.

### 2.8 D8 — Sem configuração/abstração especulativa

- UpdateService é **singleton `instance`** como `SettingsService`/`ProfileService` (padrão do projeto) — expõe `ValueListenable<UpdateState>` via `ValueNotifier` para UI reagir (mesmo padrão do `liteModeListenable`).
- Sem "verificador configurável por fonte", sem "canal de feed genérico", sem abstração de downloader plugável. Uma fonte (GitHub), um caso de uso. **YAGNI.**
- Sem "resume de download" na v1; sem atualização em background silenciosa na v1 (sempre com confirmação, como pedido).

---

## 3. Fluxo de ponta a ponta

```
BOOT ──► Home monta ──► UpdateService.check(auto: true)
                           │ se (throttle OK) e (não é pré/draft)
                           ▼
                    GET /releases/latest  (JSON)
                           │ tag/build > instalado?  ──não──► fim (silencioso)
                           ▼ sim
                    Diálogo "Nova versão"  ──Agora não──► fim
                       │ "Ignorar versão" → persiste tag → fim
                       │ "Atualizar agora"
                       ▼
                    Download streaming p/ getExternalFilesDir (progresso)
                       │ cancelado/falhou → apaga arquivo, fim
                       ▼
                    MethodChannel installApk(path)  ──OK──► instalação do SO
                       │ falhou ──► diálogo de erro + instrução manual
```

---

## 4. Estrutura de projeto (arquivos novos/editados)

Segue a convenção de pastas do repo (`lib/core`, `lib/features`, `lib/shared`).

### 4.1 Novos arquivos — Dart puro (testáveis sem device)

```
lib/core/updater/
  version_compare.dart        — parse de tag ("v1.2.3+1000003") + comparação (build → semver)
  github_release_api.dart     — modelo ReleaseInfo + chamada à API (http puro, sem cache)
  update_service.dart         — orquestração: check/download/instal (singleton + ValueListenable<UpdateState>)
  update_constants.dart       — repo slug, regex de tag, intervalo de throttle (ou em AppConstants)
```

```
lib/features/updater/
  update_available_dialog.dart  — prompt "Nova versão" (changelog + 3 ações)
  update_progress_dialog.dart   — barra de progresso + cancelar + estado "Instalando..."/erro
  update_manager_widget.dart    — (opcional) hook discreto na Home p/ disparar check e ancorar diálogos
```

### 4.2 Novos arquivos — nativo Android

```
android/app/src/main/kotlin/com/example/goanime_tv/UpdaterChannel.kt   — MethodChannel "goanime_tv/updater"
                                                                    call "installApk" via PackageInstaller
android/app/src/main/res/xml/file_paths.xml                          — FileProvider paths (external-files-path)
```

### 4.3 Arquivos editados

| Arquivo | Mudança |
|---|---|
| `pubspec.yaml` | promover `package_info_plus` para dependência direta |
| `android/app/src/main/AndroidManifest.xml` | `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>` + declaração `<provider>` (FileProvider) |
| `android/app/build.gradle.kts` | **keystore de release estável** (ver Fase 0) |
| `lib/core/constants/app_constants.dart` | `githubRepo = 'JabsDev/goanime-tv'` (+ talvez `updateCheckInterval`) |
| `lib/features/home/home_screen.dart` | disparar `UpdateService.instance.check()` pós-frame (não-bloqueante) |
| `lib/features/settings/settings_screen.dart` | seção "Atualizações": toggle "Verificar no início" + botão "Verificar agora" |

### 4.4 Contratos de API (rascunho das assinaturas)

```dart
// version_compare.dart
int compareAppVersions({required int installedBuild, required String installedVersion,
                       required String tagName}); // >0 → release é mais novo

// github_release_api.dart
class ReleaseInfo {
  final String tagName; final String? versionLabel;
  final String? changelog; final Uri? apkUrl; final int? apkSize;
  bool get isPrerelease; bool get isDraft;
}
Future<ReleaseInfo?> fetchLatestRelease({http.Client? client});

// update_service.dart
enum UpdateState { idle, checking, updateAvailable, downloading, installing, error }
class UpdateService {
  static final instance = UpdateService._();
  ValueListenable<UpdateState> get state;
  ValueListenable<double?> get progress; // 0..1 durante downloading
  Future<void> check({required bool manual});      // aplica throttle se !manual
  Future<void> downloadAndInstall(ReleaseInfo r);  // download → native install
  Future<void> ignore(ReleaseInfo r);              // guarda tagName ignorado
  bool get wasIgnored(String tagName);
  Future<bool> hasUpdate();                        // pré-checagem lógica
}

// UpdaterChannel.kt (esqueleto de contrato)
class UpdaterChannel : MethodChannel.MethodCallHandler {
  override fun onMethodCall(call, result) {
    when (call.method) {
      "installApk" -> install(call.argument<String>("path") ?: "", result)
      else -> result.notImplemented()
    }
  }
}
```

---

## 5. Plano de ação (fases + verificação)

### Fase 0 — Preparação e chave de assinatura ⚠️ (pré-requisito de tudo)

1. Criar/proteger um **keystore de release** próprio (ex.: `android/key.properties` + `releaseKey store`, gitignored com `.gitignore` já cobrindo segredos).
2. Ajustar `build.gradle.kts` para carregar `key.properties` e assinar `release` com essa chave.
3. Definir a **convenção de tag** `vX.Y.Z+BUILD` e documentá-la em `README.md`.

> 🛡️ **Crítico:** a chave define se a atualização será possível. Trocar de chave depois = só desinstalando o app. Resolver agora, antes de qualquer release que o update detecte.

**Verificação:** `flutter build apk --release --dart-define=...` (ou padrão), instalar sobre build anterior e confirmar que o sistema aceita.

### Fase 1 — Saber a versão instalada

1. Promover `package_info_plus` em `pubspec.yaml` (`flutter pub get`).
2. `lib/core/updater/version_compare.dart` + testes unitários.
3. `UpdateService.instance` inicializa com `PackageInfo` (fallback seguro se `fromPlatform` falhar: `AppConstants` version `1.0.0+0`).

**Verificação:** `flutter test test/` — responsáveis novos `version_compare_test.dart`:
- tag `v1.0.0+1000000` vs instalado `1000000` → igual;
- `v1.0.1+1000001` vs `1000000` → mais novo;
- `v1.2.0+999999` vs `1000000` → build menor, mesmo semver maior → **não** instala (chave é build);
- tag sem `+N` e semver maior/menor; malformada (não lança exceção).

### Fase 2 — Checagem no GitHub

1. `lib/core/updater/github_release_api.dart`: GET `releases/latest` com `AppConstants.userAgent`, parse com `dart:convert`, ignora `prerelease`/`draft` e release sem asset `.apk`.
2. Throttle: `SettingsService`/`SharedPreferences` — `last_update_check_at` (epoch ms), `CHECK_INTERVAL = 1 dia`; `manual` ignora o intervalo.
3. `UpdateService.check()`: pipeline "tem rede? → throttle? → fetch → compare → emitir `updateAvailable`".
4. Persistir o `tagName` ignorado (`ignored_update_tag`).

**Verificação/QA:**
- `flutter test` com mock de `http` (padrão `ApiClient.clientOverride`): JSON com release novo/igual/prerelease/sem asset.
- Manual: publicar uma tag de teste no GitHub e conferir log + estado.

### Fase 3 — Download com progresso

1. `UpdateService.downloadAndInstall()`: `http.get(apkUrl).stream` → write em `getExternalFilesDir(null)/updates/goanime<tag>.apk`; `progress` via `ValueNotifier<double>`.
2. Cancelamento → `close()` da subscription + apagar arquivo parcial.
3. Falha → apagar parcial, emitir `error` com mensagem; limpar arquivo ao final (sucesso ou cancelamento).

**Verificação:** `flutter test` com mock do stream; manual: liberar um APK pequeno de teste e validar progresso % no diálogo em emulador.

### Fase 4 — Instalação nativa (PackageInstaller)

1. `UpdaterChannel.kt`: método `installApk(path)` criando sessão `PackageInstaller.Session` (`CreateParams`, `writeBytes`, `commit`) com callback de resultado.
2. `FileProvider` + `<provider>` no `AndroidManifest.xml` + `REQUEST_INSTALL_PACKAGES`.
3. Registrar o canal no `MainActivity` (e apenas no `MainActivity`, correto p/ `singleTop`).

**Verificação:** manual em emulador Android TV:
- instalar versão antiga → disparar update → confirmar que o SO instala a nova e o app abre sem desinstalar;
- `adb install` de um APK com **outra chave** → confirmar que o diálogo de erro aparece (teste negativo);
- unknown sources desabilitado → mensagem de erro amigável.

### Fase 5 — UI de TV

1. `update_available_dialog.dart`: `showDialog` seguindo estilo do `anilist_login_dialog` — `ThemeConstants.surface`, `TvButton` primário "Atualizar agora", secundário "Agora não", link "Ignorar esta versão"; changelog rolável com `Focus`/D-pad.
2. `update_progress_dialog.dart`: status `downloading` → barra % / MB; `installing` → "Instalando..."; `error` → mensagem + botão fechar/reintentar.
3. `home_screen.dart`: no pad de `initState`/pós-frame, `unawaited(UpdateService.instance.check())`.
4. `settings_screen.dart`: toggle "Verificar atualizações no início" (default ON, persistido) + "Verificar agora".

**Verificação:** `flutter analyze` limpo; manual no emulador TV (navegação 100% setas). Widget test para o diálogo (abre, botões disparam callbacks) — espelhar padrão de `test/`.

### Fase 6 — Pipeline de release (GitHub Actions + end-to-end)

1. `.github/workflows/release.yml`: dispara em tag `v*` → `flutter build apk --release` → sobe o APK formato `goanime-tv-<tag>.apk` como asset da release (via `gh release create`/action `softprops/action-gh-release`) e usa **o texto/título da release como changelog**.
2. Teste fim a fim real: device com v1.0.0+1000000 → publicar `v1.0.1+1000001` via workflow → atualização automática na TV.
3. (Opcional, fase posterior) intervalo "beta" via `prerelease` — já ignorado pelo mecanismo.

**Verificação:** release publicada com asset; app detecta, pergunta, baixa, instala, reinicia na versão nova.

---

## 6. Riscos e pontos de atenção

| Risco | Impacto | Mitigação |
|---|---|---|
| **Chave de assinatura não versionada** | Update inviável depois (precisa desinstalar) | Fase 0 primeiro; keystore próprio + `key.properties` no `.gitignore` |
| Rate limit GitHub (60 req/h anônimo) | Checagem falha | Throttle 1×/dia + tratamento de 403/429 como "sem update" silencioso |
| Download interrompido no meio | APK corrompido | apagar parcial + tentar de novo (sem resume na v1) |
| Unknown sources desabilitado na TV | Instalação falha | diálogo de erro com instrução de onde habilitar |
| Espaço em disco de TV fraca | Download falha | usar pasta externa; validar espaço disponível antes (estimar do `apkSize`), mensagem clara |
| Build grande vs cache de memória | OOM ao usar `ApiClient.get` no APK | download via `http` cru (sem cache), streaming |
| `singleTop` + atividade secundária | Canal nativo registrado 2× | registrar canal uma única vez no `MainActivity.configureFlutterEngine` |

---

## 7. Testes

**Unitários (Dart puro, sem device):**
- `test/version_compare_test.dart` — casuística da seção Fase 1.
- `test/github_release_api_test.dart` — parse de JSON real/simulado (release nova, igual, prerelease, sem asset, 200/404/429).
- `test/update_service_test.dart` — throttle respeitado, "ignorar versão" persiste e bloqueia novo prompt, estado via mocktail.

**Widget (padrões já existentes em `test/`):**
- diálogos: ações corretas, foco inicial no botão primário, navegação D-pad.

**Manual em Android TV (checklist QA):**
1. Fresh install de v1.0.0 → nenhuma checagem automática antes da Home pronta.
2. Update disponível → diálogo sem travar o app.
3. Download com progresso → cancelar → arquivo removido.
4. Instalação → SO instala sobre a versão antiga, dados (favoritos/perfis) preservados.
5. VersionCode menor via tag malformada → não atualiza.

---

## 8. Processo de release (referência para quem publicar)

```
1. Bump versão: pubspec.yaml version: X.Y.Z+N  (N ímpar crescente)

   ex.: 1.0.1+1000001

2. flutter test && flutter analyze
3. Tag:        git tag v1.0.1+1000001
   git push origin v1.0.1+1000001        # (CI gera o APK, ou gera local)
4. Release title/body = changelog         # vira o texto exibido no diálogo
   Asset: goanime-tv-v1.0.1+1000001.apk   # APK universal (todas ABIs)
5. App nas TVs: checagem automática no próximo boot / botão "Verificar agora"
```

---

## 9. Escopo fora desta v1 (explicitamente adiado — YAGNI)

- Resume de download interrompido.
- Canal de distribuição múltiplo (Play Store + GitHub simultâneos).
- "Force update" (bloquear o app até atualizar).
- Delta/patch de APK, updates menores que o APK inteiro.
- Atualização 100% silenciosa em background.
- Suporte a canal/alpha/beta seletivos (prerelease já é ignorado por padrão).

---

## 10. Resumo do que muda

| Camada | Novo código | Dependência nova |
|---|---|---|
| Dart (lógica) | `core/updater/*` + `features/updater/*` | `package_info_plus` (já transitiva) |
| Nativo | `UpdaterChannel.kt` + `file_paths.xml` | nenhuma |
| Config | AndroidManifest (permission+provider), build.gradle (keystore), pubspec | — |
| Release | GitHub Actions + convenção de tag | nenhuma |

**Próximo passo sugerido:** executar a **Fase 0** (keystore) e a **Fase 1** (`package_info_plus` + `version_compare` + testes) — juntas definem o fundamento do resto e cabem num único PR pequeno.