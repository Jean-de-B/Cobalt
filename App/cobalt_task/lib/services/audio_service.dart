import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_constants.dart';
import '../models/fiche.dart';
import '../models/voice_note.dart';
import '../models/ai_action.dart';
import 'adpcm_decoder.dart';
import 'ble_service.dart';
import 'ai_sorter_service.dart';
import 'database_service.dart';
import 'transcription_service.dart';
import 'google_bridge_service.dart';
import 'voice_input_processor.dart';
import 'local_media_service.dart';
import 'sherpa_transcription_service.dart';
import 'audio_feedback_service.dart';
import 'foreground_service.dart';
import 'settings_service.dart';

/// =============================================================================
/// audio_service.dart
/// =============================================================================
/// Service d'orchestration du pipeline audio complet.
///
/// Ce service coordonne le flux de données depuis la réception BLE
/// jusqu'au stockage final de la note transcrite:
///
/// 1. Écoute les données audio reçues via BLE
/// 2. Décode ADPCM → PCM et génère un fichier WAV
/// 3. Envoie le WAV à l'API Groq pour transcription
/// 4. Stocke la note (texte + audio) dans SQLite
///
/// Le service gère également la lecture audio des notes enregistrées.
/// =============================================================================

class AudioService {
  /// Instance singleton
  static AudioService? _instance;

  /// Dépendances injectées
  final BleService _bleService;
  final AdpcmDecoder _adpcmDecoder;
  final TranscriptionService _transcriptionService;
  final AiSorterService _aiSorterService;
  final DatabaseService _databaseService;
  final GoogleBridgeService _googleBridgeService;
  final VoiceInputProcessor _voiceInputProcessor;
  final LocalMediaService _localMediaService;
  final SherpaTranscriptionService _sherpaService;
  final AudioFeedbackService _audioFeedback;
  final CobaltForegroundService _foregroundService;

  /// Lecteur audio pour la lecture des notes
  final AudioPlayer _audioPlayer;

  /// Enregistreur audio pour l'enregistrement depuis le téléphone
  final AudioRecorder _audioRecorder;

  /// Répertoire de stockage des fichiers audio
  Directory? _audioDirectory;

  /// Indique si un enregistrement est en cours
  bool _isRecording = false;
  bool get isRecording => _isRecording;

  /// Timestamp de début d'enregistrement
  DateTime? _recordingStartTime;

  /// Indique si la musique jouait avant l'enregistrement
  bool _musicWasPlayingBeforeRecording = false;

  /// StreamController pour notifier l'état d'enregistrement
  final _recordingStateController = StreamController<bool>.broadcast();
  Stream<bool> get recordingStateStream => _recordingStateController.stream;

  /// Subscription au stream de données BLE
  StreamSubscription? _bleDataSubscription;

  /// Garde contre l'exécution concurrente de retryPendingTranscriptions
  bool _isRetrying = false;

  /// Note en cours de lecture (pour l'UI)
  int? _currentlyPlayingId;

  /// StreamController pour notifier l'état de lecture
  final _playbackStateController = StreamController<int?>.broadcast();
  Stream<int?> get playbackStateStream => _playbackStateController.stream;

  /// Constructeur privé
  AudioService._internal()
      : _bleService = BleService(),
        _adpcmDecoder = AdpcmDecoder(),
        _transcriptionService = TranscriptionService(),
        _aiSorterService = AiSorterService(),
        _databaseService = DatabaseService(),
        _googleBridgeService = GoogleBridgeService(),
        _voiceInputProcessor = VoiceInputProcessor(),
        _localMediaService = LocalMediaService(),
        _sherpaService = SherpaTranscriptionService(),
        _audioFeedback = AudioFeedbackService(),
        _foregroundService = CobaltForegroundService(),
        _audioPlayer = AudioPlayer(),
        _audioRecorder = AudioRecorder();

  /// Factory Singleton
  factory AudioService() {
    _instance ??= AudioService._internal();
    return _instance!;
  }

  /// Flag pour reset au prochain démarrage (désactivé - données persistantes)
  static const bool _resetOnNextLaunch = false;

  /// Initialise le service
  ///
  /// - Crée le répertoire de stockage audio
  /// - Initialise le service de transcription
  /// - S'abonne aux données BLE
  Future<void> initialize() async {
    // Créer le répertoire de stockage
    final appDir = await getApplicationDocumentsDirectory();
    _audioDirectory = Directory(path.join(appDir.path, 'cobalt_voice_audio'));

    // Reset unique si le flag est activé - supprimer tous les fichiers audio
    if (_resetOnNextLaunch && await _audioDirectory!.exists()) {
      // ignore: avoid_print
      print('AUDIO: Reset - Suppression des fichiers audio...');
      try {
        await _audioDirectory!.delete(recursive: true);
        // ignore: avoid_print
        print('AUDIO: Fichiers audio supprimés');
      } catch (e) {
        // ignore: avoid_print
        print('AUDIO: Erreur suppression: $e');
      }
    }

    if (!await _audioDirectory!.exists()) {
      await _audioDirectory!.create(recursive: true);
    }

    // Initialiser les services d'IA
    _transcriptionService.initialize();
    try {
      _aiSorterService.initialize();
    } catch (e) {
      // ignore: avoid_print
      print('AUDIO: Erreur initialisation AI Sorter: $e');
      // Continuer sans le service d'analyse - fallback vers MEMO
    }

    // Initialiser le processeur d'actions locales (alarmes, timers, SMS, calendrier)
    try {
      await _voiceInputProcessor.initialize();
      // ignore: avoid_print
      print('AUDIO: VoiceInputProcessor initialisé');
    } catch (e) {
      // ignore: avoid_print
      print('AUDIO: Erreur initialisation VoiceInputProcessor: $e');
    }

    // Initialiser le service Google (connexion silencieuse si déjà connecté)
    try {
      await _googleBridgeService.initialize();
      // ignore: avoid_print
      print('AUDIO: Google Bridge initialisé - Connecté: ${_googleBridgeService.isConnected}');
    } catch (e) {
      // ignore: avoid_print
      print('AUDIO: Erreur initialisation Google Bridge: $e');
      // Continuer sans sync Google
    }



    // Initialiser le foreground service (notification persistante)
    // IMPORTANT: initialiser ET démarrer le foreground service ICI au lancement,
    // AVANT le scan BLE. startService() est très lourd côté Android natif
    // (crée un isolate, notification, service). Le faire pendant l'init
    // évite les ANR car l'utilisateur n'interagit pas encore.
    try {
      await _foregroundService.initialize();
      // ignore: avoid_print
      print('AUDIO: Foreground service initialisé');
      await _foregroundService.start();
      // ignore: avoid_print
      print('AUDIO: Foreground service démarré au lancement');
    } catch (e) {
      // ignore: avoid_print
      print('AUDIO: Erreur foreground service: $e');
    }

    // Initialiser Spotify en arrière-plan (non-bloquant, tokens + callback)
    _localMediaService.spotifyService.initialize().then((_) {
      // ignore: avoid_print
      print('AUDIO: Spotify initialisé - connecté: ${_localMediaService.spotifyService.isConnected}');
    }).catchError((e) {
      // ignore: avoid_print
      print('AUDIO: Erreur init Spotify: $e');
    });

    // Écouter les données audio du BLE
    _bleDataSubscription = _bleService.audioDataStream.listen(_processAudioData);

    // NOTE: Pas de updateNotification sur connexion BLE
    // Chaque updateNotification est un appel plateforme (MethodChannel)
    // qui sature le main thread Android et provoque des ANR

    // Configurer le lecteur audio
    _audioPlayer.onPlayerComplete.listen((_) {
      _currentlyPlayingId = null;
      _playbackStateController.add(null);
    });

    // Initialiser le service BLE (charge device persisté, écoute état BT,
    // démarre reconnexion automatique si device connu)
    // ignore: avoid_print
    print('AUDIO: Initialisation BLE (reconnexion 3-phases)...');
    await _bleService.initialize();
  }

