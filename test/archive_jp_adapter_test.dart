import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/archive_jp_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Fixtures do archive.org capturadas ao vivo em 10/10/2026.
/// O adapter foi generalizado: antes era um caso hardcoded (Haibane),
/// agora busca o acervo inteiro via `advancedsearch` + `metadata`.
void main() {
  String fx(String name) => File('test/fixtures/$name').readAsStringSync();

  group('ArchiveJpAdapter parse — busca', () {
    test('extrai itens do advancedsearch', () {
      final list = ArchiveJpAdapter.parseSearch(fx('ia_search.json'));
      expect(list, isNotEmpty);
      final hit = list.first;
      expect(hit.source, AnimeSource.archiveJp);
      expect(hit.url, startsWith('https://archive.org/details/'));
    });

    test('descarta espelhos de YouTube/Twitch (lixo do índice)', () {
      final body = jsonEncode({
        'response': {
          'numFound': 3,
          'docs': [
            {'identifier': 'youtube-abc123', 'title': 'reaction'},
            {'identifier': 'TwitchVod-999', 'title': 'vod'},
            {'identifier': 'real_item', 'title': 'Um Filme Real', 'year': 1999},
          ],
        }
      });
      final list = ArchiveJpAdapter.parseSearch(body);
      expect(list, hasLength(1));
      expect(list.single.name, 'Um Filme Real (1999)');
      expect(list.single.url,
          'https://archive.org/details/real_item');
    });

    test('payload com errors devolve lista vazia, não estoura', () {
      expect(ArchiveJpAdapter.parseSearch('{"errors":[{"message":"x"}]}'), isEmpty);
      expect(ArchiveJpAdapter.parseSearch('lixo nao json'), isEmpty);
    });
  });

  group('ArchiveJpAdapter parse — arquivos do item', () {
    test('pega só vídeo e ordena por formato/tamanho', () {
      final files = ArchiveJpAdapter.pickVideoFiles(fx('ia_meta.json'));
      expect(files, isNotEmpty);
      // h.264 vem antes de Matroska.
      expect(files.first, contains('.mp4'));
    });

    test('ignora derivados que não são vídeo', () {
      final body = jsonEncode({
        'files': [
          {'name': 'item_meta.xml', 'format': 'Metadata', 'size': '100'},
          {'name': '__ia_thumb.jpg', 'format': 'JPEG', 'size': '9000'},
          {'name': 'readme.txt', 'format': 'Text', 'size': '50'},
          {'name': 'ep01.mp4', 'format': 'h.264', 'size': '1000'},
        ]
      });
      final files = ArchiveJpAdapter.pickVideoFiles(body);
      expect(files, ['ep01.mp4']);
    });

    test('descarta derivados do player (_512kb/_meta)', () {
      final body = jsonEncode({
        'files': [
          {'name': 'show_512kb.mp4', 'format': 'h.264', 'size': '100'},
          {'name': 'show_meta.mp4', 'format': 'h.264', 'size': '100'},
          {'name': 'show.mp4', 'format': 'h.264', 'size': '100'},
        ]
      });
      expect(ArchiveJpAdapter.pickVideoFiles(body), ['show.mp4']);
    });

    test('filtra por nome quando pedido, h.264 na frente do mkv', () {
      final files =
          ArchiveJpAdapter.pickVideoFiles(fx('ia_meta.json'), contains: 'S01E01');
      // Mesmo episódio em dois formatos: o h.264 tem de vir primeiro — é
      // o que `getEpisodes` mantém ao deduplicar pelo número.
      expect(files, isNotEmpty);
      expect(files.first, endsWith('.mp4'));
      expect(files.every((f) => f.contains('S01E01')), isTrue);
    });
  });

  group('ArchiveJpAdapter — numeração/URL', () {
    test('número de episódio sai de S01E07', () {
      expect(ArchiveJpAdapter.identifierOf(
          'https://archive.org/details/haibane-renmei_202606'), 'haibane-renmei_202606');
    });

    test('URL de download escapa espaço e mantém barra', () {
      expect(
        ArchiveJpAdapter.downloadUrl('abc', 'Haibane Renmei - S01E01.mp4'),
        'https://archive.org/download/abc/Haibane%20Renmei%20-%20S01E01.mp4',
      );
    });

    test('qualidade vem do nome do arquivo', () {
      expect(ArchiveJpAdapter.qualityOf('ep_1080p.mp4'), '1080p');
      expect(ArchiveJpAdapter.qualityOf('ep_512kb.mp4'), '512kb');
      expect(ArchiveJpAdapter.qualityOf('episodio.mp4'), 'Auto');
    });

    test('getVideoSources entrega o MP4 direto (sem HLS no archive)', () async {
      final adapter = ArchiveJpAdapter();
      final res = await adapter.getVideoSources(
          Episode(number: '1', url: 'https://archive.org/download/x/ep_720p.mp4'));
      final vs = (res as Success<List<VideoSource>>).data;
      expect(vs.single.url, 'https://archive.org/download/x/ep_720p.mp4');
      expect(vs.single.quality, '720p');
      // Arquivo cru: entra no workflow de legenda IA (sem track embutida).
      expect(vs.single.subtitleCandidates, isEmpty);
    });

    test('getEpisodes monta a grade a partir do /metadata', () async {
      final adapter = ArchiveJpAdapter();
      final res = await adapter.getEpisodes(Anime(
        name: 'Haibane Renmei',
        url: 'https://archive.org/details/haibane-renmei_202606',
        source: AnimeSource.archiveJp,
      ));
      final eps = (res as Success<List<Episode>>).data;
      expect(eps, isNotEmpty);
      expect(eps.first.url, startsWith('https://archive.org/download/'));
      expect(eps.every((e) => e.source == AnimeSource.archiveJp), isTrue);
      // ordenados
      final nums = eps.map((e) => int.parse(e.number)).toList();
      final sorted = [...nums]..sort();
      expect(nums, sorted);
    });
  });
}