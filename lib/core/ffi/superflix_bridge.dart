import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef SearchSuperFlixNative = Int64 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef SearchSuperFlixDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef GetEpisodesNative = Int64 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef GetEpisodesDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef GetStreamNative = Int64 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef GetStreamDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef GetServersNative = Int64 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef GetServersDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef FreeCStringNative = Void Function(Pointer<Utf8>);
typedef FreeCStringDart = void Function(Pointer<Utf8>);

class SuperFlixFFI {
  static SuperFlixFFI? _instance;
  DynamicLibrary? _lib;
  SearchSuperFlixDart? _searchFn;
  GetEpisodesDart? _episodesFn;
  GetStreamDart? _streamFn;
  GetServersDart? _serversFn;
  FreeCStringDart? _freeFn;
  bool _loaded = false;

  SuperFlixFFI._();

  static SuperFlixFFI get instance {
    _instance ??= SuperFlixFFI._();
    return _instance!;
  }

  bool get loaded => _loaded;

  DynamicLibrary? _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libsuperflix.so');
    }
    if (Platform.isLinux) {
      final paths = [
        'go_superflix/superflix.so',
        '../go_superflix/superflix.so',
        'superflix.so',
      ];
      for (final p in paths) {
        try {
          return DynamicLibrary.open(p);
        } catch (_) {}
      }
    }
    return null;
  }

  void load() {
    if (_loaded) return;
    try {
      _lib = _openLibrary();
      if (_lib == null) return;
      _searchFn = _lib!.lookupFunction<SearchSuperFlixNative, SearchSuperFlixDart>('SearchSuperFlix');
      _episodesFn = _lib!.lookupFunction<GetEpisodesNative, GetEpisodesDart>('GetSuperFlixEpisodes');
      _streamFn = _lib!.lookupFunction<GetStreamNative, GetStreamDart>('GetSuperFlixStream');
      _serversFn = _lib!.lookupFunction<GetServersNative, GetServersDart>('GetSuperFlixServers');
      _freeFn = _lib!.lookupFunction<FreeCStringNative, FreeCStringDart>('FreeCString');
      _loaded = true;
      debugPrint('[SuperFlixFFI] Library loaded successfully');
    } catch (e) {
      debugPrint('[SuperFlixFFI] Load error: $e');
      _loaded = false;
    }
  }

  List<Map<String, dynamic>>? search(String query) {
    if (!_loaded) return null;
    final qPtr = query.toNativeUtf8(allocator: malloc);
    final resultPtr = malloc<Pointer<Utf8>>();
    resultPtr.value = nullptr;
    try {
      final code = _searchFn!(qPtr, resultPtr);
      final resultStr = resultPtr.value.toDartString();
      if (code != 0) {
        debugPrint('[SuperFlixFFI] Search error: $resultStr');
        return null;
      }
      final json = jsonDecode(resultStr);
      if (json is! List) return null;
      return json.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[SuperFlixFFI] Search parse error: $e');
      return null;
    } finally {
      if (resultPtr.value != nullptr) _freeFn!(resultPtr.value);
      malloc.free(resultPtr);
      malloc.free(qPtr);
    }
  }

  Map<String, dynamic>? getEpisodes(String tmdbId) {
    if (!_loaded) return null;
    final idPtr = tmdbId.toNativeUtf8(allocator: malloc);
    final resultPtr = malloc<Pointer<Utf8>>();
    resultPtr.value = nullptr;
    try {
      final code = _episodesFn!(idPtr, resultPtr);
      final resultStr = resultPtr.value.toDartString();
      if (code != 0) {
        debugPrint('[SuperFlixFFI] Episodes error: $resultStr');
        return null;
      }
      return jsonDecode(resultStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[SuperFlixFFI] Episodes parse error: $e');
      return null;
    } finally {
      if (resultPtr.value != nullptr) _freeFn!(resultPtr.value);
      malloc.free(resultPtr);
      malloc.free(idPtr);
    }
  }

  Map<String, dynamic>? getStream(String tmdbId, String season, String episode) {
    if (!_loaded) return null;
    final idPtr = tmdbId.toNativeUtf8(allocator: malloc);
    final seasonPtr = season.toNativeUtf8(allocator: malloc);
    final epPtr = episode.toNativeUtf8(allocator: malloc);
    final resultPtr = malloc<Pointer<Utf8>>();
    resultPtr.value = nullptr;
    try {
      final code = _streamFn!(idPtr, seasonPtr, epPtr, resultPtr);
      final resultStr = resultPtr.value.toDartString();
      if (code != 0) {
        debugPrint('[SuperFlixFFI] Stream error: $resultStr');
        return null;
      }
      return jsonDecode(resultStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[SuperFlixFFI] Stream parse error: $e');
      return null;
    } finally {
      if (resultPtr.value != nullptr) _freeFn!(resultPtr.value);
      malloc.free(resultPtr);
      malloc.free(epPtr);
      malloc.free(seasonPtr);
      malloc.free(idPtr);
    }
  }

  /// Returns every streaming server for an episode as a list of
  /// `{streamUrl, referer, name}` maps, so the UI can offer a source list.
  List<Map<String, dynamic>>? getServers(
    String tmdbId,
    String season,
    String episode,
  ) {
    if (!_loaded || _serversFn == null) return null;
    final idPtr = tmdbId.toNativeUtf8(allocator: malloc);
    final seasonPtr = season.toNativeUtf8(allocator: malloc);
    final epPtr = episode.toNativeUtf8(allocator: malloc);
    final resultPtr = malloc<Pointer<Utf8>>();
    resultPtr.value = nullptr;
    try {
      final code = _serversFn!(idPtr, seasonPtr, epPtr, resultPtr);
      final resultStr = resultPtr.value.toDartString();
      if (code != 0) {
        debugPrint('[SuperFlixFFI] Servers error: $resultStr');
        return null;
      }
      final json = jsonDecode(resultStr);
      if (json is List) return json.cast<Map<String, dynamic>>();
      return null;
    } catch (e) {
      debugPrint('[SuperFlixFFI] Servers parse error: $e');
      return null;
    } finally {
      if (resultPtr.value != nullptr) _freeFn!(resultPtr.value);
      malloc.free(resultPtr);
      malloc.free(epPtr);
      malloc.free(seasonPtr);
      malloc.free(idPtr);
    }
  }
}
