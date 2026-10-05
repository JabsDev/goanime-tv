import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/device/device_type.dart';
import '../../core/storage/settings_service.dart';
import '../../core/subtitles/legendai/legendai_connection.dart';
import '../../core/subtitles/legendai/legendai_pairing.dart';
import '../../shared/widgets/app_top_bar.dart';
import '../../shared/widgets/tv_button.dart';
import 'legendai_qr_scan_screen.dart';

/// Tela de pareamento com o LegendAI (Fase 3: IP manual; Fase 4: QR).
///
/// No celular, o botão "Ler QR code" abre a câmera e preenche o endereço; no
/// Android TV (sem câmera) o botão é escondido e resta a digitação manual.
class LegendAiPairScreen extends StatefulWidget {
  const LegendAiPairScreen({super.key});

  @override
  State<LegendAiPairScreen> createState() => _LegendAiPairScreenState();
}

class _LegendAiPairScreenState extends State<LegendAiPairScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  bool _busy = false;
  bool _isTv = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: SettingsService.instance.legendAiHost);
    _port = TextEditingController(
      text: SettingsService.instance.legendAiPort.toString(),
    );
    // TV não tem câmera: esconde o botão de QR (fallback: digitação manual).
    DeviceType.isTelevision().then((v) {
      if (mounted && v) setState(() => _isTv = true);
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  int _parsePort() =>
      int.tryParse(_port.text.trim()) ?? SettingsService.instance.legendAiPort;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Bloqueia IP público literal (o LegendAI é LAN sem auth). Retorna `true`
  /// se pode prosseguir.
  bool _guardPrivateHost() {
    final host = _host.text.trim();
    if (host.isEmpty) return true; // deixa o fluxo normal mostrar "sem endereço"
    if (isPrivateLanHost(host)) return true;
    _snack(
      'Esse endereço parece ser um IP público. O LegendAI deve estar na sua '
      'rede local (ex.: 192.168.x.y).',
    );
    return false;
  }

  Future<void> _test() async {
    if (!_guardPrivateHost()) return;
    setState(() => _busy = true);
    final ok = await LegendAiConnection.instance.test(
      host: _host.text,
      port: _parsePort(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    final c = LegendAiConnection.instance;
    _snack(
      ok
          ? 'PC conectado${c.healthLabel.isEmpty ? '' : ' · ${c.healthLabel}'}'
          : 'Não foi possível conectar. Confira o IP/porta e se o LegendAI está aberto.',
    );
  }

  Future<void> _connect() async {
    if (!_guardPrivateHost()) return;
    setState(() => _busy = true);
    final ok = await LegendAiConnection.instance.saveAndConnect(
      host: _host.text,
      port: _parsePort(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      ok ? 'Conectado e salvo.' : 'Endereço salvo, mas o PC não respondeu.',
    );
  }

  Future<void> _disconnect() async {
    await LegendAiConnection.instance.disconnect();
    if (!mounted) return;
    setState(() {
      _host.text = '';
      _port.text = '8765';
    });
    _snack('Desconectado.');
  }

  /// Abre a câmera, lê o QR e já conecta com o endereço lido.
  Future<void> _scanQr() async {
    final address = await Navigator.push<LegendAiAddress>(
      context,
      MaterialPageRoute(builder: (_) => const LegendAiQrScanScreen()),
    );
    if (!mounted || address == null) return;
    setState(() {
      _host.text = address.host;
      _port.text = address.port.toString();
    });
    _snack('QR lido: ${address.host}:${address.port}. Conectando…');
    await _connect();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          AppTopBar(
            title: 'LegendAI (PC)',
            icon: Icons.dns_outlined,
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
              children: [
                const Text(
                  'Gerar legenda no PC',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: ThemeConstants.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Abra o LegendAI no PC, veja o endereço na aba "Rede" e '
                  'informe abaixo. O PC baixa o stream, transcreve com Whisper '
                  'e traduz — o aparelho só recebe o SRT pronto.',
                  style: TextStyle(
                    fontSize: 16,
                    color: ThemeConstants.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                _FieldLabel('Endereço do PC (IP ou nome, ex.: 192.168.2.109)'),
                TextField(
                  controller: _host,
                  style: const TextStyle(color: ThemeConstants.white),
                  keyboardType: TextInputType.url,
                  decoration: _decoration('192.168.2.109'),
                ),
                const SizedBox(height: 16),
                _FieldLabel('Porta'),
                TextField(
                  controller: _port,
                  style: const TextStyle(color: ThemeConstants.white),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _decoration('8765'),
                ),
                const SizedBox(height: 20),
                ValueListenableBuilder<LegendAiStatus>(
                  valueListenable: LegendAiConnection.instance.status,
                  builder: (context, status, _) => _StatusLine(
                    status: status,
                    label: LegendAiConnection.instance.healthLabel,
                    version: LegendAiConnection.instance.health?.version ?? '',
                  ),
                ),
                const SizedBox(height: 20),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.white24,
                      valueColor: AlwaysStoppedAnimation(
                        ThemeConstants.primary,
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (!_isTv)
                      TVButton(
                        label: 'Ler QR code',
                        icon: Icons.qr_code_scanner,
                        onPressed: _busy ? () {} : _scanQr,
                      ),
                    TVButton(
                      label: 'Testar conexão',
                      isPrimary: false,
                      icon: Icons.wifi_find,
                      onPressed: _busy ? () {} : _test,
                    ),
                    TVButton(
                      label: 'Salvar e conectar',
                      icon: Icons.link,
                      onPressed: _busy ? () {} : _connect,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (SettingsService.instance.legendAiConfigured)
                  TVButton(
                    label: 'Desconectar',
                    isPrimary: false,
                    icon: Icons.link_off,
                    onPressed: _busy ? () {} : _disconnect,
                  ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: ThemeConstants.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: ThemeConstants.surfaceLight),
                  ),
                  child: Text(
                    _isTv
                        ? 'Na TV (sem câmera), digite o endereço mostrado na aba '
                              '"Rede" do PC. No celular, use "Ler QR code".'
                        : 'No celular, toque em "Ler QR code" e aponte para o código '
                              'da aba "Rede" do PC. Também é possível digitar o '
                              'endereço manualmente.',
                    style: const TextStyle(
                      fontSize: 14,
                      color: ThemeConstants.textSecondary,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: ThemeConstants.textMuted),
    filled: true,
    fillColor: ThemeConstants.surface,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: ThemeConstants.surfaceLight),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: ThemeConstants.primary, width: 2),
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, color: ThemeConstants.textSecondary),
    ),
  );
}

class _StatusLine extends StatelessWidget {
  final LegendAiStatus status;
  final String label;
  final String version;
  const _StatusLine({
    required this.status,
    required this.label,
    required this.version,
  });

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (status) {
      LegendAiStatus.online => (
        Colors.greenAccent,
        'PC conectado${label.isEmpty ? '' : ' · $label'}'
            '${version.isEmpty ? '' : ' · v$version'}',
      ),
      LegendAiStatus.checking => (Colors.orangeAccent, 'Conectando…'),
      LegendAiStatus.offline => (Colors.redAccent, 'PC não respondeu'),
      LegendAiStatus.unconfigured => (
        ThemeConstants.textSecondary,
        'Nenhum PC configurado',
      ),
    };
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 15)),
        ),
      ],
    );
  }
}
