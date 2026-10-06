import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/legendai/legendai_pairing.dart';

void main() {
  group('parseLegendAiQr', () {
    test('URL http com porta', () {
      final a = parseLegendAiQr('http://192.168.2.109:8765');
      expect(a, const LegendAiAddress('192.168.2.109', 8765));
    });

    test('URL http sem porta usa a default', () {
      final a = parseLegendAiQr('http://192.168.2.109');
      expect(a, const LegendAiAddress('192.168.2.109', kLegendAiDefaultPort));
    });

    test('URL https também é aceita', () {
      final a = parseLegendAiQr('https://pc-jabs.local:9000/');
      expect(a, const LegendAiAddress('pc-jabs.local', 9000));
    });

    test('esquema legendai://v1/pair com host e porta', () {
      final a = parseLegendAiQr(
        'legendai://v1/pair?host=192.168.2.109&port=8765',
      );
      expect(a, const LegendAiAddress('192.168.2.109', 8765));
    });

    test('esquema legendai:// sem porta usa a default', () {
      final a = parseLegendAiQr('legendai://v1/pair?host=10.0.0.5');
      expect(a, const LegendAiAddress('10.0.0.5', kLegendAiDefaultPort));
    });

    test('host:porta cru', () {
      final a = parseLegendAiQr('192.168.0.42:8765');
      expect(a, const LegendAiAddress('192.168.0.42', 8765));
    });

    test('host cru usa a default', () {
      final a = parseLegendAiQr('pc-jabs');
      expect(a, const LegendAiAddress('pc-jabs', kLegendAiDefaultPort));
    });

    test('ignora espaços e quebras de linha', () {
      final a = parseLegendAiQr('  http://192.168.1.10:8765\r\nignored  ');
      expect(a, const LegendAiAddress('192.168.1.10', 8765));
    });

    test('porta fora da faixa é rejeitada', () {
      expect(parseLegendAiQr('http://192.168.1.10:70000'), isNull);
      expect(parseLegendAiQr('192.168.1.10:80'), isNull);
    });

    test('vazio e lixo retornam null', () {
      expect(parseLegendAiQr(''), isNull);
      expect(parseLegendAiQr('   '), isNull);
      expect(parseLegendAiQr(':8765'), isNull);
    });
  });

  group('isPrivateLanHost', () {
    test('aceita faixas privadas IPv4', () {
      expect(isPrivateLanHost('10.0.0.1'), isTrue);
      expect(isPrivateLanHost('172.16.0.1'), isTrue);
      expect(isPrivateLanHost('172.31.255.254'), isTrue);
      expect(isPrivateLanHost('192.168.2.109'), isTrue);
      expect(isPrivateLanHost('127.0.0.1'), isTrue);
      expect(isPrivateLanHost('localhost'), isTrue);
      expect(isPrivateLanHost('pc-jabs.local'), isTrue);
    });

    test('aceita a faixa CGNAT do Tailscale (100.64.0.0/10)', () {
      // O roteador pode isolar Ethernet de Wi-Fi; a VPN overlay (Tailscale)
      // resolve, e o app precisa aceitar o IP 100.x do tailnet.
      expect(isPrivateLanHost('100.64.0.1'), isTrue);
      expect(isPrivateLanHost('100.101.102.103'), isTrue);
      expect(isPrivateLanHost('100.127.255.254'), isTrue);
      // Bordas fora da faixa continuam rejeitadas.
      expect(isPrivateLanHost('100.63.0.1'), isFalse);
      expect(isPrivateLanHost('100.128.0.1'), isFalse);
    });

    test('rejeita IP público literal', () {
      expect(isPrivateLanHost('8.8.8.8'), isFalse);
      expect(isPrivateLanHost('172.32.0.1'), isFalse);
      expect(isPrivateLanHost('200.150.10.1'), isFalse);
    });

    test('hostname (não-IP) é permitido — resolução decide', () {
      expect(isPrivateLanHost('pc-jabs'), isTrue);
      expect(isPrivateLanHost('legendai'), isTrue);
    });

    test('aceita IPv6 unique-local/link-local', () {
      expect(isPrivateLanHost('fd00::1'), isTrue);
      expect(isPrivateLanHost('fe80::1'), isTrue);
    });
  });
}
