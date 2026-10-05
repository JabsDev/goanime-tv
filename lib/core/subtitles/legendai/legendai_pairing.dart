import 'dart:io';

/// Interpretação do conteúdo de um QR de pareamento do LegendAI (Fase 4).
///
/// O PC mostra `http://<ip>:<porta>` (aba "Rede"). O app aceita, por robustez,
/// quatro formatos comuns — todos apontam para o mesmo endereço:
///
/// - `http://192.168.2.109:8765` (URL do QR do LegendAI)
/// - `legendai://v1/pair?host=192.168.2.109&port=8765` (esquema próprio)
/// - `192.168.2.109:8765`
/// - `192.168.2.109` (usa a porta default [kLegendAiDefaultPort])
///
/// A porta é limitada a 1024–65535 (a mesma faixa aceita pelo servidor).
class LegendAiAddress {
  final String host;
  final int port;

  const LegendAiAddress(this.host, this.port);

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is LegendAiAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Porta default do servidor de rede do LegendAI (espelha `NetConfig`).
const int kLegendAiDefaultPort = 8765;

/// Extrai `{host, port}` de um texto de QR. `null` se não parecer endereço.
LegendAiAddress? parseLegendAiQr(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  // Alguns leitores colam o conteúdo com quebras de linha; pega a 1ª linha.
  text = text.split(RegExp(r'[\r\n]')).first.trim();
  if (text.isEmpty) return null;

  final lower = text.toLowerCase();

  // Esquema próprio: legendai://v1/pair?host=...&port=...
  if (lower.startsWith('legendai://')) {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final host = (uri.queryParameters['host'] ?? uri.host).trim();
    final port = _parsePort(uri.queryParameters['port']) ?? _portFromUri(uri);
    return _build(host, port);
  }

  // URL http(s) completa.
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    return _build(uri.host.trim(), _portFromUri(uri));
  }

  // host:porta (IPv4 ou nome). Um IPv6 puro sem porta não é suportado aqui.
  final colon = text.lastIndexOf(':');
  if (colon > 0 && text.indexOf(':') == colon) {
    final host = text.substring(0, colon).trim();
    final port = _parsePort(text.substring(colon + 1));
    return _build(host, port);
  }

  // Só o host → porta default.
  return _build(text, null);
}

int? _portFromUri(Uri uri) => uri.hasPort ? uri.port : null;

int? _parsePort(String? value) {
  if (value == null) return null;
  final n = int.tryParse(value.trim());
  return n;
}

LegendAiAddress? _build(String host, int? port) {
  if (host.isEmpty) return null;
  // Host de hostname/IP não tem `:`, `/` nem espaços; rejeita lixo que tenha
  // caído no ramo "host cru" (ex.: ":8765", "a/b").
  if (host.contains(RegExp(r'[:\s/]'))) return null;
  final p = port ?? kLegendAiDefaultPort;
  if (p < 1024 || p > 65535) return null;
  return LegendAiAddress(host, p);
}

/// Heurística de segurança (Fase 4): o servidor LegendAI vive na LAN e o
/// protocolo é HTTP sem auth. Se o usuário digitar um IP **público** literal,
/// provavelmente é engano/risco — retorna `false` para a UI alertar.
///
/// Nomes de host (ex.: `pc-jabs`, `pc.local`) retornam `true`: não dá para
/// resolvê-los sem DNS e a política de rede do Android já cobre o caso.
bool isPrivateLanHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.lan')) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return true; // hostname: deixa a resolução de rede decidir
  if (ip.isLoopback || ip.isLinkLocal) return true;
  if (ip.type == InternetAddressType.IPv4) {
    final b = ip.rawAddress;
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true; // link-local (fallback)
    return false;
  }
  // IPv6: fe80::/10 (link-local) e fc00::/7 (unique local).
  final b = ip.rawAddress;
  if (b.isEmpty) return false;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
  if ((b[0] & 0xfe) == 0xfc) return true;
  return false;
}