  // ---------------------------------------------------------------------------
  // PIPELINE DE TRAITEMENT AUDIO
  // ---------------------------------------------------------------------------

  /// Traite les données audio reçues via BLE
  ///
  /// Cette méthode est appelée automatiquement quand une transmission
  /// audio complète est reçue du firmware.
  /// IMPORTANT: Ne pas bloquer cette méthode pour permettre la réception BLE continue.
  Future<void> _processAudioData(Uint8List rawBleData) async {
    // ignore: avoid_print
    print('AUDIO: Données reçues du BLE - ${rawBleData.length} bytes');

    // Mettre à jour la notification du foreground service
    _foregroundService.showActionNotification('Mémo reçu, traitement...');

    try {
      // 1. Décoder ADPCM → WAV (rapide, pas besoin de wake lock)
      // ignore: avoid_print
      print('AUDIO: Décodage ADPCM → WAV...');
      final (wavData, header) = _adpcmDecoder.decodeToWav(rawBleData);
      // ignore: avoid_print
      print('AUDIO: Décodage OK - WAV: ${wavData.length} bytes, durée: ${header.durationSeconds.toStringAsFixed(1)}s');

      // 2. Éliminer les enregistrements silencieux avant toute persistence ou STT
      if (_isWavSilent(wavData)) return;

      // 3. Sauvegarder le fichier WAV
      final audioPath = await _saveWavFile(wavData);
      final duration = header.durationSeconds.round();
      // ignore: avoid_print
      print('AUDIO: Fichier sauvegardé → $audioPath');

      // 3. Créer une note en attente de transcription
      var note = VoiceNote.pending(
        audioPath: audioPath,
        duration: duration,
      );
      final noteId = await _databaseService.insertNote(note);
      note = note.copyWith(id: noteId);
      // ignore: avoid_print
      print('AUDIO: Note créée en base (id: $noteId)');

      // 4. Transcrire de manière asynchrone (sans bloquer la réception BLE)
      // Le wake lock est géré dans _transcribeAndUpdate pour les opérations longues
      // ignore: avoid_print
      print('AUDIO: Lancement de la transcription...');
      _transcribeAndUpdate(note, wavData, isDeferred: header.isDeferred); // Fire-and-forget (pas de await)
    } catch (e, stackTrace) {
      // Log l'erreur mais ne pas crasher
      // ignore: avoid_print
      print('AUDIO ERREUR: $e');
      print('AUDIO STACK: $stackTrace');
    }
  }

  // ---------------------------------------------------------------------------
  // DÉTECTION DE SILENCE
  // ---------------------------------------------------------------------------

  /// Taille du header WAV standard en bytes.
  static const int _wavHeaderSize = 44;

  /// Fréquence d'échantillonnage supposée (Hz). Utilisée pour calculer la
  /// taille des fenêtres d'analyse.
  static const int _sampleRate = 16000;

  /// Durée d'une fenêtre d'analyse en ms (100 ms = 1600 samples à 16kHz).
  static const int _windowMs = 100;

  /// RMS minimal de la fenêtre la plus forte pour valider la présence de parole.
  /// Valeur 600/32767 ≈ 1.8% → en dessous, même les pics sont trop faibles
  /// pour être de la parole (micro BLE propre ou téléphone silencieux).
  static const double _minPeakRms = 600;

  /// Ratio minimum entre la fenêtre la plus forte et la moyenne des fenêtres.
  /// La parole est dynamique : ses pics sont ≥ 2× le fond ambiant.
  /// Le bruit ambiant (ventilation, souffle) est uniforme : ratio ≈ 1.0–1.4.
  static const double _minDynamicRatio = 1.8;

  /// Analyse les samples PCM du WAV par fenêtres de 100 ms et retourne [true]
  /// si l'audio est silencieux ou correspond à du bruit ambiant uniforme.
  ///
  /// Algorithme :
  /// 1. Découpe le signal en fenêtres de [_windowMs] ms.
  /// 2. Calcule le RMS de chaque fenêtre.
  /// 3. Si le RMS maximal < [_minPeakRms] → énergie trop faible → silence.
  /// 4. Si max(RMS) / mean(RMS) < [_minDynamicRatio] → signal uniforme → bruit.
  ///
  /// La condition 4 est ce qui distingue "parole" de "bruit ambiant soutenu" :
  /// un micro de téléphone dans une pièce normale capte un fond continu qui
  /// passe le test énergétique brut, mais dont la dynamique est trop faible.
  bool _isWavSilent(Uint8List wavData) {
    if (wavData.length <= _wavHeaderSize) return true;

    final byteData = ByteData.sublistView(wavData, _wavHeaderSize);
    final totalSamples = byteData.lengthInBytes ~/ 2;
    if (totalSamples == 0) return true;

    final windowSize = (_sampleRate * _windowMs) ~/ 1000; // 1600 samples
    final windowCount = (totalSamples / windowSize).ceil();

    final windowRms = <double>[];

    for (int w = 0; w < windowCount; w++) {
      final start = w * windowSize;
      final end = (start + windowSize).clamp(0, totalSamples);
      double sumSq = 0;
      for (int i = start; i < end; i++) {
        final s = byteData.getInt16(i * 2, Endian.little).toDouble();
        sumSq += s * s;
      }
      windowRms.add((sumSq / (end - start) > 0)
          ? (sumSq / (end - start)) // RMS² — on compare les carrés pour éviter sqrt
          : 0);
    }

    // RMS² max et moyenne (comparaison relative — pas besoin de sqrt)
    final maxRmsSq = windowRms.reduce((a, b) => a > b ? a : b);
    final meanRmsSq = windowRms.fold(0.0, (s, v) => s + v) / windowRms.length;

    final maxRms = maxRmsSq > 0 ? math.sqrt(maxRmsSq) : 0.0;  // RMS réel pour le seuil absolu
    final ratio = meanRmsSq > 0 ? (maxRmsSq / meanRmsSq) : 0.0;

    // ignore: avoid_print
    print('AUDIO: Silence check — RMS_max: ${maxRms.toStringAsFixed(0)}/32767 '
        '(${(maxRms / 32767 * 100).toStringAsFixed(1)}%), '
        'ratio dynamique: ${ratio.toStringAsFixed(2)}');

    if (maxRms < _minPeakRms) {
      // ignore: avoid_print
      print('AUDIO: 🔇 Silence détecté (énergie trop faible) — audio ignoré');
      return true;
    }
    if (ratio < _minDynamicRatio) {
      // ignore: avoid_print
      print('AUDIO: 🔇 Silence détecté (bruit uniforme, ratio ${ratio.toStringAsFixed(2)}) — audio ignoré');
      return true;
    }
    return false;
  }

  /// Hallucinations connues de Whisper sur audio silencieux
  static const List<String> _whisperHallucinations = [
    'sous-titres réalisés par',
    "sous-titres par la communauté d'amara",
    'amara.org',
    'merci d\'avoir regardé',
    'transcription de',
    'sous-titrage',
    'sous-titres',
  ];

  /// Retourne [true] si le texte transcrit est vide ou halluciné.
  ///
  /// Critères (dans l'ordre) :
  /// 1. Moins de 3 caractères alphabétiques après suppression des espaces/ponctuation
  /// 2. Correspond à une hallucination Whisper connue
  bool _isTranscriptionMeaningless(String text) {
    final cleaned = text.trim();

    // Compter les lettres (au moins 3 pour une vraie transcription)
    final letterCount = cleaned.replaceAll(RegExp(r'[^a-zA-ZÀ-ÿ]'), '').length;
    if (letterCount < 3) {
      // ignore: avoid_print
      print('TRANSCRIPTION: Vide ($letterCount lettre(s) utiles)');
      return true;
    }

    // Vérifier contre les hallucinations Whisper connues
    final lower = cleaned.toLowerCase();
    for (final pattern in _whisperHallucinations) {
      if (lower.contains(pattern)) {
        // ignore: avoid_print
        print('TRANSCRIPTION: Hallucination détectée ("$pattern")');
        return true;
      }
    }

    return false;
  }

