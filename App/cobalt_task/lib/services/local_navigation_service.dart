import 'dart:async';
import 'dart:convert';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:volume_controller/volume_controller.dart';
import 'audio_feedback_service.dart';
import 'settings_service.dart';

/// =============================================================================
/// local_navigation_service.dart
/// =============================================================================
/// Service pour lancer la navigation GPS vers une destination.
/// Utilise Google Maps ou l'app de navigation par défaut.
///
/// Pipeline de briefing vocal (si clés API configurées) :
///   GPS position → Directions API → Gemini Flash synthèse → TTS → Maps
///
/// Mode dégradé (clés manquantes, timeout >3s, erreur réseau) :
///   Maps s'ouvre directement (comportement classique).
///
/// Modes de transport supportés:
/// - driving (voiture) - défaut
/// - walking (à pied)
/// - bicycling (vélo)
/// - transit (transports en commun)
/// =============================================================================

/// Résultat d'une opération de navigation
class NavigationResult {
  final bool success;
  final String? error;
  final bool briefingSpoken;

  const NavigationResult({
    required this.success,
    this.error,
    this.briefingSpoken = false,
  });

  factory NavigationResult.success({bool briefingSpoken = false}) =>
      NavigationResult(success: true, briefingSpoken: briefingSpoken);

  factory NavigationResult.failure(String error) =>
      NavigationResult(success: false, error: error);
}

class LocalNavigationService {
  bool _initialized = false;

  String? get _googleMapsApiKey {
    final v = SettingsService().googleMapsApiKey;
    return v.isEmpty ? null : v;
  }

  String? get _geminiApiKey {
    final v = SettingsService().geminiApiKey;
    return v.isEmpty ? null : v;
  }

  /// Mapping des modes de transport vers les codes Google Maps
  static const Map<String, String> _travelModes = {
    'driving': 'd',   // Voiture
    'voiture': 'd',
    'car': 'd',
    'walking': 'w',   // À pied
    'pied': 'w',
    'walk': 'w',
    'marche': 'w',
    'bicycling': 'b', // Vélo
    'velo': 'b',
    'bike': 'b',
    'transit': 'r',   // Transports en commun
    'transport': 'r',
    'bus': 'r',
    'metro': 'r',
  };

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;

