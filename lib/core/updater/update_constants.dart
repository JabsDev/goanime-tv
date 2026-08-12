/// Constantes do mecanismo de auto-update.
class UpdateConstants {
  static const String repoSlug = String.fromEnvironment(
      'UPDATE_REPO',
      defaultValue: 'JabsDev/goanime-tv');

  /// Base da API do GitHub. Sobrescrita via `--dart-define` em testes E2E
  /// (emulador aponta para um servidor HTTP local).
  static const String apiBase = String.fromEnvironment(
      'UPDATE_API_BASE',
      defaultValue: 'https://api.github.com');

  /// Semi-passo: não deixar o app checar o GitHub mais de uma vez por dia.
  static const Duration checkInterval = Duration(hours: 24);

  /// Nome da subpasta (em `getExternalFilesDir(null)`) que guarda os APKs
  /// baixados. Estável para o instalador nativo e para o FileProvider
  /// (fallback `ACTION_VIEW`).
  static const String updatesDir = 'updates';

  /// Idade a partir da qual um arquivo parcial em `updates/` é órfão
  /// (processo morto no meio do download) e deve ser apagado no boot.
  static const Duration orphanAge = Duration(hours: 24);

  static String apkFileName(String tag) =>
      'goanime-tv-${tag.replaceAll(RegExp(r'[^A-Za-z0-9.+-]'), '_')}.apk';
}