import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QRCodeScannerScreen extends StatefulWidget {
  final String qrUrl;
  final Future<void> Function(String) onTokenCaptured;

  const QRCodeScannerScreen({
    required this.qrUrl,
    required this.onTokenCaptured,
  });

  @override
  State<QRCodeScannerScreen> createState() => _QRCodeScannerScreenState();
}

class _QRCodeScannerScreenState extends State<QRCodeScannerScreen> {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  final MobileScannerController controller = MobileScannerController();
  bool _isScanning = true;

  @override
  void initState() {
    super.initState();
    // B8: reage ao estado do scanner. No emulador Android TV não há câmera
    // virtual e o MobileScanner falha ao inicializar — sem isso a tela fica
    // presa na instrução estática com a área de scan preta.
    controller.addListener(_onScannerState);
  }

  void _onScannerState() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_onScannerState);
    controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (capture.barcodes.isNotEmpty) {
      final code = capture.barcodes.first.rawValue;
      if (code != null) {
        _handleScan(code);
      }
    }
  }

  void _handleScan(String code) {
    controller.stop();
    setState(() {
      _isScanning = false;
    });

    if (code.contains('access_token')) {
      widget.onTokenCaptured(code);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('URL inválida. Use o QR Code da TV!'),
          duration: const Duration(seconds: 3),
        ),
      );
      setState(() {
        _isScanning = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cameraError = controller.value.error;
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background.withValues(alpha: 1.0),
      appBar: AppBar(
        title: const Text('Escanear QR Code'),
        backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 1.0),
      ),
      body: cameraError != null
          ? _buildCameraError(cameraError)
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      MobileScanner(
                        key: qrKey,
                        controller: controller,
                        onDetect: _onDetect,
                      ),
                      if (_isScanning)
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 300,
                                height: 300,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.2),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    'Escaneie o QR Code\nna TV',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 1.0),
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Como escanear:',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 1.0),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    const Text('1. Abra a câmera do celular'),
                                    const Text('2. Aponte para o QR Code na TV'),
                                    const Text('3. Aprovar o login no celular'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (!_isScanning)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _isScanning = true;
                        });
                        controller.start();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Voltar'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// B8: fallback legível quando a câmera não inicializa (ex.: emulador Android
  /// TV), em vez de uma área de scan preta/estática que parece travada.
  Widget _buildCameraError(MobileScannerException error) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Câmera indisponível neste dispositivo',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Não foi possível abrir a câmera (comum em emuladores de Android TV). '
              'Use a opção "Inserir token" manualmente para conectar o AniList.',
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Semantics(
              button: true,
              child: Material(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    child: Text(
                      'Voltar',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
