import 'dart:async';
import 'dart:io';
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

    // Auto-scan BLE au démarrage (connexion automatique au premier appareil trouvé)
    // ignore: avoid_print
    print('AUDIO: Lancement auto-scan BLE...');
    _bleService.startScan(autoConnect: true);
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

      // 2. Sauvegarder le fichier WAV
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
      _transcribeAndUpdate(note, wavData); // Fire-and-forget (pas de await)
    } catch (e, stackTrace) {
      // Log l'erreur mais ne pas crasher
      // ignore: avoid_print
      print('AUDIO ERREUR: $e');
      print('AUDIO STACK: $stackTrace');
    }
  }

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
  Future<void> _transcribeAndUpdate(VoiceNote note, Uint8List wavData) async {
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
            language: 'fr',
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
        actionResult = await _voiceInputProcessor.processVoiceInput(result.text);
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
                return ('❌ PayPal', 'PayPal n\'est pas encore configuré');
              }
              return ('❌ PayPal', msg);
            }
            final contact = execResult?.metadata?['contact'] as String? ?? a.recipient;
            final amt = a.amount.toStringAsFixed(a.amount == a.amount.roundToDouble() ? 0 : 2);
            final noteStr = a.note != null ? ' pour ${a.note}' : '';
            return ('💸 $amt€ → $contact$noteStr', 'Merci de valider le paiement');
          },
          none: (a) => (a.memo ?? '', ''),
        );

        // Mettre à jour la note avec le résumé de l'action
        updatedNote = updatedNote.copyWith(
          summary: summary,
          isAnalyzing: false,
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
            title: '💸 $amt€ → $contact via PayPal$noteStr',
            category: NoteCategory.memo,
            content: 'Remboursement de $amt€ à $contact via PayPal$noteStr',
            sourceNoteId: updatedNote.id,
          );
          final ficheId = await _databaseService.insertFiche(fiche);
          if (updatedNote.id != null) {
            await _databaseService.linkNoteToFiche(updatedNote.id!, ficheId);
          }
          // ignore: avoid_print
          print('LOCAL_ACTION: Fiche MEMO paiement créée (id=$ficheId)');
        }

        // ignore: avoid_print
        print('LOCAL_ACTION: Terminé');
        return; // Ne pas créer de fiche pour les autres actions locales
      }

      // ignore: avoid_print
      print('LOCAL_ACTION: Pas d\'action locale, passage au système de fiches...');
      // ===========================================================================

      // ÉTAPE 2: Récupérer les fiches existantes pour le contexte
      final existingFiches = await _databaseService.getAllFiches();
      final fichesContext = existingFiches.map((f) => FicheContext(
        id: f.id!,
        title: f.title,
        category: f.category.name,
      )).toList();

      // ÉTAPE 3: Analyse intelligente Llama 3 avec contexte
      // ignore: avoid_print
      print('AI_ANALYSIS: Envoi à Groq Llama 3 (${fichesContext.length} fiches en contexte)...');
      final analysis = await _aiSorterService.analyzeText(
        result.text,
        existingFiches: fichesContext,
      );
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

      // ÉTAPE 6: Sync vers Google (si connecté)
      if (_googleBridgeService.isConnected) {
        // ignore: avoid_print
        print('GOOGLE_SYNC: Synchronisation ${analysis.category.name} vers Google...');
        final googleId = await _googleBridgeService.syncAnalysisResult(analysis);
        if (googleId != null) {
          // ignore: avoid_print
          print('GOOGLE_SYNC: Succès - ID: $googleId');
        } else {
          // ignore: avoid_print
          print('GOOGLE_SYNC: Échec ou non applicable');
        }
      } else {
        // ignore: avoid_print
        print('GOOGLE_SYNC: Non connecté - ${analysis.category.name} non synchronisé');
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

  /// Retente le traitement des notes en attente
  ///
  /// Gère les notes en attente de transcription ET d'analyse.
  /// À appeler quand l'app revient au premier plan.
  Future<void> retryPendingTranscriptions() async {
    // ignore: avoid_print
    print('RETRY: Recherche des notes en attente...');

    final allNotes = await _databaseService.getAllNotes();

    // Notes en attente de transcription
    final pendingTranscription = allNotes.where((n) => n.isTranscribing && n.text.isEmpty).toList();

    // Notes en attente d'analyse (transcrites mais pas analysées)
    final pendingAnalysis = allNotes.where((n) => n.isAnalyzing || (n.text.isNotEmpty && n.summary.isEmpty && !n.isTranscribing)).toList();

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

        // Récupérer les fiches existantes pour le contexte
        final existingFiches = await _databaseService.getAllFiches();
        final fichesContext = existingFiches.map((f) => FicheContext(
          id: f.id!,
          title: f.title,
          category: f.category.name,
        )).toList();

        final analysis = await _aiSorterService.analyzeText(
          note.text,
          existingFiches: fichesContext,
        );

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

    // Vérifier si la musique joue et la mettre en pause si nécessaire
    try {
      _musicWasPlayingBeforeRecording = await _localMediaService.isMusicActive();
      if (_musicWasPlayingBeforeRecording) {
        await _localMediaService.pause();
        // ignore: avoid_print
        print('RECORD: Musique mise en pause (était en lecture)');
      } else {
        // ignore: avoid_print
        print('RECORD: Pas de musique en cours');
      }
    } catch (e) {
      // ignore: avoid_print
      print('RECORD: Erreur vérification musique: $e (continue sans pause)');
      _musicWasPlayingBeforeRecording = false;
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
  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      final filePath = await _audioRecorder.stop();
      _isRecording = false;
      _recordingStateController.add(false);

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

  /// Déconnecte l'appareil BLE
  Future<void> disconnectBle() async {
    await _bleService.disconnect();
  }

  /// Connecte un appareil BLE spécifique choisi par l'utilisateur
  Future<void> connectToBleDevice(BluetoothDevice device) async {
    await _bleService.connectToDevice(device);
  }

  /// Stream de l'état de connexion BLE
  Stream<BleConnectionState> get bleConnectionStateStream =>
      _bleService.connectionStateStream;

  /// État actuel de la connexion BLE
  BleConnectionState get bleConnectionState => _bleService.connectionState;

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

  // ---------------------------------------------------------------------------
  // NETTOYAGE
  // ---------------------------------------------------------------------------

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
