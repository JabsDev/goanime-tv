import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/profile/profile_service.dart';
import '../../core/storage/settings_service.dart';
import '../../data/models/profile.dart';
import '../../features/home/anilist_login_dialog.dart';
import '../../features/home/home_screen.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/tv_button.dart';
import 'widgets/profile_avatar.dart';

class ProfileSwitcherScreen extends StatefulWidget {
  final bool showOnBoot;

  const ProfileSwitcherScreen({super.key, this.showOnBoot = false});

  @override
  State<ProfileSwitcherScreen> createState() => _ProfileSwitcherScreenState();
}

class _ProfileSwitcherScreenState extends State<ProfileSwitcherScreen> {
  @override
  void initState() {
    super.initState();
    ProfileService.instance.profilesListenable.addListener(_onChanged);
  }

  @override
  void dispose() {
    ProfileService.instance.profilesListenable.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ProfileService.instance.profiles;
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 40),
                    child: Text(
                      'Quem está assistindo?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 32,
                    runSpacing: 32,
                    children: [
                      for (final p in profiles)
                        _ProfileCard(
                          profile: p,
                          onTap: () => _selectProfile(p.id),
                          onLongPress: () => _confirmDelete(p),
                        ),
                      _AddProfileCard(onTap: _showAddOptions),
                    ],
                  ),
                ],
              ),
            ),
            if (!widget.showOnBoot)
              Positioned(
                top: 16,
                left: 16,
                child: _BackButton(onTap: () => Navigator.pop(context, false)),
              ),
          ],
        ),
      ),
    );
  }

  void _selectProfile(String id) async {
    await ProfileService.instance.switchProfile(id);
    if (!mounted) return;
    _enterHome();
  }

  void _enterHome() {
    if (widget.showOnBoot) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      Navigator.pop(context, true);
    }
  }

  void _confirmDelete(Profile p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeConstants.surface,
        title: Text('Remover "${p.displayName}"?',
            style: const TextStyle(color: Colors.white)),
        content: Text(
          p.isAnilist
              ? 'Isto vai apagar o perfil e todos os dados locais associados '
                  '(histórico, favoritos, progresso). O token AniList será '
                  'descartado deste dispositivo.'
              : 'Isto vai apagar o perfil e todos os dados locais associados '
                  '(histórico, favoritos, progresso).',
          style: const TextStyle(color: ThemeConstants.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar',
                style: TextStyle(color: ThemeConstants.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remover',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ProfileService.instance.deleteProfile(p.id);
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ThemeConstants.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Adicionar conta',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TVButton(
                  label: 'Conta local',
                  icon: Icons.person_outline,
                  isPrimary: false,
                  width: 220,
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showCreateLocal();
                  },
                ),
                TVButton(
                  label: 'Conta AniList',
                  icon: Icons.bookmark_outline,
                  isPrimary: true,
                  width: 220,
                  onPressed: () {
                    Navigator.pop(ctx);
                    _startAnilistLogin();
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showCreateLocal() {
    final controller = TextEditingController();
    String preview = '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: ThemeConstants.surface,
          title: const Text('Nova conta local',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProfileAvatar(
                profile: Profile(
                  id: '_preview',
                  displayName: preview.isEmpty ? ' ' : preview,
                  type: ProfileType.local,
                  createdAt: DateTime.now(),
                ),
                radius: 40,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 24,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                decoration: const InputDecoration(
                  hintText: 'Nome do perfil',
                  hintStyle: TextStyle(color: ThemeConstants.textSecondary),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: ThemeConstants.primary),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: ThemeConstants.primary),
                  ),
                ),
                onChanged: (v) => setState(() => preview = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar',
                  style: TextStyle(color: ThemeConstants.textSecondary)),
            ),
            TextButton(
              onPressed: preview.trim().isEmpty
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _createLocal(preview.trim());
                    },
              child: const Text('Criar',
                  style: TextStyle(color: ThemeConstants.primary)),
            ),
          ],
        ),
      ),
    );
  }

  void _createLocal(String name) async {
    final p = ProfileService.instance.createLocalProfile(name);
    await ProfileService.instance.switchProfile(p.id);
    if (!mounted) return;
    _enterHome();
  }

  void _startAnilistLogin() async {
    // Cria perfil placeholder, switcha pra ele, abre dialog existente.
    // On success: saveToken escreve no perfil atual (popula token+user).
    // On fail: remove placeholder e volta ao perfil anterior.
    final previousId = ProfileService.instance.currentProfile?.id;
    final placeholder =
        ProfileService.instance.createLocalProfile('__anilist_pending__');
    await ProfileService.instance.switchProfile(placeholder.id);
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const AnilistLoginDialog(),
    );
    if (!mounted) return;

    if (ok == true) {
      _enterHome();
    } else {
      await ProfileService.instance.deleteProfile(placeholder.id);
      if (previousId != null) {
        await ProfileService.instance.switchProfile(previousId);
      }
    }
  }
}

class _ProfileCard extends StatefulWidget {
  final Profile profile;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ProfileCard({
    required this.profile,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) =>
          FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onHover: (_) {},
            child: AnimatedScale(
              scale: _isFocused ? 1.08 : 1.0,
              duration: s.animDuration,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isFocused
                            ? ThemeConstants.primary
                            : Colors.transparent,
                        width: ThemeConstants.focusBorderWidth,
                      ),
                      boxShadow: (_isFocused && s.shadowsEnabled)
                          ? [
                              BoxShadow(
                                color: ThemeConstants.primary
                                    .withValues(alpha: 0.5),
                                blurRadius: 18,
                                spreadRadius: 1,
                              ),
                            ]
                          : [],
                    ),
                    padding: const EdgeInsets.all(4),
                    child: ProfileAvatar(
                      profile: widget.profile,
                      radius: 56,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.profile.displayName,
                    style: TextStyle(
                      color: _isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.profile.isAnilist)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        'AniList',
                        style: TextStyle(
                          color: ThemeConstants.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddProfileCard extends StatefulWidget {
  final VoidCallback onTap;

  const _AddProfileCard({required this.onTap});

  @override
  State<_AddProfileCard> createState() => _AddProfileCardState();
}

class _AddProfileCardState extends State<_AddProfileCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) =>
          FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (_) {},
            child: AnimatedScale(
              scale: _isFocused ? 1.08 : 1.0,
              duration: s.animDuration,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isFocused
                            ? ThemeConstants.primary
                            : ThemeConstants.textSecondary,
                        width: ThemeConstants.focusBorderWidth,
                      ),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: CircleAvatar(
                      radius: 56,
                      backgroundColor: ThemeConstants.surface,
                      child: Icon(
                        Icons.add,
                        size: 56,
                        color: _isFocused
                            ? ThemeConstants.primary
                            : ThemeConstants.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Adicionar perfil',
                    style: TextStyle(
                      color: _isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.textSecondary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _isFocused = false;
  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) =>
          FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : Colors.transparent,
                ),
              ),
              child: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
