import 'dart:async';
import 'package:flutter/services.dart';
import 'audio_service.dart';
import 'foreground_service.dart';

/// =============================================================================
/// cobalt_overlay_service.dart
/// =============================================================================
/// Coordonne l'overlay natif Cobalt (bulle vocale par-dessus toute app)
/// avec l'enregistrement audio et le polling d'amplitude.
///
/// Flow:
///   showOverlay() → natif overlay → startRecording() → poll amplitude
///   User tape → onOverlayDismissed → stopRecording() → hideOverlay()
///
/// Detection de silence adaptative :
///   - Les premiers polls mesurent le niveau ambiant (bruit de fond / musique)
///   - La voix est detectee quand l'amplitude depasse ambient + marge
///   - Le silence est detecte quand l'amplitude retombe pres du niveau ambiant
/// =============================================================================

class CobaltOverlayService {
  static CobaltOverlayService? _instance;

  static const _channel = MethodChannel('com.cobalt_task/cobalt_overlay');

  final AudioService _audioService = AudioService();
  final CobaltForegroundService _foregroundService = CobaltForegroundService();

  Timer? _amplitudeTimer;
  bool _isOverlayActive = false;
  bool _isPolling = false;

  /// Detection de silence adaptative
  static const int _calibrationTicks = 3;     // 3 premiers polls = calibration ambient
  static const double _voiceMargin = 0.08;    // amplitude au-dessus de l'ambient = voix
  static const double _silenceMargin = 0.04;  // retombe pres de l'ambient = silence
  static const int _silenceTicksRequired = 4;  // 4 x 200ms = 0.8s
  int _pollCount = 0;
  double _ambientSum = 0;
  double _ambientLevel = 0;
  int _silentTicks = 0;
  bool _hasHeardVoice = false;

  final _dismissController = StreamController<void>.broadcast();

  /// Stream emis quand l'overlay est dismiss (pour que HomeScreen reagisse).
  Stream<void> get overlayDismissStream => _dismissController.stream;

  /// Indique si l'overlay est actuellement actif.
  bool get isOverlayActive => _isOverlayActive;

  /// Singleton
  factory CobaltOverlayService() {
    _instance ??= CobaltOverlayService._internal();
    return _instance!;
  }

  CobaltOverlayService._internal() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onOverlayDismissed':
        await _onDismissed();
        break;
    }
  }

  /// Affiche l'overlay et demarre l'enregistrement.
  Future<void> showOverlay() async {
    if (_isOverlayActive) return;

    try {
      await _foregroundService.acquireWakeLock();

      await _channel.invokeMethod('showOverlay');
      _isOverlayActive = true;

      // Reset detection
      _pollCount = 0;
      _ambientSum = 0;
      _ambientLevel = 0;
      _silentTicks = 0;
      _hasHeardVoice = false;

      final success = await _audioService.startRecording();

      if (success) {
        await _foregroundService.updateNotification(
          title: 'Cobalt Task',
          text: 'Parlez, puis appuyez sur le bouton',
          isRecording: true,
        );
        _startAmplitudePolling();
      } else {
        await hideOverlay();
      }
    } catch (e) {
      _isOverlayActive = false;
      try { await _foregroundService.releaseWakeLock(); } catch (_) {}
    }
  }

  /// Masque l'overlay (ne stoppe PAS l'enregistrement).
  Future<void> hideOverlay() async {
    _stopAmplitudePolling();

    try {
      await _channel.invokeMethod('hideOverlay');
    } catch (_) {}

    _isOverlayActive = false;

    try { await _foregroundService.releaseWakeLock(); } catch (_) {}
  }

  /// Appele quand l'utilisateur tape sur l'overlay (dismiss).
  Future<void> _onDismissed() async {
    _stopAmplitudePolling();

    if (_audioService.isRecording) {
      await _audioService.stopRecording();
    }

    await hideOverlay();

    await _foregroundService.updateNotification(
      title: 'Cobalt Task',
      text: 'En \u00e9coute...',
      isRecording: false,
    );

    _dismissController.add(null);
  }

  void _startAmplitudePolling() {
    _amplitudeTimer?.cancel();
    _isPolling = false;
    _amplitudeTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _pollAmplitude(),
    );
  }

  void _stopAmplitudePolling() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    _isPolling = false;
  }

  Future<void> _pollAmplitude() async {
    if (_isPolling) return;
    _isPolling = true;

    try {
      if (!_audioService.isRecording || !_isOverlayActive) {
        _stopAmplitudePolling();
        return;
      }

      final amplitude = await _audioService.getAmplitude();
      final dB = amplitude.current;
      final normalized = ((dB + 60) / 60).clamp(0.0, 1.0);

      // Halo vocal
      _channel.invokeMethod('updateAmplitude', normalized);

      _pollCount++;

      // Phase 1 : Calibration du niveau ambiant (3 premiers polls = 0.6s)
      if (_pollCount <= _calibrationTicks) {
        _ambientSum += normalized;
        if (_pollCount == _calibrationTicks) {
          _ambientLevel = _ambientSum / _calibrationTicks;
        }
        return;
      }

      // Phase 2 : Detection voix/silence relative au niveau ambiant
      final voiceThreshold = _ambientLevel + _voiceMargin;
      final silenceThreshold = _ambientLevel + _silenceMargin;

      if (normalized > voiceThreshold) {
        _hasHeardVoice = true;
        _silentTicks = 0;
      } else if (_hasHeardVoice && normalized < silenceThreshold) {
        _silentTicks++;
        if (_silentTicks >= _silenceTicksRequired) {
          _onDismissed();
          return;
        }
      } else if (_hasHeardVoice) {
        // Entre les deux seuils : on ne reset pas mais on n'incremente pas non plus
      }
    } catch (_) {
    } finally {
      _isPolling = false;
    }
  }

  void dispose() {
    _amplitudeTimer?.cancel();
    _dismissController.close();
  }
}
