import 'dart:typed_data';

/// =============================================================================
/// vosk_transcription_service.dart
/// =============================================================================
/// Service de transcription vocale locale utilisant Vosk.
///
/// STATUS: DÉSACTIVÉ - vosk_flutter_2 incompatible avec AGP 8+
/// L'architecture est prête pour un futur package STT offline compatible.
///
/// Fonctionnalités prévues:
/// - Transcription 100% offline (pas de connexion internet requise)
/// - Modèle français compact (~50MB)
/// - Fonctionne en arrière-plan (écran verrouillé)
///
/// Fallback actuel: Whisper (API Groq) est utilisé pour toutes les transcriptions.
/// =============================================================================

class VoskTranscriptionService {
  static VoskTranscriptionService? _instance;

  // Service désactivé - pas de dépendances Vosk
  final bool _isInitialized = false;
  final bool _isModelLoaded = false;

  /// Nom du modèle français (pour référence future)
  static const String _modelName = 'vosk-model-small-fr-0.22';

  /// URL de téléchargement du modèle (pour référence future)
  static const String _modelUrl =
      'https://alphacephei.com/vosk/models/vosk-model-small-fr-0.22.zip';

  /// Singleton
  factory VoskTranscriptionService() {
    _instance ??= VoskTranscriptionService._internal();
    return _instance!;
  }

  VoskTranscriptionService._internal();

  /// Vérifie si le service est initialisé et prêt
  /// TOUJOURS false car le package est désactivé
  bool get isReady => _isInitialized && _isModelLoaded;

  /// Initialise le service Vosk
  /// Retourne toujours false car le package est désactivé
  Future<bool> initialize() async {
    // ignore: avoid_print
    print('[Vosk] Service désactivé - vosk_flutter_2 incompatible avec AGP 8+');
    // ignore: avoid_print
    print('[Vosk] Utilisation du fallback Whisper (cloud) pour toutes les transcriptions');
    return false;
  }

  /// Télécharge le modèle français
  /// Retourne toujours false car le package est désactivé
  Future<bool> downloadModel({
    Function(double)? onProgress,
  }) async {
    // ignore: avoid_print
    print('[Vosk] Téléchargement désactivé - package incompatible');
    return false;
  }

  /// Transcrit un fichier audio
  /// Retourne toujours null car le package est désactivé
  Future<String?> transcribeFile(String audioPath) async {
    return null;
  }

  /// Transcrit des données audio brutes
  /// Retourne toujours null car le package est désactivé
  Future<String?> transcribeBytes(Uint8List audioData) async {
    return null;
  }

  /// Évalue la qualité de la transcription (heuristique simple)
  /// Retourne un score entre 0.0 et 1.0
  double evaluateQuality(String transcription) {
    if (transcription.isEmpty) return 0.0;

    // Heuristiques simples:
    // - Longueur minimale
    // - Pas trop de caractères spéciaux
    // - Au moins quelques mots

    final words = transcription.split(' ').where((w) => w.length > 1).length;
    final specialChars = transcription.replaceAll(RegExp(r'[a-zA-ZÀ-ÿ\s]'), '').length;
    final totalChars = transcription.length;

    if (words < 2) return 0.3;
    if (specialChars > totalChars * 0.2) return 0.4;
    if (words < 5) return 0.6;

    return 0.8;
  }

  /// Libère les ressources
  void dispose() {
    // ignore: avoid_print
    print('[Vosk] Dispose (service désactivé)');
  }
}
