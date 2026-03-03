import 'dart:typed_data';
import '../models/ai_action.dart';
import 'groq_client.dart';
import 'local_action_dispatcher.dart';
import 'transcription_service.dart';

/// =============================================================================
/// voice_input_processor.dart
/// =============================================================================
/// Point d'entrée principal pour le traitement des entrées vocales.
/// Orchestre la transcription, l'analyse IA et l'exécution des actions.
///
/// Architecture Clean:
/// 1. Audio ADPCM → Transcription (Groq Whisper)
/// 2. Transcription → Analyse IA (Groq Llama 3)
/// 3. AiAction → Exécution locale (Android natif)
/// =============================================================================

/// Résultat complet du traitement vocal
class VoiceProcessingResult {
  final String transcript;
  final AiAction action;
  final ActionResult? executionResult;
  final Duration processingTime;
  final String? error;

  const VoiceProcessingResult({
    required this.transcript,
    required this.action,
    this.executionResult,
    required this.processingTime,
    this.error,
  });

  bool get success => error == null && (executionResult?.success ?? true);

  @override
  String toString() =>
      'VoiceProcessingResult(transcript: "$transcript", action: ${action.intent}, success: $success)';
}

/// Processeur principal des entrées vocales
class VoiceInputProcessor {
  static VoiceInputProcessor? _instance;

  final TranscriptionService _transcriptionService;
  final GroqClient _groqClient;
  final LocalActionDispatcher _dispatcher;

  bool _initialized = false;

  /// Constructeur privé
  VoiceInputProcessor._({
    TranscriptionService? transcriptionService,
    GroqClient? groqClient,
    LocalActionDispatcher? dispatcher,
  })  : _transcriptionService = transcriptionService ?? TranscriptionService(),
        _groqClient = groqClient ?? GroqClient(),
        _dispatcher = dispatcher ?? LocalActionDispatcher();

  /// Factory Singleton
  factory VoiceInputProcessor() {
    _instance ??= VoiceInputProcessor._();
    return _instance!;
  }

  /// Reset singleton (pour tests)
  static void reset() => _instance = null;

  /// Initialise tous les services
  Future<void> initialize() async {
    if (_initialized) return;

    await _dispatcher.initialize();

    _initialized = true;
    // ignore: avoid_print
    print('[Processor] Initialisé');
  }

  // ===========================================================================
  // POINT D'ENTRÉE PRINCIPAL
  // ===========================================================================

  /// Traite une transcription textuelle et exécute l'action correspondante
  ///
  /// C'est la fonction principale à appeler après avoir obtenu une transcription.
  Future<VoiceProcessingResult> processVoiceInput(String transcript) async {
    final stopwatch = Stopwatch()..start();

    // ignore: avoid_print
    print('[Processor] =====================================');
    // ignore: avoid_print
    print('[Processor] Traitement: "$transcript"');
    // ignore: avoid_print
    print('[Processor] GroqClient configuré: ${_groqClient.isConfigured}');

    try {
      // Étape 1: Analyser la transcription avec Groq
      // ignore: avoid_print
      print('[Processor] Appel à GroqClient.analyzeWithRetry...');
      final action = await _groqClient.analyzeWithRetry(transcript);
      // ignore: avoid_print
      print('[Processor] Action détectée: ${action.intent} (${action.runtimeType})');
      // ignore: avoid_print
      print('[Processor] Reasoning: ${action.reasoning}');

      // Étape 2: Exécuter l'action localement
      final executionResult = await _dispatcher.dispatch(action);
      // ignore: avoid_print
      print('[Processor] Résultat: ${executionResult.message}');

      // Étape 3: Log pour historique
      _logToHistory(transcript, action, executionResult);

      stopwatch.stop();
      // ignore: avoid_print
      print('[Processor] Succès - Action: ${action.intent}, Temps: ${stopwatch.elapsed.inMilliseconds}ms');
      // ignore: avoid_print
      print('[Processor] =====================================');

      return VoiceProcessingResult(
        transcript: transcript,
        action: action,
        executionResult: executionResult,
        processingTime: stopwatch.elapsed,
      );
    } catch (e, stackTrace) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[Processor] ERREUR: $e');
      // ignore: avoid_print
      print('[Processor] Stack: $stackTrace');
      // ignore: avoid_print
      print('[Processor] =====================================');

      return VoiceProcessingResult(
        transcript: transcript,
        action: NoAction(reasoning: 'Erreur de traitement: $e', memo: transcript),
        processingTime: stopwatch.elapsed,
        error: e.toString(),
      );
    }
  }

  /// Traite des données audio WAV (depuis BLE après conversion)
  ///
  /// Pipeline complet: Audio → Transcription → Action → Exécution
  Future<VoiceProcessingResult> processAudioData(Uint8List wavData) async {
    final stopwatch = Stopwatch()..start();

    try {
      // Étape 1: Transcrire l'audio via Groq Whisper
      // ignore: avoid_print
      print('[Processor] Transcription de ${wavData.length} bytes...');
      final result = await _transcriptionService.transcribeBytes(
        wavData,
        filename: 'audio.wav',
      );

      if (result.text.isEmpty) {
        return VoiceProcessingResult(
          transcript: '',
          action: const NoAction(
              reasoning: 'Transcription vide', memo: 'Audio non reconnu'),
          processingTime: stopwatch.elapsed,
          error: 'Transcription vide',
        );
      }

      // ignore: avoid_print
      print('[Processor] Transcription: "${result.text}"');

      // Étape 2: Traiter la transcription
      final processingResult = await processVoiceInput(result.text);

      stopwatch.stop();
      return VoiceProcessingResult(
        transcript: processingResult.transcript,
        action: processingResult.action,
        executionResult: processingResult.executionResult,
        processingTime: stopwatch.elapsed,
        error: processingResult.error,
      );
    } catch (e) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[Processor] Erreur audio: $e');

      return VoiceProcessingResult(
        transcript: '',
        action: NoAction(reasoning: 'Erreur audio', memo: e.toString()),
        processingTime: stopwatch.elapsed,
        error: e.toString(),
      );
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  /// Log l'action pour référence
  void _logToHistory(
    String transcript,
    AiAction action,
    ActionResult result,
  ) {
    // ignore: avoid_print
    print('[Processor] Historique: ${action.intent} - ${result.success}');
  }

  /// Vérifie si le processeur est prêt
  bool get isReady => _initialized && _groqClient.isConfigured;

  /// Obtient les statistiques de traitement
  Map<String, dynamic> getStats() {
    return {
      'initialized': _initialized,
      'groqConfigured': _groqClient.isConfigured,
    };
  }
}

// =============================================================================
// FONCTION UTILITAIRE GLOBALE
// =============================================================================

/// Point d'entrée simplifié pour traiter une entrée vocale
///
/// Usage:
/// ```dart
/// final result = await processTranscript("Mets un timer de 5 minutes");
/// print(result.action); // TimerAction(duration: 300)
/// ```
Future<VoiceProcessingResult> processTranscript(String transcript) async {
  final processor = VoiceInputProcessor();
  if (!processor.isReady) {
    await processor.initialize();
  }
  return processor.processVoiceInput(transcript);
}
