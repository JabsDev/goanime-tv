# Plano de Implementação — Auto-Update via GitHub Releases (v2)

> **Status:** proposta de arquitetura — nenhum código foi alterado.
> **Origem:** revisão crítica do `plano-auto-update.md` (v1). Este documento **corrige e completa** a v1; onde não há mudança, herda a v1.
> **Alvo:** GoAnime TV (Android TV, Flutter)

---

## 0. O que muda em relação à v1 (resumo)

| # | Falha da v1 | Correção nesta v2 |
|---|---|---|
| 1 | Troca para chave de release "quebra" a atualização de todos os instalados (hoje assinados com debug) e o plano não trata a migração | Seção 4 + Fase 0: decisão explícita de chave e o custo de dados de cada opção |
| 2 | "`.gitignore` já cobre segredos" — **falso** (não tem keystore/key.properties) | Fase 0 inclui adicionar entrada no `.gitignore`; keystore entra no CI só via secrets |
| 3 | `PackageInstaller` subespecificado (sem `IntentSender`/confirmação do sistema, sem tratamento de resultado, "app reinicia em `singleTop`" é wishful) | D6 reescrito: fluxo completo de commit + confirmação + o que acontece com o processo; política de relaunch honesta |
| 4 | **Nenhuma política de preservação/legibilidade dos dados** — `ProfileStore` vira parse failure em `[]`/`{}` silencioso; futura mudança de formato apaga dados | **Seção 3 + Fase 6** (nova): schema version + migração; invariavelmente "nunca vazio se falhar parse" |
| 5 | Escrita não-atômica (`writeAsStringSync`) + kill do processo no commit → arquivo truncado/corrompido | **Seção 3**: escrita atômica (temp+rename), `.bak` de última versão boa, flush antes do install |
| 6 | Fallback manual ambíguo (risco de virar "desinstale e reinstale" = perda total); "abrir a pasta" inexistente em TV | D6: fallback = `ACTION_VIEW` via FileProvider; **proibido orientar desinstalar** sem aviso explícito |
| 7 | `releases/latest` docs-only (sem APK) bloqueia updates futuros | D4: varre releases até a última com asset `.apk` |
| 8 | Throttle grava mesmo em erro (403/429/offline) → 24h parado | D4: throttle só é persistido em **checagem bem-sucedida** |
| 9 | Fase 6 (CI) sem assinatura → APK de CI com assinatura divergente da release | Fase 7: workflow assina via keystore em secrets |
| 10 | Sem integridade do binário, sem pre-flight de espaço, sem guarda de concorrência | D5 + Fase 3 + seção 6 (estado) |
| 11 | Contrato vazando YAGNI (`hasUpdate()`); "N ímpar" sem explicar; texto "gra}." truncado | Contrato revisado; convenção `+N` sempre crescente (sem ímpar/par); typo removido |

---

## 1. Contexto

### 1.1 Fatos verificados no repositório (nesta revisão)

- `version: 1.0.0+1000000` (versionCode `1000000`).
- **Signing:** `android/app/build.gradle.kts` assina `release` com `signingConfigs.getByName("debug")` → **todos os APKs distribuídos hoje são debug**.
- **Dados do usuário (inventário completo — fonte da seção 3):**
  - `ProfileStore` → `getApplicationDocumentsDirectory()/profiles/<id>/{profile.json, favorites.json, history.json, progress.json, lists_cache.json}` (linhas 31–33, 78–83, 151, 236–253, 322–348 de `lib/core/profile/profile_store.dart`), com escrita **síncrona não-atômica** (`writeAsStringSync`) e parse-failure virando `[]`/`{}` silencioso (linhas 85–119).
  - `SharedPreferences` → token/sessão AniList (`anilist_auth_service.dart`), settings (`settings_service.dart`), match de fontes (`provider_match_store.dart`), `current_profile_id`.
- **`.gitignore` NÃO cobre `*.jks`/`key.properties`** (visto arquivo completo).
- `package_info_plus` é dependência **transitiva** (confirmado no `pubspec.lock`).
- `MainActivity.kt` é `FlutterActivity` com corpo vazio — canal nativo será adicionado aqui.
- Sem `connectivity_plus`/`device_info` no projeto.

