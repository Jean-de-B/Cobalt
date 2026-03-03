import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// =============================================================================
/// sherpa_transcription_service.dart
/// =============================================================================
/// Service de transcription vocale locale utilisant Sherpa-ONNX.
///
/// Remplace Vosk (incompatible AGP 8+) avec une solution moderne et maintenue.
///
/// Fonctionnalités:
/// - Transcription 100% offline (pas de connexion internet requise)
/// - Modèle français Zipformer streaming
/// - Fonctionne en arrière-plan (écran verrouillé)
/// - Support streaming et non-streaming
/// =============================================================================

class SherpaTranscriptionService {
  static SherpaTranscriptionService? _instance;

  bool _isInitialized = false;
  bool _isModelLoaded = false;

  /// Recognizer pour la transcription
  sherpa.OfflineRecognizer? _recognizer;

  /// Répertoire des modèles
  Directory? _modelDirectory;

  /// Nom du modèle français
  static const String _modelName = 'sherpa-onnx-whisper-tiny';

  /// URL de base pour téléchargement des modèles
  static const String _modelBaseUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

  /// Sample rate attendu (16kHz pour Whisper)
  static const int sampleRate = 16000;

  /// Singleton
  factory SherpaTranscriptionService() {
    _instance ??= SherpaTranscriptionService._internal();
    return _instance!;
  }

  SherpaTranscriptionService._internal();

  /// Vérifie si le service est initialisé et prêt
  bool get isReady => _isInitialized && _isModelLoaded;

  /// Initialise le service Sherpa-ONNX
  Future<bool> initialize() async {
    if (_isInitialized) return _isModelLoaded;

    try {
      // ignore: avoid_print
      print('[Sherpa] Initialisation du service STT offline...');

      // Initialiser les bindings Sherpa
      sherpa.initBindings();
      // ignore: avoid_print
      print('[Sherpa] Bindings initialisés');

      // Créer le répertoire des modèles
      final appDir = await getApplicationDocumentsDirectory();
      _modelDirectory = Directory(path.join(appDir.path, 'sherpa_models'));
      if (!await _modelDirectory!.exists()) {
        await _modelDirectory!.create(recursive: true);
      }

      // Vérifier si le modèle est déjà téléchargé
      final modelDir = Directory(path.join(_modelDirectory!.path, _modelName));
      if (await modelDir.exists()) {
        final success = await _loadModel(modelDir.path);
        if (success) {
          _isInitialized = true;
          _isModelLoaded = true;
          // ignore: avoid_print
          print('[Sherpa] Modèle chargé avec succès');
          return true;
        }
      }

      _isInitialized = true;
      // ignore: avoid_print
      print('[Sherpa] Initialisé - Modèle non trouvé, téléchargement requis');
      print('[Sherpa] Fallback vers Whisper cloud en attendant');
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('[Sherpa] Erreur initialisation: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Charge le modèle depuis le répertoire local
  Future<bool> _loadModel(String modelPath) async {
    try {
      // Configuration pour Whisper tiny (modèle compact et rapide)
      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: path.join(modelPath, 'tiny-encoder.int8.onnx'),
            decoder: path.join(modelPath, 'tiny-decoder.int8.onnx'),
            language: 'fr',
            task: 'transcribe',
          ),
          tokens: path.join(modelPath, 'tiny-tokens.txt'),
          modelType: 'whisper',
          debug: false,
          numThreads: 2,
        ),
        ruleFsts: '',
        decodingMethod: 'greedy_search',
      );

      _recognizer = sherpa.OfflineRecognizer(config);
      // ignore: avoid_print
      print('[Sherpa] Recognizer créé avec succès');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[Sherpa] Erreur chargement modèle: $e');
      return false;
    }
  }

  /// Télécharge le modèle français
  /// Retourne true si le téléchargement réussit
  Future<bool> downloadModel({
    Function(double)? onProgress,
  }) async {
    if (!_isInitialized) {
      // ignore: avoid_print
      print('[Sherpa] Service non initialisé');
      return false;
    }

    try {
      // ignore: avoid_print
      print('[Sherpa] Téléchargement du modèle $_modelName...');

      final modelDir = Directory(path.join(_modelDirectory!.path, _modelName));
      if (!await modelDir.exists()) {
        await modelDir.create(recursive: true);
      }

      // Liste des fichiers à télécharger
      final files = [
        'tiny-encoder.int8.onnx',
        'tiny-decoder.int8.onnx',
        'tiny-tokens.txt',
      ];

      final httpClient = HttpClient();
      int downloadedFiles = 0;

      for (final fileName in files) {
        final url = '$_modelBaseUrl/$_modelName/$fileName';
        final filePath = path.join(modelDir.path, fileName);

        // Vérifier si le fichier existe déjà
        if (await File(filePath).exists()) {
          // ignore: avoid_print
          print('[Sherpa] Fichier existant: $fileName');
          downloadedFiles++;
          onProgress?.call(downloadedFiles / files.length);
          continue;
        }

        // ignore: avoid_print
        print('[Sherpa] Téléchargement: $fileName');

        try {
          final request = await httpClient.getUrl(Uri.parse(url));
          final response = await request.close();

          if (response.statusCode == 200) {
            final file = File(filePath);
            final sink = file.openWrite();
            await response.pipe(sink);
            await sink.close();
            // ignore: avoid_print
            print('[Sherpa] Téléchargé: $fileName');
          } else {
            // ignore: avoid_print
            print('[Sherpa] Erreur HTTP ${response.statusCode} pour $fileName');
            return false;
          }
        } catch (e) {
          // ignore: avoid_print
          print('[Sherpa] Erreur téléchargement $fileName: $e');
          return false;
        }

        downloadedFiles++;
        onProgress?.call(downloadedFiles / files.length);
      }

      httpClient.close();

      // Charger le modèle
      final success = await _loadModel(modelDir.path);
      if (success) {
        _isModelLoaded = true;
        // ignore: avoid_print
        print('[Sherpa] Modèle téléchargé et chargé avec succès');
      }

      return success;
    } catch (e) {
      // ignore: avoid_print
      print('[Sherpa] Erreur téléchargement: $e');
      return false;
    }
  }

