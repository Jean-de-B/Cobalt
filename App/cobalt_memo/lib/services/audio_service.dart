import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:record/record.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_constants.dart';
import '../models/fiche.dart';
import '../models/voice_note.dart';
import 'adpcm_decoder.dart';
import 'ble_service.dart';
import 'ai_sorter_service.dart';
import 'database_service.dart';
import 'foreground_service.dart';
import 'transcription_service.dart';

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
        _foregroundService = CobaltForegroundService(),
        _audioPlayer = AudioPlayer(),
        _audioRecorder = AudioRecorder();

  /// Factory Singleton
  factory AudioService() {
    _instance ??= AudioService._internal();
    return _instance!;
  }

  /// Flag pour reset au prochain démarrage (synchronisé avec database_service)
  static const bool _resetOnNextLaunch = true;

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

    // Initialiser le foreground service (notification persistante)
    try {
      await _foregroundService.initialize();
      // ignore: avoid_print
      print('AUDIO: Foreground service initialisé');
    } catch (e) {
      // ignore: avoid_print
      print('AUDIO: Erreur initialisation foreground service: $e');
    }

    // Écouter les données audio du BLE
    _bleDataSubscription = _bleService.audioDataStream.listen(_processAudioData);

    // Démarrer/arrêter le foreground service selon l'état BLE
    _bleService.connectionStateStream.listen((state) {
      if (state == BleConnectionState.connected) {
        _startForegroundIfNeeded();
      } else if (state == BleConnectionState.disconnected ||
                 state == BleConnectionState.disabled) {
        _stopForegroundIfRunning();
      }
    });

    // Configurer le lecteur audio
    _audioPlayer.onPlayerComplete.listen((_) {
      _currentlyPlayingId = null;
      _playbackStateController.add(null);
    });

    // Auto-connexion BLE au démarrage (sans action utilisateur)
    // ignore: avoid_print
    print('AUDIO: Lancement auto-scan BLE...');
    _bleService.startScan(autoConnect: true);
  }

  // ---------------------------------------------------------------------------
  // FOREGROUND SERVICE
  // ---------------------------------------------------------------------------

  /// Démarre le foreground service si pas déjà actif
  Future<void> _startForegroundIfNeeded() async {
    if (!_foregroundService.isRunning) {
      try {
        await _foregroundService.start();
        // ignore: avoid_print
        print('AUDIO: Foreground service démarré (BLE connecté)');
      } catch (e) {
        // ignore: avoid_print
        print('AUDIO: Erreur démarrage foreground service: $e');
      }
    }
  }

  /// Arrête le foreground service si actif
  Future<void> _stopForegroundIfRunning() async {
    if (_foregroundService.isRunning) {
      try {
        await _foregroundService.stop();
        // ignore: avoid_print
        print('AUDIO: Foreground service arrêté (BLE déconnecté)');
      } catch (e) {
        // ignore: avoid_print
        print('AUDIO: Erreur arrêt foreground service: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // PIPELINE DE TRAITEMENT AUDIO
  // ---------------------------------------------------------------------------

  /// Traite les données audio reçues via BLE
  ///
  /// Cette méthode est appelée automatiquement quand une transmission
  /// audio complète est reçue du firmware.
  Future<void> _processAudioData(Uint8List rawBleData) async {
    // ignore: avoid_print
    print('AUDIO: Données reçues du BLE - ${rawBleData.length} bytes');

    // Notifier via la notification persistante
    _foregroundService.showActionNotification('Mémo reçu, traitement...');

    try {
      // 1. Décoder ADPCM → WAV
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

      // 4. Transcrire de manière asynchrone (sans bloquer)
      // ignore: avoid_print
      print('AUDIO: Lancement de la transcription Groq...');
      _transcribeAndUpdate(note, wavData);
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
  /// 1. Transcription Whisper (texte brut)
  /// 2. Analyse Llama 3 (catégorisation + décision APPEND/CREATE)
  /// 3. Création ou mise à jour de la fiche thématique
  /// 4. Liaison de la note vocale à la fiche
  Future<void> _transcribeAndUpdate(VoiceNote note, Uint8List wavData) async {
    try {
      // ÉTAPE 1: Transcription Whisper
      // ignore: avoid_print
      print('TRANSCRIPTION: Envoi à Groq Whisper (${wavData.length} bytes)...');
      final result = await _transcriptionService.transcribeBytes(
        wavData,
        language: 'fr',
      );
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
    } catch (e) {
      // ignore: avoid_print
      print('PIPELINE ERREUR: $e');
      // ignore: avoid_print
      print('PIPELINE: Note gardée en attente pour retry');
    }
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
  /// Si [autoConnect] est false, collecte les appareils sans se connecter
  Future<void> startBleScan({bool autoConnect = true}) async {
    await _bleService.startScan(autoConnect: autoConnect);
  }

  /// Déconnecte l'appareil BLE
  Future<void> disconnectBle() async {
    await _bleService.disconnect();
  }

  /// Stream de l'état de connexion BLE
  Stream<BleConnectionState> get bleConnectionStateStream =>
      _bleService.connectionStateStream;

  /// État actuel de la connexion BLE
  BleConnectionState get bleConnectionState => _bleService.connectionState;

  /// Stream des appareils découverts pendant le scan
  Stream<List<ScanResult>> get discoveredDevicesStream =>
      _bleService.discoveredDevicesStream;

  /// Liste des appareils découverts
  List<ScanResult> get discoveredDevices => _bleService.discoveredDevices;

  /// Connecte à un appareil BLE spécifique
  Future<void> connectToBleDevice(BluetoothDevice device) async {
    await _bleService.connectToDevice(device);
  }

  /// Stream de progression du transfert
  Stream<double> get transferProgressStream => _bleService.transferProgressStream;

  /// Stream du niveau de batterie (0-100, -1 si non disponible)
  Stream<int> get batteryLevelStream => _bleService.batteryLevelStream;

  /// Niveau de batterie actuel
  int get batteryLevel => _bleService.batteryLevel;

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
  }
}
