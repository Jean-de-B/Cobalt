import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// =============================================================================
/// transcription_service.dart
/// =============================================================================
/// Service de transcription audio via l'API Groq (Whisper).
///
/// Groq offre une API compatible OpenAI pour la transcription audio,
/// utilisant le modèle Whisper Large V3 avec des performances optimisées.
///
/// Endpoint: https://api.groq.com/openai/v1/audio/transcriptions
/// Modèle: whisper-large-v3
/// Format accepté: WAV, MP3, FLAC, etc.
///
/// IMPORTANT: La clé API est chargée depuis le fichier .env
/// Ne jamais coder la clé API en dur dans le code source.
/// =============================================================================

/// Résultat d'une transcription
class TranscriptionResult {
  /// Texte transcrit
  final String text;

  /// Durée de l'audio en secondes (si disponible)
  final double? duration;

  /// Langue détectée (si disponible)
  final String? language;

  const TranscriptionResult({
    required this.text,
    this.duration,
    this.language,
  });

  factory TranscriptionResult.fromJson(Map<String, dynamic> json) {
    return TranscriptionResult(
      text: json['text'] as String? ?? '',
      duration: json['duration'] as double?,
      language: json['language'] as String?,
    );
  }
}

/// Exception personnalisée pour les erreurs de transcription
class TranscriptionException implements Exception {
  final String message;
  final int? statusCode;
  final String? details;

  const TranscriptionException(
    this.message, {
    this.statusCode,
    this.details,
  });

  @override
  String toString() {
    if (statusCode != null) {
      return 'TranscriptionException [$statusCode]: $message';
    }
    return 'TranscriptionException: $message';
  }
}

/// Service de transcription Groq Whisper
class TranscriptionService {
  /// Instance singleton
  static TranscriptionService? _instance;

  /// URL de base de l'API Groq
  static const String _baseUrl = 'https://api.groq.com/openai/v1';

  /// Endpoint de transcription
  static const String _transcriptionEndpoint = '/audio/transcriptions';

  /// Modèle Whisper à utiliser
  static const String _model = 'whisper-large-v3';

  /// Clé API Groq (chargée depuis .env)
  String? _apiKey;

  /// Client HTTP réutilisable
  final http.Client _httpClient;

  /// Constructeur privé
  TranscriptionService._internal() : _httpClient = http.Client();

  /// Factory Singleton
  factory TranscriptionService() {
    _instance ??= TranscriptionService._internal();
    return _instance!;
  }

  /// Initialise le service avec la clé API depuis .env
  ///
  /// Doit être appelé après le chargement de dotenv dans main().
  /// Lève une exception si la clé n'est pas configurée.
  void initialize() {
    _apiKey = dotenv.env['GROQ_API_KEY'];

    if (_apiKey == null || _apiKey!.isEmpty) {
      throw const TranscriptionException(
        'Clé API Groq non configurée. '
        'Ajoutez GROQ_API_KEY dans le fichier .env',
      );
    }
  }

  /// Vérifie si le service est initialisé
  bool get isInitialized => _apiKey != null && _apiKey!.isNotEmpty;

  /// Transcrit un fichier audio WAV
  ///
  /// [wavFile] Fichier WAV à transcrire
  /// [language] Code de langue optionnel (ex: "fr", "en")
  ///            Si non spécifié, la langue est détectée automatiquement
  ///
  /// Retourne un [TranscriptionResult] contenant le texte transcrit.
  ///
  /// Exemple:
  /// ```dart
  /// final service = TranscriptionService();
  /// final result = await service.transcribeFile(
  ///   File('note.wav'),
  ///   language: 'fr',
  /// );
  /// print(result.text);
  /// ```
  Future<TranscriptionResult> transcribeFile(
    File wavFile, {
    String? language,
  }) async {
    if (!isInitialized) {
      throw const TranscriptionException('Service non initialisé');
    }

    // Vérifier que le fichier existe
    if (!await wavFile.exists()) {
      throw TranscriptionException(
        'Fichier audio introuvable: ${wavFile.path}',
      );
    }

    // Lire le contenu du fichier
    final bytes = await wavFile.readAsBytes();
    return transcribeBytes(bytes, filename: wavFile.path, language: language);
  }

  /// Transcrit des données audio en bytes
  ///
  /// [audioBytes] Données audio WAV en bytes
  /// [filename] Nom du fichier (pour le Content-Type)
  /// [language] Code de langue optionnel
  ///
  /// Utile quand l'audio est en mémoire (ex: juste décodé depuis ADPCM).
  Future<TranscriptionResult> transcribeBytes(
    Uint8List audioBytes, {
    String filename = 'audio.wav',
    String? language,
  }) async {
    if (!isInitialized) {
      throw const TranscriptionException('Service non initialisé');
    }

    try {
      // Construire la requête multipart
      final uri = Uri.parse('$_baseUrl$_transcriptionEndpoint');
      final request = http.MultipartRequest('POST', uri);

      // Headers d'authentification
      request.headers['Authorization'] = 'Bearer $_apiKey';

      // Paramètres du formulaire
      request.fields['model'] = _model;
      request.fields['response_format'] = 'json';

      // Langue optionnelle (améliore la précision si connue)
      if (language != null) {
        request.fields['language'] = language;
      }

      // Ajouter le fichier audio
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          audioBytes,
          filename: filename.endsWith('.wav') ? filename : '$filename.wav',
        ),
      );

      // Envoyer la requête
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      // Traiter la réponse
      return _handleResponse(response);
    } on SocketException catch (e) {
      throw TranscriptionException(
        'Erreur réseau: impossible de contacter l\'API Groq',
        details: e.message,
      );
    } on http.ClientException catch (e) {
      throw TranscriptionException(
        'Erreur HTTP',
        details: e.message,
      );
    }
  }

  /// Traite la réponse de l'API
  TranscriptionResult _handleResponse(http.Response response) {
    final statusCode = response.statusCode;

    // Succès (200-299)
    if (statusCode >= 200 && statusCode < 300) {
      try {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return TranscriptionResult.fromJson(json);
      } catch (e) {
        throw TranscriptionException(
          'Réponse invalide de l\'API',
          statusCode: statusCode,
          details: response.body,
        );
      }
    }

    // Erreurs client (400-499)
    if (statusCode >= 400 && statusCode < 500) {
      String message;
      try {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final error = json['error'] as Map<String, dynamic>?;
        message = error?['message'] as String? ?? 'Erreur inconnue';
      } catch (_) {
        message = response.body;
      }

      switch (statusCode) {
        case 401:
          throw TranscriptionException(
            'Clé API invalide ou expirée',
            statusCode: statusCode,
            details: message,
          );
        case 413:
          throw TranscriptionException(
            'Fichier audio trop volumineux',
            statusCode: statusCode,
            details: message,
          );
        case 429:
          throw TranscriptionException(
            'Limite de requêtes atteinte. Réessayez plus tard.',
            statusCode: statusCode,
            details: message,
          );
        default:
          throw TranscriptionException(
            message,
            statusCode: statusCode,
          );
      }
    }

    // Erreurs serveur (500-599)
    if (statusCode >= 500) {
      throw TranscriptionException(
        'Erreur serveur Groq. Réessayez plus tard.',
        statusCode: statusCode,
        details: response.body,
      );
    }

    // Autres cas
    throw TranscriptionException(
      'Erreur inattendue',
      statusCode: statusCode,
      details: response.body,
    );
  }

  /// Libère les ressources
  void dispose() {
    _httpClient.close();
  }
}