  // ---------------------------------------------------------------------------

  /// Sauvegarde un fichier WAV sur le disque
  ///
  /// Retourne le chemin absolu du fichier créé.
  Future<String> _saveWavFile(Uint8List wavData) async {
    // Générer un nom unique basé sur le timestamp
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filename = 'note_$timestamp.wav';
    final filePath = path.join(_audioDirectory!.path, filename);

    // Écrire le fichier
    final file = File(filePath);
    await file.writeAsBytes(wavData);

    return filePath;
  }

  /// Transcrit l'audio et analyse avec l'IA pour catégoriser
  ///
  /// Pipeline complet:
  /// 1. Transcription Vosk (local, offline) avec fallback Whisper (cloud)
  /// 2. Analyse Llama 3 (catégorisation + décision APPEND/CREATE)
  /// 3. Création ou mise à jour de la fiche thématique
  /// 4. Liaison de la note vocale à la fiche
  /// 5. Feedback audio TTS pour confirmer l'action
  ///
  /// Utilise un wake lock pour maintenir le CPU actif en arrière-plan.
  /// Note: Le wake lock principal est géré par BleService quand connecté
  Future<void> _transcribeAndUpdate(VoiceNote note, Uint8List wavData, {bool isDeferred = false}) async {
    // ignore: avoid_print
    print('TRANSCRIPTION: Début du traitement (wake lock géré par BLE)');

    try {
      // ÉTAPE 1: Transcription avec stratégie intelligente
      // - Vosk d'abord (fonctionne en arrière-plan, offline)
      // - Whisper si Vosk échoue ou qualité insuffisante
      String transcribedText = '';
      bool usedWhisper = false;

      // Essayer Vosk d'abord (fonctionne écran verrouillé)
      if (_sherpaService.isReady) {
        // ignore: avoid_print
        print('TRANSCRIPTION: Tentative Vosk (local)...');
        try {
          final voskResult = await _sherpaService.transcribeBytes(wavData);

          if (voskResult != null && voskResult.isNotEmpty) {
            // Évaluer la qualité de la transcription Vosk
            final quality = _sherpaService.evaluateQuality(voskResult);
            // ignore: avoid_print
            print('TRANSCRIPTION: Vosk OK - Qualité: ${(quality * 100).toStringAsFixed(0)}% - "$voskResult"');

            // Si qualité suffisante (> 60%), utiliser Vosk
            if (quality >= 0.6) {
              transcribedText = voskResult;
              // ignore: avoid_print
              print('TRANSCRIPTION: Utilisation de Vosk (qualité suffisante)');
            } else {
              // ignore: avoid_print
              print('TRANSCRIPTION: Qualité Vosk insuffisante, fallback Whisper...');
            }
          } else {
            // ignore: avoid_print
            print('TRANSCRIPTION: Vosk n\'a rien retourné');
          }
        } catch (e) {
          // ignore: avoid_print
          print('TRANSCRIPTION: Erreur Vosk: $e');
        }
      } else {
        // ignore: avoid_print
        print('TRANSCRIPTION: Vosk non initialisé');
      }

      // Fallback vers Whisper (cloud) si Vosk n'a pas donné de résultat satisfaisant
      if (transcribedText.isEmpty) {
        // ignore: avoid_print
        print('TRANSCRIPTION: Envoi à Groq Whisper (${wavData.length} bytes)...');
        try {
          final result = await _transcriptionService.transcribeBytes(
            wavData,
            language: SettingsService().language,
          );
          transcribedText = result.text;
          usedWhisper = true;
          // ignore: avoid_print
          print('TRANSCRIPTION: Whisper OK - "${transcribedText.substring(0, transcribedText.length.clamp(0, 50))}..."');
        } catch (e) {
          // ignore: avoid_print
          print('TRANSCRIPTION: Erreur Whisper: $e');
          // Si les deux échouent, on ne peut pas continuer
          throw Exception('Transcription impossible (Vosk et Whisper ont échoué)');
        }
      }

      // Variable pour le résultat final
      final result = (text: transcribedText, usedWhisper: usedWhisper);
      // ignore: avoid_print
      print('TRANSCRIPTION: Succès! Texte: "${result.text.substring(0, result.text.length.clamp(0, 50))}..."');

      // -----------------------------------------------------------------------
      // Validation post-STT : éliminer les transcriptions vides ou hallucinées
      // -----------------------------------------------------------------------
      if (_isTranscriptionMeaningless(result.text)) {
        // ignore: avoid_print
        print('TRANSCRIPTION: Texte vide ou hallucination → fiche grisée');
        final rejectedNote = note.copyWith(
          text: result.text,
          summary: 'Transcription non exploitable',
          isTranscribing: false,
          isAnalyzing: false,
          errorMessage: 'hallucination',
        );
        await _databaseService.updateNote(rejectedNote);
        return;
      }
      // -----------------------------------------------------------------------

      // Mettre à jour la note avec le texte (passer en mode "analyse")
      var updatedNote = note.copyWith(
        text: result.text,
        isTranscribing: false,
        isAnalyzing: true,
      );
      await _databaseService.updateNote(updatedNote);
      // ignore: avoid_print
      print('TRANSCRIPTION: Note mise à jour, lancement de l\'analyse IA...');

      // ===========================================================================
      // ÉTAPE 1.5: ACTIONS LOCALES (Alarmes, Timers, SMS, Calendrier)
      // ===========================================================================
      // Essayer d'abord de détecter une action locale avant le système de fiches
      // ignore: avoid_print
      print('LOCAL_ACTION: ========================================');
      // ignore: avoid_print
      print('LOCAL_ACTION: Analyse de "${result.text}"...');

      VoiceProcessingResult? actionResult;
      try {
        actionResult = await _voiceInputProcessor.processVoiceInput(result.text, isDeferred: isDeferred);
        // ignore: avoid_print
        print('LOCAL_ACTION: Action détectée = ${actionResult.action.intent} (${actionResult.action.runtimeType})');
        // ignore: avoid_print
        print('LOCAL_ACTION: Reasoning = ${actionResult.action.reasoning}');
      } catch (e) {
        // ignore: avoid_print
        print('LOCAL_ACTION: ERREUR dans VoiceInputProcessor: $e');
        // Continuer vers AI_SORTER en cas d'erreur
        actionResult = null;
      }
      // ignore: avoid_print
      print('LOCAL_ACTION: ========================================');

      // Si une action locale a été détectée et exécutée (pas NoAction)
      if (actionResult != null && actionResult.action is! NoAction) {
        // ignore: avoid_print
        print('LOCAL_ACTION: Action détectée = ${actionResult.action.intent}');
        // ignore: avoid_print
        print('LOCAL_ACTION: Résultat = ${actionResult.executionResult?.message ?? "OK"}');

        // Générer le résumé et le message de confirmation TTS
        final (summary, ttsMessage) = actionResult.action.when(
          calendar: (a) => ('📅 ${a.title}', 'Événement ajouté: ${a.title}'),
          sms: (a) {
            final execResult = actionResult?.executionResult;
            if (execResult != null && !execResult.success) {
              return ('⏳ → ${a.recipient} ?', 'Veuillez d\'abord confirmer le contact ${a.recipient}');
            }
            final contact = execResult?.metadata?['contact'] as String? ?? a.recipient;
            return ('💬 SMS → $contact', 'SMS envoyé à $contact');
          },
          alarm: (a) => ('⏰ Alarme ${a.time.hour}:${a.time.minute.toString().padLeft(2, "0")}', 'Alarme programmée pour ${a.time.hour} heures ${a.time.minute > 0 ? "et ${a.time.minute} minutes" : ""}'),
          timer: (a) => ('⏱️ Timer ${a.durationSeconds ~/ 60} min', 'Minuteur de ${a.durationSeconds ~/ 60} minutes lancé'),
          systemControl: (a) => ('🔊 ${a.controlType.name}', 'Paramètre système modifié'),
          call: (a) {
            final execResult = actionResult?.executionResult;
            if (execResult != null && !execResult.success) {
              return ('⏳ → ${a.contact} ?', 'Veuillez d\'abord confirmer le contact ${a.contact}');
            }
            final contact = execResult?.metadata?['contact'] as String? ?? a.contact;
            return ('📞 Appel → $contact', 'Appel de $contact');
          },
          messaging: (a) {
            final execResult = actionResult?.executionResult;
            if (execResult != null && !execResult.success) {
              return ('⏳ → ${a.recipient} ?', 'Veuillez d\'abord confirmer le contact ${a.recipient}');
            }
            final meta = execResult?.metadata;
            final app = meta?['app'] as String? ?? a.app.name;
            final contact = meta?['contact'] as String? ?? a.recipient;
            final appLabel = switch (app) {
              'whatsapp' => 'WhatsApp',
              'telegram' => 'Telegram',
              'signal' => 'Signal',
              'messenger' => 'Messenger',
              _ => 'SMS',
            };
            return ('💬 $appLabel → $contact', '$appLabel envoyé à $contact');
          },
          message: (a) {
            final execResult = actionResult?.executionResult;
            // Contact non validé → message non envoyé
            if (execResult != null && !execResult.success) {
              return ('⏳ → ${a.recipient} ?', 'Veuillez d\'abord confirmer le contact ${a.recipient}');
            }
            final meta = execResult?.metadata;
            final app = meta?['app'] as String?;
            final contact = meta?['contact'] as String? ?? a.recipient;
            final appLabel = switch (app) {
              'whatsapp' => 'WhatsApp',
              'telegram' => 'Telegram',
              'signal' => 'Signal',
              'messenger' => 'Messenger',
              _ => 'SMS',
            };
            return ('💬 $appLabel → $contact', '$appLabel envoyé à $contact');
          },
          navigation: (a) {
            final meta = actionResult?.executionResult?.metadata;
            final briefingSpoken = meta?['briefingSpoken'] == true;
            if (briefingSpoken) return ('🗺️ GPS → ${a.destination}', '');
            return ('🗺️ GPS → ${a.destination}', 'Navigation vers ${a.destination}');
          },
          media: (a) {
            final tts = switch (a.controlType) {
              MediaControlType.play => 'Musique lancée !',
              MediaControlType.pause => 'Musique en pause',
              MediaControlType.playPause => 'Musique lancée !',
              MediaControlType.next => 'Piste suivante',
              MediaControlType.previous => 'Piste précédente',
              MediaControlType.stop => 'Musique arrêtée',
              MediaControlType.playSearch => 'Musique lancée !',
              MediaControlType.like => 'Titre liké !',
              MediaControlType.transfer => 'Lecture transférée',
            };
            return ('🎵 ${a.controlType.name}', tts);
          },
          appLaunch: (a) => ('📱 ${a.appName}', 'Application ${a.appName} lancée'),
          payment: (a) {
            final execResult = actionResult?.executionResult;
            if (execResult != null && !execResult.success) {
              final msg = execResult.message;
              if (msg.contains('non confirmé') || msg.contains('introuvable')) {
                return ('⏳ → ${a.recipient} ?', 'Veuillez d\'abord confirmer le contact ${a.recipient}');
              }
              if (msg.contains('non configuré')) {
                return ('❌ Paiement', 'IBAN non configuré');
              }
              return ('❌ Paiement', msg);
            }
            final contact = execResult?.metadata?['contact'] as String? ?? a.recipient;
            final amt = a.amount.toStringAsFixed(a.amount == a.amount.roundToDouble() ? 0 : 2);
            final noteStr = a.note != null ? ' pour ${a.note}' : '';
            return ('💸 $amt€ → $contact$noteStr', 'Merci de valider le paiement');
          },
          none: (a) => (a.memo ?? '', ''),
        );

        // Construire le JSON de l'action pour affichage structuré dans la fiche
        final actionMap = actionResult.action.toJson();
        final resolved = actionResult.executionResult?.metadata;
        if (resolved != null && resolved.isNotEmpty) {
          actionMap['resolved'] = resolved;
        }

        // Mettre à jour la note avec le résumé et le JSON de l'action
        updatedNote = updatedNote.copyWith(
          summary: summary,
          isAnalyzing: false,
          actionJson: jsonEncode(actionMap),
        );
        await _databaseService.updateNote(updatedNote);

        // Feedback audio TTS (confirmer l'action à l'utilisateur)
        // SAUF pour les commandes média (play/next/previous/playSearch) :
        // le TTS prend l'audio focus Android et met Spotify en pause,
        // puis Spotify ne reprend pas automatiquement. La musique elle-même
        // est le feedback suffisant pour ces commandes.
        final skipTts = actionResult.action is MediaAction &&
            [MediaControlType.play, MediaControlType.playPause,
             MediaControlType.next, MediaControlType.previous,
             MediaControlType.playSearch]
                .contains((actionResult.action as MediaAction).controlType);

        if (ttsMessage.isNotEmpty && !skipTts) {
          final execSuccess = actionResult.executionResult?.success ?? true;
          if (execSuccess) {
            await _audioFeedback.speak(ttsMessage);
          } else if (actionResult.action.intent == ActionIntent.message ||
                     actionResult.action.intent == ActionIntent.sms ||
                     actionResult.action.intent == ActionIntent.messaging ||
                     actionResult.action.intent == ActionIntent.call ||
                     actionResult.action.intent == ActionIntent.payment) {
            // Pending validation → message amical (pas "Erreur.")
            await _audioFeedback.speak(ttsMessage);
          } else {
            await _audioFeedback.announceError(
              actionResult.executionResult?.message ?? 'Action échouée',
            );
          }
        }

        // Créer une fiche MEMO pour tracer les paiements réussis
        if (actionResult.action is PaymentAction &&
            (actionResult.executionResult?.success ?? false)) {
          final pa = actionResult.action as PaymentAction;
          final contact = actionResult.executionResult?.metadata?['contact'] as String? ?? pa.recipient;
          final amt = pa.amount.toStringAsFixed(pa.amount == pa.amount.roundToDouble() ? 0 : 2);
          final noteStr = pa.note != null ? ' (${pa.note})' : '';
          final fiche = Fiche.fromAnalysis(
            title: '💸 $amt€ → $contact$noteStr',
            category: NoteCategory.memo,
            content: 'Demande de remboursement de $amt€ à $contact$noteStr',
            sourceNoteId: updatedNote.id,
          );
          final ficheId = await _databaseService.insertFiche(fiche);
          if (updatedNote.id != null) {
            await _databaseService.linkNoteToFiche(updatedNote.id!, ficheId);
          }
          // ignore: avoid_print
          print('LOCAL_ACTION: Fiche MEMO paiement créée (id=$ficheId)');
        }

        // Enregistrer l'action dans l'historique Google (même sans sync)
        if (_googleBridgeService.isConnected) {
          final intent = actionResult.action.intent;
          final categoryForHistory = switch (intent) {
            ActionIntent.calendar => NoteCategory.event,
            ActionIntent.sms || ActionIntent.messaging || ActionIntent.message ||
            ActionIntent.call => NoteCategory.contact,
            ActionIntent.payment => NoteCategory.memo,
            _ => NoteCategory.memo,
          };
          _googleBridgeService.addActionToHistory(
            category: categoryForHistory,
            title: summary,
            success: actionResult.executionResult?.success ?? true,
          );
        }

        // ignore: avoid_print
        print('LOCAL_ACTION: Terminé');
        return; // Ne pas créer de fiche pour les autres actions locales
      }

      // ignore: avoid_print
      print('LOCAL_ACTION: Pas d\'action locale, passage au système de fiches...');
      // ===========================================================================

      // ÉTAPE 2: Récupérer les fiches existantes pour la déduplication locale (TitleMatcher)
      // Note: non envoyées à l'API Groq — la catégorisation est purement textuelle.
      final existingFiches = await _databaseService.getAllFiches();
      final fichesContext = existingFiches.map((f) => FicheContext(
        id: f.id!,
        title: f.title,
        category: f.category.name,
      )).toList();

      // ÉTAPE 3: Analyse intelligente Llama 3 (transcription uniquement, ~600 tokens)
      // ignore: avoid_print
      print('AI_ANALYSIS: Envoi à Groq Llama 3...');
      final analysis = await _aiSorterService.analyzeText(result.text);
      // ignore: avoid_print
      print('AI_ANALYSIS: Catégorie=${analysis.category.name}, Titre="${analysis.summary}"');

      // ÉTAPE 4: Fusion automatique côté application (pas IA)
      // Chercher une fiche existante avec titre similaire et même catégorie
      final matchingFicheId = TitleMatcher.findMatchingFiche(
        analysis.summary,
        analysis.category,
        fichesContext,
      );

      int? ficheId;
      if (matchingFicheId != null) {
        // APPEND: Fiche similaire trouvée
        final existingFiche = await _databaseService.getFicheById(matchingFicheId);

        if (existingFiche != null) {
          // ignore: avoid_print
          print('FICHE: APPEND auto à "${existingFiche.title}" (id: ${existingFiche.id})');

          var updatedFiche = existingFiche.addSourceNote(note.id!);

          // Ajouter les items si c'est une TODO
          if (analysis.items.isNotEmpty) {
            updatedFiche = updatedFiche.appendItems(analysis.items);
          }

          // Ajouter le contenu
          if (analysis.content.isNotEmpty) {
            updatedFiche = updatedFiche.appendContent(analysis.content);
          }

          // Mettre à jour les infos contact si présentes
          if (analysis.contactFirstName != null || analysis.contactLastName != null ||
              analysis.contactPhone != null || analysis.contactEmail != null ||
              analysis.contactBuildingCode != null) {
            updatedFiche = updatedFiche.copyWith(
              contactFirstName: analysis.contactFirstName ?? updatedFiche.contactFirstName,
              contactLastName: analysis.contactLastName ?? updatedFiche.contactLastName,
              contactPhone: analysis.contactPhone ?? updatedFiche.contactPhone,
              contactEmail: analysis.contactEmail ?? updatedFiche.contactEmail,
              contactBuildingCode: analysis.contactBuildingCode ?? updatedFiche.contactBuildingCode,
            );
          }

          // Mettre à jour le lieu/date si présents
          if (analysis.eventLocation != null || analysis.eventDateTime != null) {
            final parsedDateTime = analysis.eventDateTime != null
                ? DateParser.parseRelativeDate(analysis.eventDateTime!)
                : null;
            updatedFiche = updatedFiche.copyWith(
              eventLocation: analysis.eventLocation ?? updatedFiche.eventLocation,
              eventDateTime: parsedDateTime ?? updatedFiche.eventDateTime,
            );
          }

          await _databaseService.updateFiche(updatedFiche);
          ficheId = existingFiche.id;
        }
      }

      if (ficheId == null) {
        // CREATE: Nouvelle fiche
        // ignore: avoid_print
        print('FICHE: CREATE nouvelle fiche "${analysis.summary}"');

        // Parser la date relative en date absolue si présente
        final parsedDateTime = analysis.eventDateTime != null
            ? DateParser.parseRelativeDate(analysis.eventDateTime!)
            : null;

        final newFiche = Fiche.fromAnalysis(
          title: analysis.summary,
          category: analysis.category,
          content: analysis.content,
          todoItems: analysis.items.isNotEmpty ? analysis.items : null,
          eventDateTime: parsedDateTime,
          eventLocation: analysis.eventLocation,
          contactFirstName: analysis.contactFirstName,
          contactLastName: analysis.contactLastName,
          contactPhone: analysis.contactPhone,
          contactEmail: analysis.contactEmail,
          contactBuildingCode: analysis.contactBuildingCode,
          sourceNoteId: note.id,
        );
        ficheId = await _databaseService.insertFiche(newFiche);
        // ignore: avoid_print
        print('FICHE: Créée avec id: $ficheId');
      }

      // ÉTAPE 5: Mise à jour finale de la note vocale
      // Garder le texte original si content est vide
      final noteText = analysis.content.isNotEmpty ? analysis.content : result.text;

      updatedNote = updatedNote.copyWith(
        text: noteText,
        summary: analysis.summary,
        category: analysis.category,
        isAnalyzing: false,
        eventDateTime: analysis.eventDateTime,
        contactName: analysis.contactFullName,
      );
      await _databaseService.updateNote(updatedNote);

      // Lier la note à la fiche
      if (note.id != null) {
        await _databaseService.linkNoteToFiche(note.id!, ficheId);
      }

      // ignore: avoid_print
      print('PIPELINE: Terminé - Note liée à fiche $ficheId');

      // ÉTAPE 6: Sync vers le service configuré (local ou Google)
      // Les services locaux (Samsung, Todoist) fonctionnent sans connexion Google.
      // ignore: avoid_print
      print('GOOGLE_SYNC: Synchronisation ${analysis.category.name}...');
      final googleId = await _googleBridgeService.syncAnalysisResult(analysis);
      if (googleId != null) {
        // ignore: avoid_print
        print('GOOGLE_SYNC: Succès - ID: $googleId');
        // Figer le service dans actionJson pour affichage historique sur la fiche
        try {
          final svcLabel = _serviceLabel(googleId, analysis.category);
          final rawJson = updatedNote.actionJson ?? '{}';
          final map = jsonDecode(rawJson) as Map<String, dynamic>;
          final params = Map<String, dynamic>.from(map['params'] as Map? ?? {});
          params['syncedService'] = svcLabel;
          map['params'] = params;
          final noteWithService = updatedNote.copyWith(actionJson: jsonEncode(map));
          await _databaseService.updateNote(noteWithService);
        } catch (_) {}
      } else {
        // ignore: avoid_print
        print('GOOGLE_SYNC: Non applicable (non connecté ou service non configuré)');
      }

      // ÉTAPE 7: Feedback audio TTS pour confirmer l'enregistrement
      final categoryName = analysis.category.name;
      String ttsConfirmation;
      switch (categoryName) {
        case 'todo':
          ttsConfirmation = 'Tâche enregistrée: ${analysis.summary}';
          break;
        case 'shopping':
          ttsConfirmation = 'Ajouté à la liste de courses';
          break;
        case 'event':
          ttsConfirmation = 'Événement noté: ${analysis.summary}';
          break;
        case 'contact':
          ttsConfirmation = 'Contact enregistré: ${analysis.summary}';
          break;
        case 'memo':
        default:
          ttsConfirmation = 'Note enregistrée';
          break;
      }
      await _audioFeedback.speak(ttsConfirmation);
    } catch (e) {
      // ignore: avoid_print
      print('PIPELINE ERREUR: $e');
      // ignore: avoid_print
      print('PIPELINE: Note gardée en attente pour retry');

      // Feedback d'erreur
      await _audioFeedback.announceError('Erreur de traitement');
    }
    // Note: Le wake lock est géré par BleService (actif tant que connecté)
  }