### 1.2 O problema (inalterado da v1)

Sideload fora da Play Store: sem mecanismo de descobrir/instalar versões novas.

---

## 2. Invariantes invioláveis (NOVO — leia antes de tudo)

O update **proíbe** qualquer caminho que perca dados do usuário. Estes invariantes são condições de aceite de qualquer PR:

- **I-1 — Mesma identidade:** a instalação nunca muda `applicationId` (`com.example.goanime_tv`) nem a **chave de assinatura** sem uma estratégia de migração explícita (Seção 4.1). Assinatura diferente = o Android recusa atualizar por cima = só resta desinstalar (perde tudo).
- **I-2 — Instalação só em cima, nunca "por baixo":** usar sempre `PackageInstaller` com commit **atômico** e nunca flags de wipe (`setWipeData=false`). Downgrade de versionCode é proibido (o instalador já rejeita; o app também bloqueia na pré-checagem).
- **I-3 — Nunca orientar "desinstale primeiro":** em nenhum diálogo/mensagem. Se um dia for inevitável (chave trocada), o fluxo é **exceção logada**, exige aviso explícito de perda e oferece export/backup antes.
- **I-4 — Dados nunca "vazios por falha de parse":** se a nova versão não souber ler um JSON antigo, **migra** (Seção 3.3); nunca retorna `[]`/`{}` em silêncio para dados do usuário.
- **I-5 — Gravação atômica com `.bak`:** todo arquivo de dados do usuário é escrito via temp+rename, guardando a última versão boa.
- **I-6 — Flush antes do commit:** nenhuma instalação começa antes de toda persistência de dados estar gravada em disco (Seção 3.4).
- **I-7 — Binário íntegro:** só instala APK cujo digest confere com o da release (Seção 5.2).

---

## 3. Dados do usuário e sua preservação (NOVO — o núcleo desta v2)

### 3.1 Inventário (quem perde o quê)

| Dado | Local de armazenamento | Perde se... |
|---|---|---|
| Perfis (nomes, avatar, id) | `profiles/<id>/profile.json` | desinstalar |
| Favoritos | `profiles/<id>/favorites.json` | desinstalar **ou formato novo não lido** |
| Histórico | `profiles/<id>/history.json` | desinstalar **ou formato novo não lido** |
| Progresso por episódio | `profiles/<id>/progress.json` | desinstalar **ou formato novo não lido** |
| Cache de listas AniList | `profiles/<id>/lists_cache.json` | desinstalar |
| Sessão/token AniList | `SharedPreferences` | desinstalar |
| Settings, match de fontes, perfil atual | `SharedPreferences` | desinstalar |
| APK baixado (temporário) | `getExternalFilesDir(null)/updates/` | — (é lixo técnico, apagado no fim) |

### 3.2 Por que um update "preserva" (e quando não preserva)

Instalar em cima (mesma appId + mesma chave + versionCode ≥) **preserva** o sandbox do app: JSONs e SharedPreferences ficam intactos. O risco real não é o instalador apagar — é:

1. **Formato ilegível pela nova versão** → dados presentes em disco, sumidos na UI.
2. **Escrita corrompida na janela de instalação** → processo morto no meio de um `writeAsStringSync`.
3. **Desinstalação forçada perseguida por engano** (fallback mal desenhado ou chave trocada).

### 3.3 Schema version + migração (fecha o risco nº 1)

- Adicionar **`schemaVersion` de dados** sutil ao `profile.json` (e um no `progress.json` se mudanças exigirem). Campo `"schema": 1`.
- Regra: **qualquer mudança de formato** incrementa o schema e adiciona uma migração **dentro do mesmo PR**; o código novo **sempre** é capaz de ler `schema-1`.
- Quando a leitura falhar (parse error), o comportamento deixa de ser "silencioso":
  - tentar `.bak` (Seção 3.5);
  - se ambos ilegíveis, logar com path + preservar o arquivo em disco (não sobrescrever) e criar estado vazio apenas com aviso ao usuário.
- A v1 já trata corrupção em leitura como `[]`/`{}` — o problema é que **isso hoje é o "comportamento final"**, não um último recurso.

### 3.4 Escrita atômica + flush (fecha o risco nº 2)

