import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Drop-in replacement for [Image.network] that caches images on disk and in
/// memory, reuses placeholders/error widgets, and avoids re-fetching the same
/// poster/banner across screens (home -> detail -> player).
class CachedImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? fallback;
  final BorderRadius? borderRadius;

  const CachedImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.fallback,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return _fallbackSized();
    }

    final image = CachedNetworkImage(
      imageUrl: url!,
      fit: fit,
      width: width,
      height: height,
      fadeInDuration: const Duration(milliseconds: 200),
      // ponytail: width pode chegar como double.infinity (GridView cells sem
      // LayoutBuilder) — .toInt() em Infinity lança UnsupportedError e crasha
      // a tela de busca. Blinda: só converte quando finite.
      memCacheWidth: (width != null && width!.isFinite && width! > 0)
          ? width!.toInt() * 2
          : null,
      placeholder: (_, _) => fallback ?? const SizedBox.shrink(),
      errorWidget: (_, _, _) => fallback ?? const SizedBox.shrink(),
    );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: image);
    }
    return image;
  }

  Widget _fallbackSized() {
    if (width != null || height != null) {
      return SizedBox(width: width, height: height, child: fallback);
    }
    return fallback ?? const SizedBox.shrink();
  }
}