  /// Transcrit un fichier audio WAV
  Future<String?> transcribeFile(String audioPath) async {
    if (!isReady) {
      // ignore: avoid_print
      print('[Sherpa] Service non prêt');
      return null;
    }

    try {
      final file = File(audioPath);
      if (!await file.exists()) {
        // ignore: avoid_print
        print('[Sherpa] Fichier non trouvé: $audioPath');
        return null;
      }

      final audioData = await file.readAsBytes();
      return transcribeBytes(audioData);
    } catch (e) {
      // ignore: avoid_print
      print('[Sherpa] Erreur transcription fichier: $e');
      return null;
    }
  }

  /// Transcrit des données audio brutes (WAV 16kHz mono)
  Future<String?> transcribeBytes(Uint8List audioData) async {
    if (!isReady || _recognizer == null) {
      // ignore: avoid_print
      print('[Sherpa] Service non prêt pour transcription');
      return null;
    }

    try {
      // Convertir WAV en samples Float32
      final samples = _wavToFloat32(audioData);
      if (samples == null || samples.isEmpty) {
        // ignore: avoid_print
        print('[Sherpa] Échec conversion WAV');
        return null;
      }

      // ignore: avoid_print
      print('[Sherpa] Transcription de ${samples.length} samples...');

      // Créer un stream et transcrire
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);

      // Décoder
      _recognizer!.decode(stream);

      // Récupérer le résultat
      final result = _recognizer!.getResult(stream);
      final text = result.text.trim();

      // Libérer les ressources
      stream.free();

      if (text.isNotEmpty) {
        // ignore: avoid_print
        print('[Sherpa] Transcription: "$text"');
      } else {
        // ignore: avoid_print
        print('[Sherpa] Transcription vide');
      }

      return text.isNotEmpty ? text : null;
    } catch (e) {
      // ignore: avoid_print
      print('[Sherpa] Erreur transcription: $e');
      return null;
    }
  }

  /// Convertit un fichier WAV en Float32List
  Float32List? _wavToFloat32(Uint8List wavData) {
    try {
      // Vérifier l'en-tête WAV
      if (wavData.length < 44) return null;

      // Vérifier la signature RIFF
      if (wavData[0] != 0x52 || // R
          wavData[1] != 0x49 || // I
          wavData[2] != 0x46 || // F
          wavData[3] != 0x46) {
        // F
        // ignore: avoid_print
        print('[Sherpa] Format invalide: pas un fichier WAV');
        return null;
      }

      // Lire les paramètres WAV
      final byteData = ByteData.sublistView(wavData);
      final numChannels = byteData.getUint16(22, Endian.little);
      final wavSampleRate = byteData.getUint32(24, Endian.little);
      final bitsPerSample = byteData.getUint16(34, Endian.little);

      // ignore: avoid_print
      print('[Sherpa] WAV: ${wavSampleRate}Hz, $numChannels ch, $bitsPerSample bits');

      // Trouver le début des données (chercher "data" chunk)
      int dataStart = 44;
      for (int i = 36; i < wavData.length - 8; i++) {
        if (wavData[i] == 0x64 && // d
            wavData[i + 1] == 0x61 && // a
            wavData[i + 2] == 0x74 && // t
            wavData[i + 3] == 0x61) {
          // a
          dataStart = i + 8;
          break;
        }
      }

      // Convertir les samples 16-bit en float32
      final numSamples = (wavData.length - dataStart) ~/ (bitsPerSample ~/ 8);
      final samples = Float32List(numSamples);

      if (bitsPerSample == 16) {
        for (int i = 0; i < numSamples; i++) {
          final offset = dataStart + i * 2;
          if (offset + 1 < wavData.length) {
            final sample = byteData.getInt16(offset, Endian.little);
            samples[i] = sample / 32768.0;
          }
        }
      }

      return samples;
    } catch (e) {
      // ignore: avoid_print
      print('[Sherpa] Erreur conversion WAV: $e');
      return null;
    }
  }

  /// Évalue la qualité de la transcription (heuristique simple)
  double evaluateQuality(String transcription) {
    if (transcription.isEmpty) return 0.0;

    final words = transcription.split(' ').where((w) => w.length > 1).length;
    final specialChars =
        transcription.replaceAll(RegExp(r'[a-zA-ZÀ-ÿ\s]'), '').length;
    final totalChars = transcription.length;

    if (words < 2) return 0.3;
    if (specialChars > totalChars * 0.2) return 0.4;
    if (words < 5) return 0.6;

    return 0.8;
  }

  /// Libère les ressources
  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _isModelLoaded = false;
    // ignore: avoid_print
    print('[Sherpa] Ressources libérées');
  }
}