- Trocar o padrão de gravação do `ProfileStore` (e do `shared_preferences` onde o timing importar) por:
  1. escrever `file.json.tmp` → `rename` para `file.json` (atômico na mesma partição);
  2. antes de sobrescrever, se existir versão anterior válida, renomear para `file.json.bak` (**uma** geração).
- `UpdateService` expõe `Future<void> flushData()`: aguarda/força a escrita de todas as pendências (ProfileStore + SharedPreferences) **antes** de chamar `installApk`.
- Isto independe do update: é robustez geral do app, mas o update é quem mais expõe a janela.

### 3.5 Backup leve (recomendado, baixo custo)

- Manter `*.bak` por geração (item 3.4) cobre crash/truncamento.
- Export opcional: favoritos/histórico já vivem no AniList (parcial); não adicionar backend novo. V1 do plano já **explicitamente adia** export — **reavaliar** se a chave mudar (item 4.1).

---

## 4. Decisões arquiteturais (v2)

### D1 — Fonte: API do GitHub (com correção da v1)

- `GET /releases/latest` continua sendo o caminho rápido.
- **Correção:** `releases/latest` pode ser uma release *docs-only* (sem asset .apk) e mais nova que a instalada. Nesse caso **não** parar: cair para `GET /releases?per_page=20` e tomar a última release **com asset `.apk`** e sem `prerelease`/`draft`. Só se nenhuma tiver asset é que vira "sem update".
- Cabeçalho: `User-Agent` obrigatório (existe em `AppConstants.userAgent`).

### D2 — Identificação de versão

- Herda a v1 (build number monotônico, tag `vX.Y.Z+BUILD`, fallback semver para tag sem `+N`).
- **Remover** a convenção "`N ímpar`" da v1 (sem explicação e desnecessária — `prerelease` já é ignorado). Doc: **`N` deve ser estritamente crescente em toda tag de release**; um hotfix que esqueça de subir `N` simplesmente não atualiza (defeito detectável em CI — ver Fase 7).
- Testes adicionais pedidos v1 mantidos; adicionar caso "mesmo build, semver maior" → **não** atualiza (é decisão de design, não bug; documentar no release process).

### D3 — Versão instalada: `package_info_plus`

- Herda v1 (promover para dependência direta; já transitiva). Fallback `1.0.0+0` se `fromPlatform` falhar.

### D4 — Checagem (corrigida)

- **Throttle só em sucesso:** `last_update_check_at` é gravado **após** uma checagem que retornou respostas HTTP válidas (200/404). Em 403/429/erro de rede/timeout → **não** grava; silencioso e pode tentar no próximo boot. (Sem `connectivity_plus`: rede indisponível é só "erro tratado como sem update".)
- **Guarda de concorrência:** `check()` é no-op se o estado atual não for `idle` (impede duplo diálogo/download com "Verificar agora").
- **Ignorar versão** e pré/draft: herdam v1.
- `prerelease`: a v1 mostra que `releases/latest` já exclui prereleases; no fallback via `/releases`, filtrar `prerelease:true` e `draft:true` no parse.

### D5 — Download (corrigida — D5-a integridade, D5-b espaço)

- Streaming p/ `getExternalFilesDir(null)/updates/goanime-tv-<tag>.apk`, progresso via `ValueNotifier<double?>`. Sem cache (`ApiClient` fica proibido aqui, como na v1).
- **Pre-flight de espaço:** antes de baixar, comparar `apkSize` (+ margem ~10%) com o espaço livre do volume externo (`StatFs` no nativo ou file length apóisione a shell/plugin — mínimo: checar espaço **após** `contentLength` conhecido no primeiro byte e abortar com diálogo claro).
- `content-length` ausente (redirect sem header): progresso indeterminado (`null` → barra pulsante), não erro.
- **Integridade (D5-a):** a API do GitHub expõe `digest` (SHA-1) por asset e a release pode publicar `sha256` no `body`. Verificar o digest após o download e **antes** do `installApk`; divergência → apagar e avisar (nenhum binário suspeito vai para o instalador).
- **Limpeza de órfãos:** no boot, `UpdateService` apaga arquivos parciais em `updates/` com idade > 24h (processo morto no meio do download).
- Falha/cancelamento: herda v1 (apagar parcial, sem resume).

