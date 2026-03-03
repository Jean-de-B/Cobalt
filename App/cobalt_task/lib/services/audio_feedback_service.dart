import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

/// =============================================================================
/// audio_feedback_service.dart
/// =============================================================================
/// Service de feedback audio pour confirmations vocales.
///
/// Utilisé pour confirmer les actions quand l'écran est verrouillé:
/// - "SMS envoyé à Pierre"
/// - "Alarme créée pour 7h"
/// - "Appel en cours vers Marie"
/// =============================================================================

class AudioFeedbackService {
  static AudioFeedbackService? _instance;

  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _enabled = true;

  /// Singleton
  factory AudioFeedbackService() {
    _instance ??= AudioFeedbackService._internal();
    return _instance!;
  }

  AudioFeedbackService._internal();

  /// Active/désactive le feedback vocal
  bool get isEnabled => _enabled;
  set enabled(bool value) => _enabled = value;

  /// Initialise le service TTS
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Configuration du TTS
      await _tts.setLanguage('fr-FR');
      await _tts.setSpeechRate(0.5); // Vitesse normale
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      // Utiliser le moteur TTS par défaut
      final engines = await _tts.getEngines;
      if (engines.isNotEmpty) {
        // ignore: avoid_print
        print('[AudioFeedback] Moteurs TTS disponibles: $engines');
      }

      _isInitialized = true;
      // ignore: avoid_print
      print('[AudioFeedback] Service initialisé');
    } catch (e) {
      // ignore: avoid_print
      print('[AudioFeedback] Erreur d\'initialisation: $e');
    }
  }

  /// Prononce un texte de confirmation
  Future<void> speak(String text) async {
    if (!_enabled || !_isInitialized) return;

    try {
      await _tts.speak(text);
      // ignore: avoid_print
      print('[AudioFeedback] Prononcé: "$text"');
    } catch (e) {
      // ignore: avoid_print
      print('[AudioFeedback] Erreur speak: $e');
    }
  }

  /// Prononce un texte et attend la fin de la lecture TTS
  ///
  /// Contrairement à [speak] qui retourne immédiatement,
  /// cette méthode bloque jusqu'à ce que le TTS ait fini de parler.
  /// Utile pour enchaîner TTS → action (ex: briefing navigation → Maps).
  Future<void> speakAndWait(String text) async {
    if (!_enabled || !_isInitialized) return;

    try {
      final completer = Completer<void>();

      _tts.setCompletionHandler(() {
        if (!completer.isCompleted) completer.complete();
      });

      _tts.setErrorHandler((msg) {
        if (!completer.isCompleted) completer.completeError(msg);
      });

      await _tts.speak(text);
      await completer.future;

      // ignore: avoid_print
      print('[AudioFeedback] speakAndWait terminé: "$text"');
    } catch (e) {
      // ignore: avoid_print
      print('[AudioFeedback] Erreur speakAndWait: $e');
    }
  }

  /// Confirme une action exécutée
  Future<void> confirmAction(String actionType, String details) async {
    final message = _buildConfirmationMessage(actionType, details);
    await speak(message);
  }

  /// Construit le message de confirmation selon le type d'action
  String _buildConfirmationMessage(String actionType, String details) {
    switch (actionType.toLowerCase()) {
      case 'sms':
        return 'SMS envoyé à $details';
      case 'call':
        return 'Appel vers $details';
      case 'alarm':
        return 'Alarme créée pour $details';
      case 'timer':
        return 'Minuteur de $details lancé';
      case 'calendar':
        return 'Événement $details créé';
      case 'task':
        return 'Tâche $details ajoutée';
      case 'volume':
        return 'Volume $details';
      case 'flashlight':
        return 'Lampe torche $details';
      case 'navigation':
        return 'Navigation vers $details';
      case 'whatsapp':
        return 'Message WhatsApp envoyé à $details';
      case 'error':
        return 'Erreur: $details';
      default:
        return details;
    }
  }

  /// Annonce une erreur
  Future<void> announceError(String error) async {
    await speak('Erreur. $error');
  }

  /// Annonce que l'écoute est active
  Future<void> announceListening() async {
    await speak('J\'écoute');
  }

  /// Annonce la fin du traitement
  Future<void> announceComplete() async {
    await speak('Terminé');
  }

  /// Arrête la lecture en cours
  Future<void> stop() async {
    await _tts.stop();
  }

  /// Libère les ressources
  void dispose() {
    _tts.stop();
    // ignore: avoid_print
    print('[AudioFeedback] Ressources libérées');
  }
}
