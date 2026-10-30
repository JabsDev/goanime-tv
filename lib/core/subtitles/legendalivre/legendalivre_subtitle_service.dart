import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'legendalivre_client.dart';
import 'legendalivre_extract.dart';
import 'video_hash.dart';

enum LegendaLivreStatus {
  found,
  notFound,
  readError,
  listError,
  downloadError,
  saveError,
}

class LegendaLivreResult {
  final LegendaLivreStatus status;
  final String? path;
  final String? movieName;
  final List<LegendaLivreLegend> legends;

  const LegendaLivreResult({
    required this.status,
    this.path,
    this.movieName,
    this.legends = const [],
  });
}

class LegendaLivreSubtitleService {
  final LegendaLivreClient client;
  final http.Client? httpClient;

  LegendaLivreSubtitleService({LegendaLivreClient? client, this.httpClient})
      : client = client ?? LegendaLivreClient();

  Future<LegendaLivreResult> fetchBest({
    required String videoUrl,
    required int langCode,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.tryParse(videoUrl);
    if (uri == null) {
      return const LegendaLivreResult(status: LegendaLivreStatus.readError);
    }

    String hash;
    try {
      hash = await computeRemoteVideoHash(uri, headers: headers, client: httpClient)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return const LegendaLivreResult(status: LegendaLivreStatus.readError);
    }
    if (hash == '0000000000000000') {
      return const LegendaLivreResult(status: LegendaLivreStatus.notFound);
    }

    String? movie;
    try {
      movie = await client.movieName(hash);
    } catch (_) {}

    List<LegendaLivreLegend> legends;
    try {
      legends = await client.listSubtitles(hash: hash, langCode: langCode, best: true);
    } catch (_) {
      return LegendaLivreResult(
        status: LegendaLivreStatus.listError,
        movieName: movie,
      );
    }
    if (legends.isEmpty) {
      // tenta lista normal
      try {
        legends = await client.listSubtitles(hash: hash, langCode: langCode, best: false);
      } catch (_) {
        return LegendaLivreResult(
          status: LegendaLivreStatus.listError,
          movieName: movie,
        );
      }
    }
    if (legends.isEmpty) {
      return LegendaLivreResult(
        status: LegendaLivreStatus.notFound,
        movieName: movie,
      );
    }

    Uint8List zip;
    try {
      zip = await client.downloadZip(legends.first);
    } catch (_) {
      return LegendaLivreResult(
        status: LegendaLivreStatus.downloadError,
        movieName: movie,
        legends: legends,
      );
    }

    final extracted = extractSubtitleFromZip(zip);
    if (extracted == null) {
      return LegendaLivreResult(
        status: LegendaLivreStatus.downloadError,
        movieName: movie,
        legends: legends,
      );
    }

    try {
      final dir = await _cacheDir();
      await dir.create(recursive: true);
      final file = File('${dir.path}/${hash}_$langCode${extracted.extension}');
      await file.writeAsBytes(ensureUtf8(extracted.bytes));
      return LegendaLivreResult(
        status: LegendaLivreStatus.found,
        path: file.path,
        movieName: movie,
        legends: legends,
      );
    } catch (_) {
      return LegendaLivreResult(
        status: LegendaLivreStatus.saveError,
        movieName: movie,
        legends: legends,
      );
    }
  }

  Future<List<LegendaLivreLegend>> listOptions({
    required String videoUrl,
    required int langCode,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.tryParse(videoUrl);
    if (uri == null) return const [];
    String hash;
    try {
      hash = await computeRemoteVideoHash(uri, headers: headers, client: httpClient)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return const [];
    }
    if (hash == '0000000000000000') return const [];
    try {
      return await client.listSubtitles(hash: hash, langCode: langCode, best: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/subs_legendalivre');
  }
}