### D6 — Instalação: PackageInstaller (reescrita da v1 — o ponto mais subespecificado)

**Opção A (recomendada) — `MethodChannel` próprio em Kotlin:**

- `SessionParams` com `mode = MODE_FULL_INSTALL`, `setPackageName(fromContext.packageName)`? não — **sem** `setPackageName` para app não concedido… (decisão concreta a validar em device), `setSize(apkBytes)`.
- `PackageInstaller.createSession(params)` → `openWrite` → `writeBytes` → `fsync` → `commit(IntentSender)`.
- **Confirmação do sistema — o que a v1 omitia:** em API 26+, uma instalação de aplicativo sendo atualizada pede confirmação; o commit precisa de um `PendingIntent.getBroadcast`/`getActivity` que dispara `ACTION_CONFIRM_INSTALL` (API 26) ou resulta direto. **O resultado vem DE VOLTA por essa Intent** — quem escuta é o próprio app (processo pode estar vivo ainda) ou um `BroadcastReceiver` (para o caso de o processo morrer).
- **Mapeamento de resultado:** `SESSION_COMMIT_SUCCESS` → sucesso; códigos de erro (`INSTALL_FAILED...`) mapeados para mensagens amigáveis já previstas (unknown sources, assinatura, espaço). Cada código tem ação: assinatura → avisar que é chave divergente (nunca sugerir desinstalar — I-3); unknown sources → instrução de onde habilitar.
- **Relaunch honesto (correção da v1):** o commit **mata o processo** do app (PackageInstaller encerra o alvo). Não há relaunch automático confiável. Política definida: (a) o `BroadcastReceiver` tenta reaparecer o app **se** o SO entregar a intent com o processo ainda vivo; senão (b) UX: "Instalação concluída — reabra o GoAnime TV" (aceitável em TV). **Não prometer** "app reinicia em singleTop".
- Registro do canal **uma única vez** em `configureFlutterEngine` do `MainActivity` (mantém a correção da v1 sobre `singleTop`).

**FileProvider — só para o fallback.** O instalador nativo lê o arquivo por path direto (nativo mesmo), **não precisa** de `content://`. `FileProvider` + `file_paths.xml` existem **apenas** para o fallback de instalação via Intent (`ACTION_VIEW` com `content://` + `grantUriPermission`). A v1 não separava os dois papéis.

**Fallback (Opção B) — uma concessão controlada:**
- Se `installApk` falhar por causa do fluxo PackageInstaller (não por assinatura/espaço), abrir `ACTION_VIEW` com o URI `content://` → instalador do sistema. Isso **não** é "abrir a pasta": Android TV não tem file manager para navegar; a frase v1 "abrir a pasta/arquivo na UI do sistema" é removida.

### D7 — UX de TV (herda v1 com estados corrigidos)

Sequência idêntica à v1 (detecção → prompt → progresso → instalação → erro). Mudanças:
- Diálogo de erro distingue **causa** (assinatura / unknown sources / espaço / rede).
- Maior o guarda-concorrência: diálogos são âncora de um único `UpdateState` (`ValueNotifier`).
- Nova tela/estado "Instalando..." passa a ser **"instalei, reabra o app"** quando confirmado pelo receiver (I-4 não aplica — isso é UX, não dado).

### D8 — YAGNI (corrigido da v1)

- Mantida a disciplina; **removido `hasUpdate()` do contrato** (duplicava `check()`, era especulação). Contrato final na Seção 6.
- "Verificador configurável por fonte", "resume de download", "update silencioso em background", "force update": continuam fora (Seção 10).

---

## 5. Fluxo de ponta a ponta (v2)