    _initialized = true;
    // ignore: avoid_print
    print('[Navigation] Service initialisé (briefing: ${_canBrief ? 'actif' : 'inactif'})');
  }

  /// Vérifie si le briefing vocal est possible (les 2 clés API configurées)
  bool get _canBrief => _googleMapsApiKey != null && _geminiApiKey != null;

  /// Lance la navigation vers une destination
  Future<NavigationResult> navigate({
    required String destination,
    String? mode,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    if (destination.isEmpty) {
      return NavigationResult.failure('Destination vide');
    }

    try {
      // Déterminer le mode de transport
      final travelMode = _getTravelMode(mode);

      // S'assurer que le volume média est audible pour le guidage vocal Maps
      await _ensureMediaVolume();

      // Tenter le briefing vocal AVANT le lancement Maps
      final briefingSpoken = await _tryVocalBriefing(destination, travelMode);

      // Lancer l'app de navigation choisie dans les paramètres
      final navApp = SettingsService().navigationApp;
      final NavigationResult result;
      if (navApp == 'waze') {
        result = await _launchWaze(destination);
      } else {
        result = await _launchGoogleMaps(destination, travelMode);
      }

      if (result.success) {
        return NavigationResult.success(briefingSpoken: briefingSpoken);
      }

      // Fallback: intent générique de navigation
      final fallback = await _launchGenericNavigation(destination);
      if (fallback.success) {
        return NavigationResult.success(briefingSpoken: briefingSpoken);
      }

      return fallback;
    } catch (e) {
      // ignore: avoid_print
      print('[Navigation] Erreur: $e');
      return NavigationResult.failure(e.toString());
    }
  }

  // ===========================================================================
  // BRIEFING VOCAL
  // ===========================================================================

  /// Orchestrateur du briefing vocal : GPS → Directions → Gemini → TTS
  ///
  /// Retourne `true` si le briefing a été prononcé, `false` sinon.
  /// N'échoue JAMAIS (try-catch global) — en cas d'erreur, Maps se lance sans briefing.
  Future<bool> _tryVocalBriefing(String destination, String travelMode) async {
    if (!_canBrief) return false;

    try {
      // 1. Obtenir la position GPS (PAS sous le timeout 3s)
      final position = await _getPosition();
      if (position == null) {
        // ignore: avoid_print
        print('[Navigation] GPS indisponible → skip briefing');
        return false;
      }

      // 2. Directions API + Gemini Flash (SOUS le timeout 3s)
      final briefingText = await _fetchAndSynthesize(
        position,
        destination,
        travelMode,
      ).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          // ignore: avoid_print
          print('[Navigation] Timeout 3s → skip briefing');
          return null;
        },
      );

      if (briefingText == null || briefingText.isEmpty) {
        return false;
      }

      // 3. TTS : lire le briefing (PAS sous le timeout 3s — on laisse le TTS finir)
      await _speakAndWait(briefingText);

      // ignore: avoid_print
      print('[Navigation] Briefing vocal terminé');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[Navigation] Erreur briefing (skip): $e');
      return false;
    }
  }

  /// Obtient la position GPS de l'utilisateur
  ///
  /// Tente d'abord le cache (getLastKnownPosition, instantané),
  /// puis getCurrentPosition avec un timeout de 5s.
  /// Retourne null si GPS indisponible ou permission refusée.
  Future<Position?> _getPosition() async {
    try {
      // Vérifier la permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return null;
        }
      }

      // Essayer le cache d'abord (instantané)
      final cached = await Geolocator.getLastKnownPosition();
      if (cached != null) {
        // ignore: avoid_print
        print('[Navigation] Position GPS (cache): ${cached.latitude},${cached.longitude}');
        return cached;
      }

      // Sinon, obtenir la position actuelle (max 5s)
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );
      // ignore: avoid_print
      print('[Navigation] Position GPS (live): ${current.latitude},${current.longitude}');
      return current;
    } catch (e) {
      // ignore: avoid_print
      print('[Navigation] Erreur GPS: $e');
      return null;
    }
  }

  /// Appelle Directions API + Gemini Flash pour synthétiser le briefing
  ///
  /// Cette méthode est sous le timeout de 3s via .timeout() dans _tryVocalBriefing.
  Future<String?> _fetchAndSynthesize(
    Position position,
    String destination,
    String travelMode,
  ) async {
    // ---- Directions API ----
    final directionsMode = _travelModeToString(travelMode);
    final directionsUri = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${position.latitude},${position.longitude}'
      '&destination=${Uri.encodeComponent(destination)}'
      '&key=$_googleMapsApiKey'
      '&language=fr'
      '&mode=$directionsMode',
    );

    // ignore: avoid_print
    print('[Navigation] Directions API → $destination');
    final directionsResponse = await http.get(directionsUri);

    if (directionsResponse.statusCode != 200) {
      // ignore: avoid_print
      print('[Navigation] Directions API erreur: ${directionsResponse.statusCode}');
      return null;
    }

    final directionsJson = jsonDecode(directionsResponse.body) as Map<String, dynamic>;
    final routes = directionsJson['routes'] as List?;
    if (routes == null || routes.isEmpty) {
      // ignore: avoid_print
      print('[Navigation] Aucune route trouvée');
      return null;
    }

    final legs = (routes[0] as Map<String, dynamic>)['legs'] as List?;
    if (legs == null || legs.isEmpty) return null;

    final leg = legs[0] as Map<String, dynamic>;
    final steps = leg['steps'] as List?;
    if (steps == null || steps.isEmpty) return null;

    // Extraire les instructions textuelles (strip HTML)
    final duration = (leg['duration'] as Map<String, dynamic>?)?['text'] ?? '';
    final distance = (leg['distance'] as Map<String, dynamic>?)?['text'] ?? '';

    final stepsData = steps.map((step) {
      final s = step as Map<String, dynamic>;
      final instruction = (s['html_instructions'] as String? ?? '')
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final stepDist = (s['distance'] as Map<String, dynamic>?)?['text'] ?? '';
      return {'instruction': instruction, 'distance': stepDist};
    }).toList();

    // Construire le JSON compact pour Gemini
    final itineraireJson = jsonEncode({
      'destination': destination,
      'duration': duration,
      'distance': distance,
      'mode': directionsMode,
      'steps': stepsData,
    });

    // ---- Gemini Flash ----
    // ignore: avoid_print
    print('[Navigation] Gemini Flash → synthèse briefing');
    final geminiUri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_geminiApiKey',
    );

    final geminiBody = jsonEncode({
      'systemInstruction': {
        'parts': [
          {
            'text':
                'Tu es un copilote. Analyse cet itinéraire JSON. '
                'Ne donne pas la liste des rues. '
                'Synthétise le trajet en 3 phrases clés basées sur des repères visuels ou des directions cardinales simples. '
                'Ton : Direct et rassurant. Langue : Français.',
          }
        ],
      },
      'contents': [
        {
          'parts': [
            {'text': itineraireJson},
          ],
        }
      ],
      'generationConfig': {
        'temperature': 0.7,
        'maxOutputTokens': 200,
      },
    });

    final geminiResponse = await http.post(
      geminiUri,
      headers: {'Content-Type': 'application/json'},
      body: geminiBody,
    );

    if (geminiResponse.statusCode != 200) {
      // ignore: avoid_print
      print('[Navigation] Gemini erreur: ${geminiResponse.statusCode}');
      return null;
    }

    final geminiJson = jsonDecode(geminiResponse.body) as Map<String, dynamic>;
    final candidates = geminiJson['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;

    final content = (candidates[0] as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
    if (content == null) return null;

    final parts = content['parts'] as List?;
    if (parts == null || parts.isEmpty) return null;

    final briefing = (parts[0] as Map<String, dynamic>)['text'] as String?;

    // ignore: avoid_print
    print('[Navigation] Briefing Gemini: $briefing');
    return briefing;
  }

  /// Délègue à AudioFeedbackService.speakAndWait()
  Future<void> _speakAndWait(String text) async {
    final tts = AudioFeedbackService();
    await tts.speakAndWait(text);
  }

  // ===========================================================================
  // VOLUME
  // ===========================================================================

  /// S'assure que le volume média est audible pour le guidage vocal Maps.
  /// Si le volume est en dessous de 30%, le monte à 50%.
  Future<void> _ensureMediaVolume() async {
    try {
      final controller = VolumeController();
      final current = await controller.getVolume();
      if (current < 0.3) {
        controller.setVolume(0.5, showSystemUI: true);
        // ignore: avoid_print
        print('[Navigation] Volume média monté à 50% (était ${(current * 100).toInt()}%)');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Navigation] Impossible de vérifier le volume: $e');
    }
  }

  // ===========================================================================
  // GOOGLE MAPS LAUNCH
  // ===========================================================================

  /// Convertit le mode de transport en code Google Maps
  String _getTravelMode(String? mode) {
    if (mode == null) {
      // Lire le mode par défaut depuis les paramètres
      final defaultMode = SettingsService().defaultTransport;
      return _travelModes[defaultMode] ?? 'b';
    }

    final normalizedMode = mode.toLowerCase().trim();
    return _travelModes[normalizedMode] ?? 'b';
  }

  /// Lance Google Maps avec la destination
  Future<NavigationResult> _launchGoogleMaps(String destination, String travelMode) async {
    // ignore: avoid_print
    print('[Navigation] Google Maps -> $destination (mode: $travelMode)');

    // Encoder la destination
    final encodedDestination = Uri.encodeComponent(destination);

    // Format Google Maps avec navigation directe
    // google.navigation:q=DESTINATION&mode=MODE
    final navUri = Uri.parse('google.navigation:q=$encodedDestination&mode=$travelMode');

    if (await canLaunchUrl(navUri)) {
      await launchUrl(navUri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('[Navigation] Navigation Google Maps lancée');
      return NavigationResult.success();
    }

    // Fallback: ouvrir Google Maps en mode directions
    // https://www.google.com/maps/dir/?api=1&destination=DESTINATION&travelmode=MODE
    final travelModeStr = _travelModeToString(travelMode);
    final webUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$encodedDestination&travelmode=$travelModeStr'
    );

    if (await canLaunchUrl(webUri)) {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('[Navigation] Google Maps (web) lancé');
      return NavigationResult.success();
    }

    return NavigationResult.failure('Google Maps non disponible');
  }

  /// Lance Waze avec la destination
  Future<NavigationResult> _launchWaze(String destination) async {
    final encodedDestination = Uri.encodeComponent(destination);
    // ignore: avoid_print
    print('[Navigation] Waze -> $destination');

    // Deep link natif Waze (ouvre l'app directement)
    final wazeUri = Uri.parse('waze://?q=$encodedDestination&navigate=yes');
    if (await canLaunchUrl(wazeUri)) {
      await launchUrl(wazeUri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('[Navigation] Waze lancé (deep link)');
      return NavigationResult.success();
    }

    // Fallback intent Android (cherche le package Waze)
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'https://waze.com/ul?q=$encodedDestination&navigate=yes',
        package: 'com.waze',
      );
      await intent.launch();
      // ignore: avoid_print
      print('[Navigation] Waze lancé (intent)');
      return NavigationResult.success();
    } catch (e) {
      // ignore: avoid_print
      print('[Navigation] Waze non disponible ($e), fallback Google Maps');
      return await _launchGoogleMaps(destination, _getTravelMode(null));
    }
  }

  /// Convertit le code court en nom complet pour l'URL web
  String _travelModeToString(String code) {
    return switch (code) {
      'd' => 'driving',
      'w' => 'walking',
      'b' => 'bicycling',
      'r' => 'transit',
      _ => 'driving',
    };
  }

  /// Lance une navigation générique via intent Android
  Future<NavigationResult> _launchGenericNavigation(String destination) async {
    // ignore: avoid_print
    print('[Navigation] Intent générique -> $destination');

    final encodedDestination = Uri.encodeComponent(destination);

    final intent = AndroidIntent(
      action: 'android.intent.action.VIEW',
      data: 'geo:0,0?q=$encodedDestination',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();

    // ignore: avoid_print
    print('[Navigation] Intent de navigation lancé');
    return NavigationResult.success();
  }

  /// Ouvre simplement Google Maps (sans destination)
  Future<NavigationResult> openMaps() async {
    final uri = Uri.parse('geo:0,0');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return NavigationResult.success();
    }

    // Fallback via intent
    final intent = AndroidIntent(
      action: 'android.intent.action.VIEW',
      package: 'com.google.android.apps.maps',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();
    return NavigationResult.success();
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
