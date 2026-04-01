import 'package:flutter/services.dart';
import '../models/ai_action.dart';
import 'local_spotify_service.dart';

/// =============================================================================
/// local_media_service.dart
/// =============================================================================
/// Service pour contrôler la lecture média sur Android.
/// Utilise un MethodChannel natif pour envoyer des Media Key Events.
///
/// Fonctionne avec tous les lecteurs média (Spotify, YouTube Music, etc.)
/// car utilise les événements système standard.
/// =============================================================================

/// Résultat d'une opération média
class MediaResult {
  final bool success;
  final String? error;

  const MediaResult({
    required this.success,
    this.error,
  });

  factory MediaResult.success() => const MediaResult(success: true);

  factory MediaResult.failure(String error) =>
      MediaResult(success: false, error: error);
}

class LocalMediaService {
  static const _channel = MethodChannel('com.cobalt_task/media_keys');
  bool _initialized = false;

  final LocalSpotifyService _spotifyService = LocalSpotifyService();
  LocalSpotifyService get spotifyService => _spotifyService;

  /// Initialise le service (MediaKeys uniquement)
  /// Spotify s'initialise à la demande via login() pour éviter les ANR
  Future<void> initialize() async {
    if (_initialized) return;

    _initialized = true;
    // ignore: avoid_print
    print('[Media] Service initialisé (MethodChannel)');
  }

  /// Exécute une commande de contrôle média
  Future<MediaResult> execute({
    required MediaControlType controlType,
    String? query,
    String? app,
    String? deviceType,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // ignore: avoid_print
      print('[Media] execute() controlType=$controlType, query=$query, app=$app');
      // ignore: avoid_print
      print('[Media] spotifyService.isConnected=${_spotifyService.isConnected} (hashCode=${_spotifyService.hashCode})');

      // Si Spotify est connecté, tenter via l'API Web (pas d'écran nécessaire)
      if (_spotifyService.isConnected) {
        // ignore: avoid_print
        print('[Media] >>> Routage vers Spotify Web API <<<');
        final spotifyResult = await _trySpotifyCommand(controlType, query, app);
        // ignore: avoid_print
        print('[Media] Spotify résultat: ${spotifyResult != null ? "OK" : "null (fallback MediaKey)"}');
        if (spotifyResult != null) {
          // Si un device_type est spécifié en plus, transférer après le lancement
          if (deviceType != null && deviceType.isNotEmpty && controlType != MediaControlType.transfer) {
            // ignore: avoid_print
            print('[Media] Transfert additionnel vers $deviceType');
            await Future.delayed(const Duration(milliseconds: 500));
            await _transferToDevice(deviceType);
          }
          return spotifyResult;
        }
      } else {
        // ignore: avoid_print
        print('[Media] Spotify NON connecté → fallback MediaKey');
      }

      switch (controlType) {
        case MediaControlType.play:
          return await _sendMediaCommand('play');

        case MediaControlType.pause:
          return await _sendMediaCommand('pause');

        case MediaControlType.playPause:
          return await _sendMediaCommand('playPause');

        case MediaControlType.next:
          return await _sendMediaCommand('next');

        case MediaControlType.previous:
          return await _sendMediaCommand('previous');

        case MediaControlType.stop:
          return await _sendMediaCommand('stop');

        case MediaControlType.playSearch:
          return await _playSearch(query ?? '', app);

        case MediaControlType.like:
          if (_spotifyService.isConnected) {
            final result = await _spotifyService.likeCurrentTrack();
            if (result.success) return MediaResult.success();
            return MediaResult.failure(result.error ?? 'Erreur like');
          }
          return MediaResult.failure('Spotify non connecté');

        case MediaControlType.transfer:
          if (_spotifyService.isConnected) {
            return await _transferToDevice(deviceType);
          }
          return MediaResult.failure('Spotify non connecté');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Media] Erreur: $e');
      return MediaResult.failure(e.toString());
    }
  }

  /// Envoie une commande média via le MethodChannel natif
  Future<MediaResult> _sendMediaCommand(String command) async {
    // ignore: avoid_print
    print('[Media] Commande: $command');

    try {
      final result = await _channel.invokeMethod<bool>(command);

      if (result == true) {
        // ignore: avoid_print
        print('[Media] MediaKey envoyé: $command');
        return MediaResult.success();
      } else {
        // ignore: avoid_print
        print('[Media] Échec envoi MediaKey: $command');
        return MediaResult.failure('Échec envoi commande média');
      }
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[Media] PlatformException: ${e.message}');
      return MediaResult.failure('Erreur plateforme: ${e.message}');
    } catch (e) {
      // ignore: avoid_print
      print('[Media] Erreur: $e');
      return MediaResult.failure(e.toString());
    }
  }