```
BOOT ─► Home monta ─► UpdateService.check(auto)
        │ (guard: estado == idle) (throttle 1×/dia, validado só em sucesso)
        ▼
 GET /releases/latest
        │ release nova? (build > instalado, não-pré/draft)
        │ ─não──► fim (silencioso; não grava throttle se houve erro de rede/HTTP 5xx/429)
        │ ─sem asset .apk──► GET /releases?per_page=20 → última com asset .apk
        ▼ sim (release com APK mais novo)
 Diálogo "Nova versão"  ──Agora não──► fim
    │ "Ignorar versão" → persiste tag → fim
    │ "Atualizar agora"
    ▼
 [pre-flight espaço livre vs apkSize]
 [download streaming p/ external; progresso; cancela/falha → apaga parcial, fim]
 [verifica digest (sha1 do asset / sha256 do body)]
    ▼
 [UpdateService.flushData()  ← I-6]
 [installApk(path) via PackageInstaller]
    ├─ commit ok ─► confirmação SO ─► [BroadcastReceiver realaunch best-effort / UX "reabra"]
    ├─ erro assinatura ─► diálogo "chave divergente" (nunca desinstalar; logar)
    ├─ erro unknown sources ─► instrução + ACTION_VIEW fallback (FileProvider)
    └─ erro espaço/outro ─► diálogo causa → retry/ACTION_VIEW
 [arquivo do APK apagado no fim (sucesso/cancelamento)]
```

---

## 6. Contratos de API (revisados)

```dart
// version_compare.dart — inalterado da v1
int compareAppVersions({required int installedBuild, required String installedVersion,
                       required String tagName}); // >0 → release mais nova

// github_release_api.dart (adiciona digest e fallback de lista)
class ReleaseInfo {
  final String tagName; final String? versionLabel;
  final String? changelog; final Uri? apkUrl; final int? apkSize;
  final String? apkDigest;      // sha1 do asset (API) ou sha256 do body
  bool get isPrerelease; bool get isDraft;
}
Future<ReleaseInfo?> fetchLatestRelease({http.Client? client}); // inverte p/ /releases quando latest sem apk

// update_service.dart — hasUpdate() REMOVIDO
enum UpdateState { idle, checking, updateAvailable, downloading, installing, done, error }
class UpdateService {
  static final instance = UpdateService._();
  ValueListenable<UpdateState> get state;
  ValueListenable<double?> get progress;        // null → indeterminado
  String? get errorMessage;                     // causa amigável (assinatura/espaço/unknown sources/rede)
  Future<void> check({required bool manual});   // no-op se state != idle; throttle só p/ !manual
  Future<void> downloadAndInstall(ReleaseInfo r);
  Future<void> ignore(ReleaseInfo r);           // persiste tagName ignorado
  bool get wasIgnored(String tagName);
  Future<void> flushData();                     // I-6: persiste tudo antes de instalar
}

// UpdaterChannel.kt
class UpdaterChannel : MethodChannel.MethodCallHandler {
  override fun onMethodCall(call, result) {
    when (call.method) {
      "installApk" -> install(call.argument<String>("path") ?: "", result)
      else -> result.notImplemented()
    }
  }
  // commit(IntentSender) → confirm → BroadcastReceiver onReceive → MethodChannel.invoke back ou comportamento padrão
}
```

---

## 7. Plano de ação (fases + verificação)

### Fase 0 — Chave de assinatura e política de chave ⚠️ (pré-requisito; decide o destino dos dados)

**Decisão obrigatória** (a v1 a pulou):
- **Opção A — Continuar com a chave debug:** zero quebra; todo instalado atual continua atualizável. Custo: assinatura "oficial" é a debug — aceitável para o modelo atual, mas **decidida e documentada** (não é acidente).
- **Opção B — Criar keystore de release próprio:** releases novas e CI com essa chave; **mas todos os instalados hoje (debug) não conseguem atualizar por cima** → primeira release = desinstalar/reinstalar = perda de dados (I-3 não pode). Exige: aviso na release + export/backup de dados (favoritos/histórico AniList) antes, e migração coordenada.

Em B: gerar keystore, `key.properties` (**adicionar `*.jks` e `key.properties` ao `.gitignore`** — não cobre hoje), ajustar `build.gradle.kts` com fallback para debug se ausente (dev local), guardar a keystore como **secret do GitHub** para CI (Fase 7).

**Verificação:** instalar release nova sobre uma instalada e confirmar que o sistema aceita sem desinstalar; teste negativo com outra chave (diálogo de erro, I-3 respeitado).

### Fase 1 — Versão instalada (herda v1)

Promover `package_info_plus`, `version_compare.dart` + testes da v1 (+ caso "mesmo build, semver maior").

