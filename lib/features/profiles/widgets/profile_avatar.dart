import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../core/constants/theme_constants.dart';
import '../../../data/models/profile.dart';

class ProfileAvatar extends StatelessWidget {
  final Profile profile;
  final double radius;
  final bool focused;

  const ProfileAvatar({
    super.key,
    required this.profile,
    this.radius = 48,
    this.focused = false,
  });

  @override
  Widget build(BuildContext context) {
    final url = profile.anilistAvatar;
    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: ThemeConstants.surface,
        backgroundImage: CachedNetworkImageProvider(url),
      );
    }
    final initial = profile.displayName.isEmpty
        ? '?'
        : profile.displayName[0].toUpperCase();
    final color = _colorFor(profile.displayName);
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // ponytail: hash do nome → cor primária Material. Determinístico, zero assets.
  static Color _colorFor(String name) {
    if (name.isEmpty) return ThemeConstants.primaryDark;
    final hash = name.hashCode.abs();
    return Colors.primaries[hash % Colors.primaries.length];
  }
}