  /// Tente d'exécuter la commande via l'API Spotify Web
  /// Retourne null si Spotify n'est pas pertinent (fallback MediaKey)
  Future<MediaResult?> _trySpotifyCommand(
    MediaControlType controlType,
    String? query,
    String? app,
  ) async {
    // Pour playSearch avec app=spotify, toujours utiliser l'API
    if (controlType == MediaControlType.playSearch &&
        app?.toLowerCase() == 'spotify') {
      final result = await _spotifyService.searchAndPlay(query ?? '');
      if (result.success) return MediaResult.success();
      // ignore: avoid_print
      print('[Media] Spotify API échoué, fallback MediaKey: ${result.error}');
      return null;
    }

    // Pour les commandes basiques, tenter via Spotify
    SpotifyResult? result;
    switch (controlType) {
      case MediaControlType.play:
        result = await _spotifyService.play();
      case MediaControlType.pause:
        result = await _spotifyService.pause();
      case MediaControlType.playPause:
        // Vérifier l'état actuel pour toggle correctement via l'API
        final state = await _spotifyService.getPlayerState();
        final isPlaying = state?['is_playing'] as bool? ?? false;
        result = isPlaying
            ? await _spotifyService.pause()
            : await _spotifyService.play();
      case MediaControlType.next:
        result = await _spotifyService.next();
      case MediaControlType.previous:
        result = await _spotifyService.previous();
      case MediaControlType.playSearch:
        result = await _spotifyService.searchAndPlay(query ?? '');
      case MediaControlType.like:
        result = await _spotifyService.likeCurrentTrack();
      case MediaControlType.transfer:
        return null; // Géré directement dans execute()
      default:
        return null;
    }

    if (result.success) return MediaResult.success();
    // Fallback: retourner null pour que le switch MediaKey soit exécuté
    return null;
  }

  /// Recherche et lance la lecture via ACTION_MEDIA_PLAY_FROM_SEARCH
  Future<MediaResult> _playSearch(String query, String? app) async {
    // ignore: avoid_print
    print('[Media] PlaySearch: "$query" sur ${app ?? "app par défaut"}');

    // Essayer d'abord via Spotify Web API si l'app cible est Spotify
    if (app?.toLowerCase() == 'spotify' && _spotifyService.isConnected) {
      final spotifyResult = await _spotifyService.searchAndPlay(query);
      if (spotifyResult.success) {
        return MediaResult.success();
      }
      // ignore: avoid_print
      print('[Media] Spotify Web API échoué: ${spotifyResult.error}, fallback MediaKey');
    }

    // Méthode standard (intents Android)
    try {
      final result = await _channel.invokeMethod<bool>('playSearch', {
        'query': query,
        'app': app,
      });

      if (result == true) {
        // ignore: avoid_print
        print('[Media] PlaySearch lancé avec succès');
        return MediaResult.success();
      } else {
        // ignore: avoid_print
        print('[Media] Échec PlaySearch');
        return MediaResult.failure('Impossible de lancer la recherche média');
      }
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[Media] PlatformException: ${e.message}');
      return MediaResult.failure('Erreur plateforme: ${e.message}');
    }
  }

  /// Met en pause la lecture (utilisé par AudioService pour pause pendant enregistrement)
  /// Route via Spotify Web API si connecté, sinon MediaKey
  Future<MediaResult> pause() async {
    if (_spotifyService.isConnected) {
      final result = await _spotifyService.pause();
      if (result.success) return MediaResult.success();
    }
    return await _sendMediaCommand('pause');
  }

  /// Reprend la lecture (utilisé par AudioService après enregistrement)
  /// Route via Spotify Web API si connecté, sinon MediaKey
  Future<MediaResult> play() async {
    if (_spotifyService.isConnected) {
      final result = await _spotifyService.play();
      if (result.success) return MediaResult.success();
    }
    return await _sendMediaCommand('play');
  }

  /// Transfère la lecture vers un appareil par type (ordinateur, telephone, enceinte, tv)
  Future<MediaResult> _transferToDevice(String? deviceType) async {
    if (deviceType == null || deviceType.isEmpty) {
      return MediaResult.failure('Type d\'appareil non précisé');
    }

    final devices = await _spotifyService.getDevices();
    if (devices.isEmpty) return MediaResult.failure('Aucun appareil Spotify disponible');

    // Mapping mot-clé → type Spotify API
    final targetType = switch (deviceType.toLowerCase()) {
      'ordinateur' || 'computer' || 'pc' || 'ordi' || 'mac' => 'computer',
      'telephone' || 'téléphone' || 'smartphone' || 'phone' || 'tel' || 'portable' => 'smartphone',
      'enceinte' || 'speaker' || 'haut-parleur' || 'hp' => 'speaker',
      'tv' || 'télé' || 'television' || 'télévision' => 'tv',
      'cast' || 'chromecast' || 'google home' => 'castaudio',
      _ => deviceType.toLowerCase(),
    };

    // Chercher un device qui matche le type
    for (final device in devices) {
      final type = (device['type'] as String? ?? '').toLowerCase();
      if (type == targetType) {
        final id = device['id'] as String? ?? '';
        final name = device['name'] as String? ?? '';
        final result = await _spotifyService.transferPlayback(id);
        if (result.success) {
          // ignore: avoid_print
          print('[Media] Lecture transférée vers $name ($type)');
          return MediaResult.success();
        }
        return MediaResult.failure(result.error ?? 'Erreur transfert');
      }
    }

    // Pas trouvé
    final available = devices.map((d) => d['name']).join(', ');
    return MediaResult.failure('Aucun appareil de type "$deviceType" trouvé. Disponibles: $available');
  }

  /// Vérifie si de la musique est actuellement en cours de lecture
  Future<bool> isMusicActive() async {
    try {
      final result = await _channel.invokeMethod<bool>('isMusicActive');
      return result ?? false;
    } catch (e) {
      // ignore: avoid_print
      print('[Media] Erreur isMusicActive: $e');
      return false;
    }
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