### Fase 2 — Checagem GitHub (v1 corrigida)

- `github_release_api.dart` com fallback a `/releases` quando `latest` não tiver APK (D1).
- Throttle **só em sucesso** (D4); guarda `state != idle` (D4).
- Persistência de `tagName` ignorado.

**Verificação:** unit com mock de `http` (release com/sem APK, latest docs-only → pega anterior, 429/offline **não** grava throttle, mesmo dia manual ignora). Manual: tag de teste no GitHub.

### Fase 3 — Download seguro (v1 + correções)

- Streaming, progresso `null`-indeterminado, pre-flight de espaço (D5), verificação de digest (D5-a), limpeza de órfãos no boot (D5), apagar parcial em falha/cancelamento.

**Verificação:** unit com stream mock (digest errado → aborta; space insuficiente → diálogo); manual com APK pequeno em emulador.

### Fase 4 — Instalação nativa completa (v1 reescrita)

- `UpdaterChannel.kt` conforme Seção 6/D6: `SessionParams` (`MODE_FULL_INSTALL`, `setSize`), `commit(IntentSender)` para `ACTION_CONFIRM_INSTALL`, `BroadcastReceiver` (registrado no tempo certo) recebendo o resultado, mapeamento de códigos de erro.
- `AndroidManifest.xml`: `REQUEST_INSTALL_PACKAGES` + `<provider>`; `file_paths.xml` **apenas** para o fallback `ACTION_VIEW`.
- Registro único do canal no `MainActivity.configureFlutterEngine` (correção v1 mantida).

**Verificação manual (TV emulador):**
- update da v antiga → confirmação do SO → instala por cima → dados (perfis/favoritos/histórico/progresso/settings/token) **verificados um a um**;
- `adb install` com outra chave → erro "chave divergente" sem sugerir desinstalar;
- unknown sources off → instrução correta; fallback `ACTION_VIEW` funciona;
- processo morto no meio: `BroadcastReceiver` behavior → app volta ou mensagem "reabra".

### Fase 5 — UI TV (herda v1)

- `update_available_dialog.dart`, `update_progress_dialog.dart` (indeterminado + erro por causa), hook na Home pós-frame, Configurações (toggle + "Verificar agora").
- Diálogo "Instalação concluída — reabra o app" quando aplicável.

### Fase 6 — Integridade de dados do usuário (NOVO — o coração desta revisão)

1. `ProfileStore`: escrita atômica (`.tmp` + `rename`) e `.bak` de geração anterior (Seção 3.4).
2. Gravar/ler `schema` nos JSONs; **em qualquer mudança de formato futuro**, bump + migração no mesmo PR; parse-failure deixa de apagar dados (tenta `.bak`, loga, preserva arquivo) (Seção 3.3).
3. `UpdateService.flushData()` chamada antes de todo `installApk` (I-6); `SharedPreferences` flush incluso.
4. (Opcional, recomendado) export de dados via AniList como rede de segurança na política de chave (Fase 0-B).
5. Teste fim-a-fim de dados: instalar vN com dados semeados (perfis, favoritos, progresso, settings, token simulado) → atualizar para vN+1 → **confirmar que a nova versão LÊ e renderiza os dados**, não só que os bytes continuam lá.

**Verificação:** teste unitário do write-atômico (kill simulado → arquivo intacto ou `.bak`); teste de migração de schema; checklist manual da seção "Dados" de Fase 4.

### Fase 7 — Pipeline de release CI (v1 corrigida)

1. Workflow em tag `v*`: `flutter build apk --release` **assinado com a keystore de release via secrets do GitHub** (Fase 0-B) — sem isso o APK do CI sai debug e quebra o update (correção do gap nº 9).
2. **Guarda de versionamento:** o fluxo falha (dry-run) se o `buildNumber` (parte `+N` do `pubspec.yaml`) da tag não for **estritamente maior** que o da última tag no repo — protege a regra D2.
3. Publicar release com asset `goanime-tv-<tag>.apk`, changelog = title/body; opcionalmente `sha256` no body (usado pelo D5-a).
4. Teste fim a fim: device v1.0.0+1000000 → publicar `v1.0.1+1000001` via workflow → TV atualiza e **dados preservados/legíveis**.

---

