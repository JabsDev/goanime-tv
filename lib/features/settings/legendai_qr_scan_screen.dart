import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/subtitles/legendai/legendai_pairing.dart';
import '../../shared/widgets/app_top_bar.dart';

/// Leitor de QR de pareamento do LegendAI (Fase 4).
///
/// Retorna um [LegendAiAddress] via `Navigator.pop` quando lê um QR válido.
/// No Android TV (sem câmera) esta tela não deve ser aberta — a tela de
/// pareamento esconde o botão nesse caso e mantém a digitação manual.
class LegendAiQrScanScreen extends StatefulWidget {
  const LegendAiQrScanScreen({super.key});

  @override
  State<LegendAiQrScanScreen> createState() => _LegendAiQrScanScreenState();
}

class _LegendAiQrScanScreenState extends State<LegendAiQrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _handled = false;
  String? _message;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      final address = parseLegendAiQr(raw);
      if (address != null) {
        _handled = true;
        Navigator.pop(context, address);
        return;
      }
    }
    if (mounted && _message == null) {
      setState(
        () => _message =
            'QR lido, mas não parece um endereço do LegendAI. '
            'Use o QR da aba "Rede" do PC.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          AppTopBar(
            title: 'Ler QR do LegendAI',
            icon: Icons.qr_code_scanner,
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => _CameraError(
                    message: error.errorDetails?.message ?? error.errorCode.name,
                  ),
                ),
                IgnorePointer(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: ThemeConstants.primary,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                if (_message != null)
                  Positioned(
                    bottom: 32,
                    left: 24,
                    right: 24,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _message!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Aponte para o QR que aparece na aba "Rede" do LegendAI.',
              style: TextStyle(color: ThemeConstants.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  final String message;
  const _CameraError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Não foi possível abrir a câmera.',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Digite o endereço manualmente. ($message)',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ThemeConstants.textSecondary,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
