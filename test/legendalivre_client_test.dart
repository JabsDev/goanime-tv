import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/subtitles/legendalivre/legendalivre_client.dart';

String b64(String s) => base64.encode(utf8.encode(s));

void main() {
  test('listSubtitles parseia registros', () async {
    final xml = '<?xml version="1.0"?><subtitles><subtitle>'
        '<name>${b64("Filme.pt-br.srt")}</name>'
        '<id>${b64("123")}</id>'
        '<date>${b64("01-01-2020")}</date>'
        '</subtitle></subtitles>';
    final client = MockClient((req) async {
      expect(req.method, 'POST');
      return http.Response(xml, 200);
    });
    final c = LegendaLivreClient(client: client);
    final list = await c.listSubtitles(hash: 'abc', langCode: 6);
    expect(list.length, 1);
    expect(list.first.name, 'Filme.pt-br.srt');
    expect(list.first.id, '123');
    expect(list.first.date, '01-01-2020');
    c.close();
  });

  test('downloadZip exige zip', () async {
    final client = MockClient((req) async {
      return http.Response.bytes([0x50, 0x4B, 0x03, 0x04, 1, 2, 3], 200);
    });
    final c = LegendaLivreClient(client: client);
    final legend = LegendaLivreLegend(name: 'x', id: '1', date: '01-01-2020');
    final bytes = await c.downloadZip(legend);
    expect(bytes[0], 0x50);
    c.close();
  });

  test('downloadZip rejeita não-zip', () async {
    final client = MockClient((req) async {
      return http.Response('nope', 200);
    });
    final c = LegendaLivreClient(client: client);
    final legend = LegendaLivreLegend(name: 'x', id: '1', date: '01-01-2020');
    expect(() => c.downloadZip(legend), throwsA(isA<StateError>()));
    c.close();
  });
}