## 8. Riscos e pontos de atenção (v2)

| Risco | Impacto | Mitigação |
|---|---|---|
| Trocar de chave sem migração | **Todos atualizáveis viram não-atualizáveis; dados só via desinstalar** | Fase 0 decide A/B; autopreservation I-3 com aviso + backup |
| Formato de dados novo ilegível pela versão nova | Favoritos/histórico/progresso **soomem da UI** com arquivos intactos | schema version + migração; nunca vazio-silencioso (I-4) |
| Escrita corrompida na janela do commit | Arquivo truncado → dados perdidos | escrita atômica + `.bak` + `flushData()` antes do install (I-5/I-6) |
| `releases/latest` docs-only | Updates futuros parados | fallback a `/releases` (D1) |
| Rate limit / rede / 429 | Check falha e trava 24h | throttle só em sucesso; erro = silencioso, tenta no boot |
| APK corrompido/adulterado | Falha opaca no instalador / binário suspeito | digest check before install (D5-a) |
| Espaço em disco insuficiente | Download falha no meio | pre-flight de espaço + mensagem clara |
| Double-trigger de UI | Duplos diálogos/downloads | guarda `state != idle` no `check()` |
| CI assina com chave errada | Signature mismatch em produção | keystore via secrets + teste de instalação no CI |
| Processo morto após commit | "Update sumiu", usuário não sabe que instalou | BroadcastReceiver best-effort / mensagem "reabra o app" |

---

## 9. Testes (v2)

**Unitários:** `version_compare_test` (v1 + "mesmo build"), `github_release_api_test` (agora: latest docs-only, fallback, 429 não grava throttle, digest parse), `update_service_test` (guarda de concorrência, throttle só-sucesso, ignore persiste), **`profile_store_data_test`** (atômico, `.bak` recuperação, migração de schema, parse-failure preserva arquivo).

**Widget:** diálogos (v1) + erro diferenciado.

**Manual TV (checklist QA — ampliado da v1):**
1. Fresh install v1.0.0 → sem check antes da Home.
2. Update disponível → diálogo não trava.
3. Download → cancelar → arquivo removido; órfãos antigos limpos no boot.
4. **Preservação de dados (obrigatório, item expandido):** após update, conferir **todos** — perfis, favoritos, histórico, progresso por episódio, settings, sessão AniList, provider match — e que a **nova versão renderiza** cada um.
5. VersionCode menor / build igual → não atualiza.
6. Release docs-only → atualiza via fallback (release anterior com APK).
7. Digest divergente → aborta antes de instalar.

---

## 10. Escopo fora desta v1 (YAGNI — herdado e ajustado)

- Resume de download interrompido (mantém apagar-parcial).
- Canal de distribuição múltiplo (Play Store + GitHub).
- Force update / atualização 100% silenciosa.
- Delta/patch de APK.
- Suporte a canais alpha/beta seletivos (prerelease já ignorado).
- **Export completo de dados** — **não mais "adiado por padrão"**: vira requisito **se** a Fase 0 escolher trocar de chave (única forma de honrar I-3 sem perda).
- Rollback de versão ruim dentro do app (release ruim vira a próxima correção; N sempre crescente — documentar para usuários).

---

## 11. Processo de release (referência)

```
1. Bump: pubspec.yaml version: X.Y.Z+N  (N ESTRITAMENTE crescente — sem "ímpar/par")
2. flutter test && flutter analyze   (obrigatório: teste de dados da Fase 6)
3. git tag vX.Y.Z+N && git push      → CI:
   - verifica N > última tag (guarda D2)
   - build apk --release assinado com keystore de release (secrets)
   - grita se sha256/changelog ausentes
4. Release title/body = changelog (vira o texto do diálogo)
   Asset: goanime-tv-vX.Y.Z+N.apk   (+ sha256 no body)
5. Se não reconhecida já instalada (troca de chave em hom - cap Fase 0): publish aviso + passo de backup na mesma release
6. TVs: checagem automática no próximo boot / "Verificar agora"
```

---

## 12. Aprovação

PRs de cada fase precisam declarar **qual invariável (seção 2) protege** e qual teste a comprova. Nenhum PR de update é aceito sem o teste de preservação/releitura de dados (Fase 6).