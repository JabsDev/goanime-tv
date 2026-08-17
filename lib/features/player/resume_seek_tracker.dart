/// Lógica pura de retomada: decide quando confirmar / re-aplicar o seek de
/// retomada após `open()`. Separada do player para ser testável sem media_kit.
///
/// Regras (corrigem o Bug 2):
/// - Amostras de posição ANTES do vídeo ficar pronto não confirmam o seek
///   (o mpv pode reportar o time-pos enfileirado e descartar o seek depois).
/// - A confirmação exige N amostras consecutivas dentro da zona do alvo
///   (pos >= alvo - 5s), só após `markVideoReady`. Uma amostra isolada pode
///   ser o time-pos "fantasma" (Furo 1 residual).
/// - O seek só é re-aplicado com o vídeo pronto, quando a posição real está
///   bem abaixo do alvo (pos <= alvo - 5s) e ainda há tentativas (backoff).
class ResumeSeekTracker {
  ResumeSeekTracker({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const int maxRetries = 3;
  static const Duration retryBackoff = Duration(milliseconds: 1500);
  static const double confirmToleranceSec = 2;
  static const double seekFarBelowSec = 5;
  static const int confirmSamples = 2;

  double _targetSec = 0;
  bool _videoReady = false;
  bool _confirmed = false;
  int _retries = 0;
  int _nearStreak = 0;
  DateTime? _lastSeekAt;

  double get targetSec => _targetSec;
  bool get isArmed => _targetSec > 0 && !_confirmed;
  bool get confirmed => _confirmed;

  /// Inicia a retomada para [targetSec] segundos (chamado após `open()`).
  void arm(double targetSec) {
    _targetSec = targetSec;
    _confirmed = false;
    _videoReady = false;
    _retries = 0;
    _nearStreak = 0;
    _lastSeekAt = null;
  }

  /// Desarma (nova abertura de fonte, novo episódio, ou `_restoreProgress`
  /// sem retomada aplicável).
  void reset() => arm(0);

  /// Chama quando a duração é conhecida e o stream é considerado pronto.
  void markVideoReady() => _videoReady = true;

  /// Evento de posição. Retorna `true` quando um (re-)seek deve ser emitido
  /// neste instante (a UI chama `_player.seek`).
  bool onPosition(double positionSec) {
    if (!isArmed || !_videoReady) return false;
    final acceptable = positionSec > _targetSec - seekFarBelowSec;
    final closeEnough = positionSec >= _targetSec - confirmToleranceSec;
    if (closeEnough || acceptable) {
      // Zona do alvo: acumula amostras. Confirma só com `confirmSamples`
      // consecutivas — evita confirmar com o time-pos enfileirado do mpv.
      _nearStreak++;
      if (_nearStreak >= confirmSamples) {
        _confirmed = true;
      }
      return false;
    }
    _nearStreak = 0;
    if (_retries >= maxRetries) {
      // Desistir: posição abaixo do alvo e tentativas esgotadas.
      _confirmed = true;
      return false;
    }
    final now = _clock();
    if (_lastSeekAt != null && now.difference(_lastSeekAt!) < retryBackoff) {
      return false;
    }
    _lastSeekAt = now;
    _retries++;
    return true;
  }
}