  /// Retente le traitement des notes en attente.
  ///
  /// Gère les notes en attente de transcription ET d'analyse.
  /// À appeler quand l'app revient au premier plan.
  ///
  /// Protégé contre l'exécution concurrente : si un retry est déjà en cours
  /// (ex. lifecycle resume rapide dû à l'overlay AssistantActivity), l'appel
  /// est ignoré silencieusement.
  Future<void> retryPendingTranscriptions() async {
    if (_isRetrying) {
      // ignore: avoid_print
      print('RETRY: Déjà en cours, appel ignoré');
      return;
    }
    _isRetrying = true;

    try {
      await _retryPendingTranscriptionsInternal();
    } finally {
      _isRetrying = false;
    }
  }

  Future<void> _retryPendingTranscriptionsInternal() async {
    // ignore: avoid_print
    print('RETRY: Recherche des notes en attente...');

    final allNotes = await _databaseService.getAllNotes();

    // Notes en attente de transcription
    final pendingTranscription = allNotes.where((n) => n.isTranscribing && n.text.isEmpty).toList();

    // Notes en attente d'analyse :
    // - isAnalyzing=true (pipeline interrompu)
    // - MAIS exclure les notes déjà traitées par une action locale (actionJson non null)
    //   → elles ne passent jamais par l'AI sorter
    // - La condition summary.isEmpty est retirée : trop large, peut boucler indéfiniment
    //   si l'AI sorter produit un summary vide ou si la note a été partiellement mise à jour.
    final pendingAnalysis = allNotes.where((n) {
      if (!n.isAnalyzing) return false;           // Uniquement les notes explicitement en attente
      if (n.actionJson != null) return false;     // Déjà traitée par action locale
      if (n.text.isEmpty) return false;           // Pas encore transcrite → chemin transcription
      return true;
    }).toList();

    if (pendingTranscription.isEmpty && pendingAnalysis.isEmpty) {
      // ignore: avoid_print
      print('RETRY: Aucune note en attente');
      return;
    }

    // ignore: avoid_print
    print('RETRY: ${pendingTranscription.length} transcription(s), ${pendingAnalysis.length} analyse(s) en attente');

    // Traiter les transcriptions en attente
    for (final note in pendingTranscription) {
      try {
        final file = File(note.audioPath);
        if (!await file.exists()) {
          // ignore: avoid_print
          print('RETRY: Fichier manquant pour note ${note.id}');
          continue;
        }

        final wavData = await file.readAsBytes();
        // ignore: avoid_print
        print('RETRY: Traitement complet de la note ${note.id}...');

        // Pipeline complet: transcription + analyse
        await _transcribeAndUpdate(note, wavData);
        // ignore: avoid_print
        print('RETRY: Note ${note.id} traitée avec succès!');
      } catch (e) {
        // ignore: avoid_print
        print('RETRY: Échec pour note ${note.id}: $e');
      }
    }

    // Traiter les analyses en attente (notes déjà transcrites)
    for (final note in pendingAnalysis) {
      try {
        // ignore: avoid_print
        print('RETRY: Analyse de la note ${note.id}...');

        // Récupérer les fiches existantes pour la déduplication locale (TitleMatcher)
        final existingFiches = await _databaseService.getAllFiches();
        final fichesContext = existingFiches.map((f) => FicheContext(
          id: f.id!,
          title: f.title,
          category: f.category.name,
        )).toList();

        final analysis = await _aiSorterService.analyzeText(note.text);

        // Fusion automatique côté application
        final matchingFicheId = TitleMatcher.findMatchingFiche(
          analysis.summary,
          analysis.category,
          fichesContext,
        );

        int? ficheId;
        if (matchingFicheId != null) {
          final existingFiche = await _databaseService.getFicheById(matchingFicheId);
          if (existingFiche != null) {
            var updatedFiche = existingFiche.addSourceNote(note.id!);
            if (analysis.items.isNotEmpty) {
              updatedFiche = updatedFiche.appendItems(analysis.items);
            }
            if (analysis.content.isNotEmpty) {
              updatedFiche = updatedFiche.appendContent(analysis.content);
            }
            if (analysis.eventLocation != null || analysis.eventDateTime != null) {
              final parsedDateTime = analysis.eventDateTime != null
                  ? DateParser.parseRelativeDate(analysis.eventDateTime!)
                  : null;
              updatedFiche = updatedFiche.copyWith(
                eventLocation: analysis.eventLocation ?? updatedFiche.eventLocation,
                eventDateTime: parsedDateTime ?? updatedFiche.eventDateTime,
              );
            }
            await _databaseService.updateFiche(updatedFiche);
            ficheId = existingFiche.id;
            // ignore: avoid_print
            print('RETRY: APPEND auto à "${existingFiche.title}"');
          }
        }

        if (ficheId == null) {
          final parsedDateTime = analysis.eventDateTime != null
              ? DateParser.parseRelativeDate(analysis.eventDateTime!)
              : null;

          final newFiche = Fiche.fromAnalysis(
            title: analysis.summary,
            category: analysis.category,
            content: analysis.content,
            todoItems: analysis.items.isNotEmpty ? analysis.items : null,
            eventDateTime: parsedDateTime,
            eventLocation: analysis.eventLocation,
            contactFirstName: analysis.contactFirstName,
            contactLastName: analysis.contactLastName,
            contactPhone: analysis.contactPhone,
            contactEmail: analysis.contactEmail,
            contactBuildingCode: analysis.contactBuildingCode,
            sourceNoteId: note.id,
          );
          ficheId = await _databaseService.insertFiche(newFiche);
          // ignore: avoid_print
          print('RETRY: Fiche créée avec id: $ficheId');
        }

        // Garder le texte original si content est vide
        final noteText = analysis.content.isNotEmpty ? analysis.content : note.text;

        final updatedNote = note.copyWith(
          text: noteText,
          summary: analysis.summary,
          category: analysis.category,
          isAnalyzing: false,
          eventDateTime: analysis.eventDateTime,
          contactName: analysis.contactFullName,
        );
        await _databaseService.updateNote(updatedNote);

        // Lier la note à la fiche
        if (note.id != null) {
          await _databaseService.linkNoteToFiche(note.id!, ficheId);
        }

        // ignore: avoid_print
        print('RETRY: Note ${note.id} analysée et fiche créée!');
      } catch (e) {
        // ignore: avoid_print
        print('RETRY: Échec analyse pour note ${note.id}: $e');
        // Marquer la note comme erreur pour éviter une boucle infinie de retries
        try {
          final failed = note.copyWith(
            isAnalyzing: false,
            errorMessage: 'Analyse échouée: $e',
          );
          await _databaseService.updateNote(failed);
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------------
  // LECTURE AUDIO
  // ---------------------------------------------------------------------------

  /// Lit une note vocale
  ///
  /// [note] La note à lire
  ///
  /// Si une autre note est en cours de lecture, elle est arrêtée.
  Future<void> playNote(VoiceNote note) async {
    // Arrêter la lecture en cours
    if (_currentlyPlayingId != null) {
      await stopPlayback();
    }

    // Vérifier que le fichier existe
    final file = File(note.audioPath);
    if (!await file.exists()) {
      throw Exception('Fichier audio introuvable: ${note.audioPath}');
    }

    // Lancer la lecture
    _currentlyPlayingId = note.id;
    _playbackStateController.add(note.id);

    await _audioPlayer.play(DeviceFileSource(note.audioPath));
  }

  /// Met en pause la lecture
  Future<void> pausePlayback() async {
    await _audioPlayer.pause();
  }

  /// Reprend la lecture
  Future<void> resumePlayback() async {
    await _audioPlayer.resume();
  }

  /// Arrête la lecture
  Future<void> stopPlayback() async {
    await _audioPlayer.stop();
    _currentlyPlayingId = null;
    _playbackStateController.add(null);
  }

  /// Vérifie si une note est en cours de lecture
  bool isPlaying(int? noteId) {
    return noteId != null && _currentlyPlayingId == noteId;
  }

  // ---------------------------------------------------------------------------
  // ENREGISTREMENT DEPUIS LE TÉLÉPHONE
  // ---------------------------------------------------------------------------

  /// Vérifie si la permission microphone est accordée
  Future<bool> checkMicrophonePermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    final result = await Permission.microphone.request();
    return result.isGranted;
  }

  /// Démarre l'enregistrement depuis le microphone du téléphone
  Future<bool> startRecording() async {
    if (_isRecording) return false;

    // Vérifier la permission
    final hasPermission = await checkMicrophonePermission();
    if (!hasPermission) {
      // ignore: avoid_print
      print('RECORD: Permission microphone refusée');
      return false;
    }

    // Vérifier si l'enregistrement est possible
    if (!await _audioRecorder.hasPermission()) {
      // ignore: avoid_print
      print('RECORD: Pas de permission pour enregistrer');
      return false;
    }

    // Vérifier si la musique joue et la mettre en pause si nécessaire.
    // Si le flag est déjà true (session dictée multi-segments), la musique
    // est déjà gérée → on ne re-vérifie pas pour ne pas écraser l'état.
    if (!_musicWasPlayingBeforeRecording) {
      try {
        final rawMusicActive = await _localMediaService.isMusicActive();
        final cobaltTtsSpeaking = _audioFeedback.isSpeaking;
        // ignore: avoid_print
        print('RECORD: isMusicActive=$rawMusicActive | cobaltTTS=$cobaltTtsSpeaking');

        // Exclure le TTS de Cobalt lui-même
        _musicWasPlayingBeforeRecording = rawMusicActive && !cobaltTtsSpeaking;

        if (_musicWasPlayingBeforeRecording) {
          await _localMediaService.pause();
          // ignore: avoid_print
          print('RECORD: Musique utilisateur mise en pause');
        } else if (rawMusicActive && cobaltTtsSpeaking) {
          // ignore: avoid_print
          print('RECORD: Audio actif = TTS Cobalt uniquement → pas de pause musique');
          await _audioFeedback.stop();
        } else {
          // ignore: avoid_print
          print('RECORD: Pas de musique en cours');
        }
      } catch (e) {
        // ignore: avoid_print
        print('RECORD: Erreur vérification musique: $e (continue sans pause)');
        _musicWasPlayingBeforeRecording = false;
      }
    } else {
      // ignore: avoid_print
      print('RECORD: Musique déjà trackée (segment dictée), skip check');
    }

    try {
      // Générer le chemin du fichier
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'note_$timestamp.wav';
      final filePath = path.join(_audioDirectory!.path, filename);

      // Configuration de l'enregistrement (WAV 16kHz mono pour Whisper)
      const config = RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      );

      await _audioRecorder.start(config, path: filePath);
      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _recordingStateController.add(true);

      // Son de début d'enregistrement
      _audioFeedback.playStartSound();

      // ignore: avoid_print
      print('RECORD: Enregistrement démarré → $filePath');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('RECORD ERREUR: $e');
      return false;
    }
  }

  /// Arrête l'enregistrement et traite le fichier audio
  /// Stoppe l'enregistrement et retourne le chemin du fichier WAV
  /// SANS creer de VoiceNote ni lancer le pipeline IA.
  /// Utilise par DictationService pour le mode dictee.
  Future<String?> stopRecordingRaw() async {
    if (!_isRecording) return null;

    try {
      final filePath = await _audioRecorder.stop();
      _isRecording = false;
      _recordingStateController.add(false);
      // NOTE: on ne reprend PAS la musique ici — c'est le rôle de
      // resumeMusic() appelé explicitement par DictationService à la fin
      // de la session (pas entre chaque segment intermédiaire).
      _recordingStartTime = null;

      if (filePath == null) {
        // ignore: avoid_print
        print('RECORD: stopRecordingRaw - arret sans fichier');
        return null;
      }

      // ignore: avoid_print
      print('RECORD: stopRecordingRaw → $filePath');
      return filePath;
    } catch (e) {
      // ignore: avoid_print
      print('RECORD ERREUR stopRecordingRaw: $e');
      _isRecording = false;
      _recordingStateController.add(false);
      return null;
    }
  }

  /// Reprend la musique si elle était en lecture avant la session dictée.
  /// Appelé explicitement par DictationService à la fin de la dictée.
  Future<void> resumeMusic() => _resumeMusicAfterRecording();

  /// Public wrapper pour DictationService : retourne true si le WAV est silencieux.
  bool isWavSilent(Uint8List wavData) => _isWavSilent(wavData);

  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      final filePath = await _audioRecorder.stop();
      _isRecording = false;
      _recordingStateController.add(false);

      // Son de fin d'enregistrement
      _audioFeedback.playStopSound();

      // Reprendre la musique après l'enregistrement
      _resumeMusicAfterRecording();

      if (filePath == null) {
        // ignore: avoid_print
        print('RECORD: Arrêt sans fichier');
        return;
      }

      // ignore: avoid_print
      print('RECORD: Enregistrement arrêté → $filePath');

      // Calculer la durée
      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!).inSeconds
          : 0;
      _recordingStartTime = null;

      // Ignorer les enregistrements trop courts (< 1 seconde)
      if (duration < 1) {
        // ignore: avoid_print
        print('RECORD: Enregistrement trop court, ignoré');
        final file = File(filePath);
        if (await file.exists()) await file.delete();
        return;
      }

      // Créer une note en attente de transcription
      var note = VoiceNote.pending(
        audioPath: filePath,
        duration: duration,
      );
      final noteId = await _databaseService.insertNote(note);
      note = note.copyWith(id: noteId);
      // ignore: avoid_print
      print('RECORD: Note créée en base (id: $noteId)');

      // Transcrire
      final file = File(filePath);
      final wavData = await file.readAsBytes();

      // Enregistrement silencieux → garder la fiche en grisé
      if (_isWavSilent(wavData)) {
        final silentNote = note.copyWith(
          text: '',
          summary: 'Enregistrement silencieux',
          isTranscribing: false,
          isAnalyzing: false,
          errorMessage: 'silence',
        );
        await _databaseService.updateNote(silentNote);
        // ignore: avoid_print
        print('RECORD: Enregistrement silencieux (fiche grisée)');
        return;
      }

      // ignore: avoid_print
      print('RECORD: Lancement de la transcription Groq...');
      _transcribeAndUpdate(note, wavData);
    } catch (e) {
      // ignore: avoid_print
      print('RECORD ERREUR: $e');
      _isRecording = false;
      _recordingStateController.add(false);
    }
  }

  /// Reprend la musique après l'enregistrement (seulement si elle jouait avant)
  Future<void> _resumeMusicAfterRecording() async {
    // Ne reprendre que si la musique jouait avant l'enregistrement
    if (!_musicWasPlayingBeforeRecording) {
      // ignore: avoid_print
      print('RECORD: Pas de reprise (musique ne jouait pas avant)');
      return;
    }

    // Attendre un court délai pour que l'enregistrement soit bien terminé
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      // Envoyer une commande play pour reprendre la musique
      final result = await _localMediaService.play();
      // ignore: avoid_print
      print('RECORD: Reprise de la musique - ${result.success ? "OK" : result.error}');
    } catch (e) {
      // ignore: avoid_print
      print('RECORD: Erreur reprise musique: $e');
    } finally {
      // Reset du flag
      _musicWasPlayingBeforeRecording = false;
    }
  }

  /// Annule l'enregistrement en cours sans sauvegarder
  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    try {
      final filePath = await _audioRecorder.stop();
      _isRecording = false;
      _recordingStartTime = null;
      _recordingStateController.add(false);

      // Supprimer le fichier
      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) await file.delete();
      }

      // ignore: avoid_print
      print('RECORD: Enregistrement annulé');
    } catch (e) {
      // ignore: avoid_print
      print('RECORD ERREUR: $e');
      _isRecording = false;
      _recordingStateController.add(false);
    }
  }

  /// Retourne l'amplitude actuelle du microphone (dBFS).
  /// Necessite qu'un enregistrement soit en cours.
  /// Utilise par CobaltOverlayService pour les barres sonores.
  Future<Amplitude> getAmplitude() async {
    return await _audioRecorder.getAmplitude();
  }

  // ---------------------------------------------------------------------------
  // GESTION DES FICHIERS
  // ---------------------------------------------------------------------------

  /// Supprime le fichier audio d'une note
  Future<void> deleteAudioFile(String audioPath) async {
    final file = File(audioPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Calcule l'espace disque utilisé par les fichiers audio
  Future<int> getStorageUsedBytes() async {
    if (_audioDirectory == null || !await _audioDirectory!.exists()) {
      return 0;
    }

    int totalSize = 0;
    await for (final entity in _audioDirectory!.list()) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }
    return totalSize;
  }

  /// Formate la taille en texte lisible
  String formatStorageSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------------------
  // CONTRÔLE BLE
  // ---------------------------------------------------------------------------

  /// Lance le scan BLE
  Future<void> startBleScan() async {
    await _bleService.startScan();
  }

  /// Scan rapide de navigation (device picker)
  Future<void> startBrowseScan() async => _bleService.startBrowseScan();
  Future<void> stopBrowseScan() async => _bleService.stopBrowseScan();

  /// Déclenche une tentative de reconnexion immédiate (appeler depuis foreground resume)
  void triggerBleReconnect() {
    _bleService.triggerReconnect();
  }

  /// Déconnecte l'appareil BLE
  Future<void> disconnectBle() async {
    await _bleService.disconnect();
  }

  /// Connecte un appareil BLE spécifique choisi par l'utilisateur
  Future<void> connectToBleDevice(BluetoothDevice device, {String? deviceName}) async {
    await _bleService.connectToDevice(device, deviceName: deviceName);
  }

  /// Stream de l'état de connexion BLE
  Stream<BleConnectionState> get bleConnectionStateStream =>
      _bleService.connectionStateStream;

  /// État actuel de la connexion BLE
  BleConnectionState get bleConnectionState => _bleService.connectionState;

  /// Nom de l'appareil BLE connecté (ex: "Cobalt A3F2")
  String? get connectedDeviceName => _bleService.connectedDeviceName;

  /// Version firmware de l'appareil connecté (ex: "1.0.0")
  String? get firmwareVersion => _bleService.firmwareVersion;

  /// Accès au service BLE (pour l'écran debug et DFU)
  BleService get bleServiceInstance => _bleService;

  /// ID du device appairé (null si aucun)
  String? get selectedDeviceId => _bleService.selectedDeviceId;

  /// Stream des appareils découverts (pour le device picker)
  Stream<List<ScanResult>> get discoveredDevicesStream =>
      _bleService.discoveredDevicesStream;

  /// Liste actuelle des appareils découverts
  List<ScanResult> get discoveredDevices => _bleService.discoveredDevices;

  /// Stream de progression du transfert
  Stream<double> get transferProgressStream => _bleService.transferProgressStream;

  /// Stream du niveau de batterie (0-100, -1 si non disponible)
  Stream<int> get batteryLevelStream => _bleService.batteryLevelStream;

  /// Niveau de batterie actuel
  int get batteryLevel => _bleService.batteryLevel;

  /// Stream de l'état de charge (true = bracelet en charge USB)
  Stream<bool> get chargingStream => _bleService.chargingStream;

  /// État de charge actuel
  bool get isCharging => _bleService.isCharging;

  // ---------------------------------------------------------------------------
  // CONTRÔLE GOOGLE
  // ---------------------------------------------------------------------------

  /// Vérifie si connecté à Google
  bool get isGoogleConnected => _googleBridgeService.isConnected;

  /// Email de l'utilisateur Google
  String? get googleUserEmail => _googleBridgeService.userEmail;

  /// Nom de l'utilisateur Google
  String? get googleUserName => _googleBridgeService.userName;

  /// Stream de l'état de connexion Google
  Stream<bool> get googleConnectionStateStream =>
      _googleBridgeService.connectionStateStream;

  /// Stream de l'historique des actions Google
  Stream<List<SyncAction>> get googleHistoryStream =>
      _googleBridgeService.historyStream;

  /// Historique des actions Google
  List<SyncAction> get googleActionHistory =>
      _googleBridgeService.actionHistory;

  /// Connecte l'utilisateur à Google
  Future<bool> signInGoogle() async {
    return await _googleBridgeService.signIn();
  }

  /// Déconnecte l'utilisateur de Google
  Future<void> signOutGoogle() async {
    await _googleBridgeService.signOut();
  }

  /// URL du Journal Cobalt (Google Docs)
  String? get journalUrl => _googleBridgeService.journalUrl;

  // ---------------------------------------------------------------------------
  // CONTRÔLE SPOTIFY
  // ---------------------------------------------------------------------------

  /// Vérifie si connecté à Spotify
  bool get isSpotifyConnected =>
      _localMediaService.spotifyService.isConnected;

  /// Stream de l'état de connexion Spotify
  Stream<bool> get spotifyConnectionStream =>
      _localMediaService.spotifyService.connectionStream;

  /// Connecte l'utilisateur à Spotify (ouvre le navigateur OAuth)
  Future<void> connectSpotify() async {
    // ignore: avoid_print
    print('[AudioService] connectSpotify() appelé');
    await _localMediaService.spotifyService.login();
    // ignore: avoid_print
    print('[AudioService] connectSpotify() terminé');
  }

  /// Déconnecte l'utilisateur de Spotify
  Future<void> disconnectSpotify() async {
    await _localMediaService.spotifyService.disconnect();
  }

  /// État du lecteur Spotify (morceau en cours, etc.)
  Future<Map<String, dynamic>?> getSpotifyPlayerState() async {
    return await _localMediaService.spotifyService.getPlayerState();
  }

  /// Contrôles Spotify
  Future<void> spotifyPlay() async => _localMediaService.spotifyService.play();
  Future<void> spotifyPause() async => _localMediaService.spotifyService.pause();
  Future<void> spotifyNext() async => _localMediaService.spotifyService.next();
  Future<void> spotifyPrevious() async => _localMediaService.spotifyService.previous();
  Future<void> spotifyLike() async => _localMediaService.spotifyService.likeCurrentTrack();
  Future<List<Map<String, dynamic>>> spotifyGetDevices() => _localMediaService.spotifyService.getDevices();
  Future<void> spotifyTransferPlayback(String id) => _localMediaService.spotifyService.transferPlayback(id);

  /// Contrôles MediaKey génériques (Deezer, YouTube Music)
  Future<void> mediaPlayPause() => _localMediaService.execute(controlType: MediaControlType.playPause);
  Future<void> mediaNext() => _localMediaService.execute(controlType: MediaControlType.next);
  Future<void> mediaPrevious() => _localMediaService.execute(controlType: MediaControlType.previous);

  // ---------------------------------------------------------------------------
  // NETTOYAGE
  // ---------------------------------------------------------------------------

  /// Traduit un googleId/localId retourné par syncFiche en nom d'app lisible.
  String _serviceLabel(String googleId, NoteCategory category) {
    return switch (googleId) {
      'local_samsung_reminder'  => 'Samsung Reminders',
      'local_samsung_calendar'  => 'Samsung Calendar',
      'local_todoist'           => 'Todoist',
      'local_samsung'           => 'Samsung Notes',
      'local_notion'            => 'Notion',
      'local_chooser'           => 'Application',
      _ => switch (category) {
        NoteCategory.todo || NoteCategory.shopping => 'Google Tasks',
        NoteCategory.event                         => 'Google Calendar',
        NoteCategory.contact                       => 'Contacts',
        NoteCategory.memo                          => 'Google Tasks',
      },
    };
  }

  /// Libère toutes les ressources
  Future<void> dispose() async {
    await _bleDataSubscription?.cancel();
    await _audioPlayer.dispose();
    await _audioRecorder.dispose();
    await _playbackStateController.close();
    await _recordingStateController.close();
    _googleBridgeService.dispose();
  }
}
