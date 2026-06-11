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

  /// Intents qui n'ont de sens qu'en temps réel — ignorés si l'enregistrement est différé.
  static const _instantIntents = {
    ActionIntent.media,
    ActionIntent.systemControl,
    ActionIntent.call,
    ActionIntent.navigation,
    ActionIntent.appLaunch,
    ActionIntent.timer,
  };

  /// Traite une transcription textuelle et exécute l'action correspondante.
  ///
  /// [isDeferred] : true si l'audio provient de la flash offline (reconnexion différée).
  /// Dans ce cas, les commandes instantanées (media, volume, appel…) sont ignorées.
  Future<VoiceProcessingResult> processVoiceInput(String transcript, {bool isDeferred = false}) async {
    final stopwatch = Stopwatch()..start();

    // ignore: avoid_print
    print('[Processor] =====================================');
    // ignore: avoid_print
    print('[Processor] Traitement: "$transcript"');
    // ignore: avoid_print
    print('[Processor] GroqClient configuré: ${_groqClient.isConfigured}');

    try {
      // Étape 1: Pré-classification locale (skip API si commande simple)
      final localAction = _tryLocalClassification(transcript);
      final AiAction action;
      if (localAction != null) {
        action = localAction;
        // ignore: avoid_print
        print('[Processor] Classification LOCALE (skip API): ${action.intent}');
      } else {
        // ignore: avoid_print
        print('[Processor] Appel à GroqClient.analyzeWithRetry...');
        action = await _groqClient.analyzeWithRetry(transcript);
      }
      // ignore: avoid_print
      print('[Processor] Action détectée: ${action.intent} (${action.runtimeType})');
      // ignore: avoid_print
      print('[Processor] Reasoning: ${action.reasoning}');

      // Filtre différé : commandes instantanées ignorées si l'audio vient de la flash offline
      if (isDeferred && _instantIntents.contains(action.intent)) {
        // ignore: avoid_print
        print('[Processor] Action IGNORÉE (différée + instant): ${action.intent}');
        stopwatch.stop();
        return VoiceProcessingResult(
          transcript: transcript,
          action: NoAction(reasoning: 'Commande instantanée ignorée (enregistrement différé)', memo: transcript),
          processingTime: stopwatch.elapsed,
        );
      }

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

  /// Pré-classification locale par regex.
  /// Retourne null si la commande est trop complexe pour être classifiée localement.
  AiAction? _tryLocalClassification(String transcript) {
    final t = transcript.trim().toLowerCase();

    // --- MEDIA : pause / play / next / previous / stop ---
    if (RegExp(r'^(mets?\s+)?pause$').hasMatch(t) ||
        t == 'stop la musique' || t == 'arrête la musique') {
      return const MediaAction(reasoning: 'Pause (local)', controlType: MediaControlType.pause);
    }
    if (RegExp(r'^(lance|reprends?|play|lecture)(\s+la\s+musique)?$').hasMatch(t)) {
      return const MediaAction(reasoning: 'Play (local)', controlType: MediaControlType.play);
    }
    if (RegExp(r'^(suivant|next|piste suivante|titre suivant)$').hasMatch(t)) {
      return const MediaAction(reasoning: 'Next (local)', controlType: MediaControlType.next);
    }
    if (RegExp(r'^(précédent|previous|piste précédente|titre précédent)$').hasMatch(t)) {
      return const MediaAction(reasoning: 'Previous (local)', controlType: MediaControlType.previous);
    }
    if (t == 'stop' || t == 'arrête') {
      return const MediaAction(reasoning: 'Stop (local)', controlType: MediaControlType.stop);
    }
    if (RegExp(r'^like(\s+(ce|le|this)\s+(titre|morceau|track|son))?$').hasMatch(t)) {
      return const MediaAction(reasoning: 'Like (local)', controlType: MediaControlType.like);
    }

    // --- VOLUME ---
    if (RegExp(r'^(monte|augmente|plus fort|volume\s*up)(\s+le\s+(son|volume))?$').hasMatch(t)) {
      return const SystemControlAction(reasoning: 'Vol+ (local)', controlType: SystemControlType.volumeUp);
    }
    if (RegExp(r'^(baisse|diminue|moins fort|volume\s*down)(\s+le\s+(son|volume))?$').hasMatch(t)) {
      return const SystemControlAction(reasoning: 'Vol- (local)', controlType: SystemControlType.volumeDown);
    }
    if (RegExp(r'^(son\s+à\s+fond|volume\s+(à\s+fond|max|100))$').hasMatch(t)) {
      return const SystemControlAction(reasoning: 'Vol max (local)', controlType: SystemControlType.volumeSet, value: 100);
    }
    if (RegExp(r'^(coupe\s+le\s+son|mute|muet|silence)$').hasMatch(t)) {
      return const SystemControlAction(reasoning: 'Mute (local)', controlType: SystemControlType.volumeMute);
    }

    // --- LAMPE ---
    if (RegExp(r'^(allume|active)\s+(la\s+)?(lampe|torche|flash)').hasMatch(t)) {
      return const SystemControlAction(reasoning: 'Lampe on (local)', controlType: SystemControlType.flashlightOn);
    }
    if (RegExp(r'^(éteins?|désactive|coupe)\s+(la\s+)?(lampe|torche|flash)').hasMatch(t)) {
      return const SystemControlAction(reasoning: 'Lampe off (local)', controlType: SystemControlType.flashlightOff);
    }

    // --- APPEL ---
    final callMatch = RegExp(r'^appell?e\s+(.+)$').firstMatch(t);
    if (callMatch != null) {
      final contact = callMatch.group(1)!.trim();
      return CallAction(reasoning: 'Appel (local)', contact: contact);
    }

    // --- TIMER ---
    final timerMatch = RegExp(r'timer?\s+(?:de\s+)?(\d+)\s*(min|minute|sec|seconde|h|heure)').firstMatch(t);
    if (timerMatch != null) {
      final value = int.parse(timerMatch.group(1)!);
      final unit = timerMatch.group(2)!;
      final seconds = unit.startsWith('h') ? value * 3600
          : unit.startsWith('min') ? value * 60
          : value;
      return TimerAction(reasoning: 'Timer (local)', durationSeconds: seconds, label: 'Timer');
    }

    // --- BATTERIE ---
    if (RegExp(r"(niveau\s+(de\s+)?(la\s+)?batterie|batterie\s+(est|à|reste|il\s+reste)|combien\s+(il\s+reste|reste[- ]t[- ]il)\s+(de\s+)?batterie|autonomie\s+restante|charge\s+restante|t[ue]\s+as\s+combien\s+de\s+batterie|c.?est\s+quoi\s+la\s+batterie)").hasMatch(t)) {
      return QueryBatteryAction(reasoning: 'Demande batterie (local)');
    }

    // --- HEURE ---
    if (RegExp(r"(quelle\s+heure\s+(est[- ]il|il\s+est)|il\s+est\s+quelle\s+heure|dis[- ]moi\s+l.heure|c.?est\s+quoi\s+l.heure|l.heure\s+s.?il\s+te\s+pla[iî]t|donne[- ]moi\s+l.heure|heure\s+actuelle|quelle\s+est\s+l.heure)").hasMatch(t)) {
      return QueryTimeAction(reasoning: 'Demande heure (local)');
    }

    // --- APP LAUNCH ---
    final openMatch = RegExp(r'^ouvr[ei]s?\s+(.+)$').firstMatch(t);
    if (openMatch != null) {
      return AppLaunchAction(reasoning: 'App (local)', appName: openMatch.group(1)!.trim());
    }

    // Pas de match local → envoyer à Groq
    return null;
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
