import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

/// =============================================================================
/// local_app_launcher_service.dart
/// =============================================================================
/// Service pour lancer des applications Android par leur nom.
/// Maintient un mapping des noms courants vers les package names.
/// =============================================================================

/// Résultat d'une opération de lancement d'app
class AppLaunchResult {
  final bool success;
  final String? error;
  final String? launchedPackage;

  const AppLaunchResult({
    required this.success,
    this.error,
    this.launchedPackage,
  });

  factory AppLaunchResult.success(String packageName) =>
      AppLaunchResult(success: true, launchedPackage: packageName);

  factory AppLaunchResult.failure(String error) =>
      AppLaunchResult(success: false, error: error);
}

class LocalAppLauncherService {
  bool _initialized = false;

  /// Mapping des noms d'apps courants vers leurs package names
  /// Inclut les noms en français et anglais
  static const Map<String, String> _knownApps = {
    // Réseaux sociaux
    'instagram': 'com.instagram.android',
    'insta': 'com.instagram.android',
    'facebook': 'com.facebook.katana',
    'fb': 'com.facebook.katana',
    'twitter': 'com.twitter.android',
    'x': 'com.twitter.android',
    'tiktok': 'com.zhiliaoapp.musically',
    'snapchat': 'com.snapchat.android',
    'snap': 'com.snapchat.android',
    'linkedin': 'com.linkedin.android',
    'reddit': 'com.reddit.frontpage',
    'pinterest': 'com.pinterest',

    // Messagerie
    'whatsapp': 'com.whatsapp',
    'telegram': 'org.telegram.messenger',
    'signal': 'org.thoughtcrime.securesms',
    'messenger': 'com.facebook.orca',
    'discord': 'com.discord',
    'slack': 'com.Slack',
    'teams': 'com.microsoft.teams',

    // Google
    'gmail': 'com.google.android.gm',
    'mail': 'com.google.android.gm',
    'youtube': 'com.google.android.youtube',
    'yt': 'com.google.android.youtube',
    'maps': 'com.google.android.apps.maps',
    'google maps': 'com.google.android.apps.maps',
    'drive': 'com.google.android.apps.docs',
    'google drive': 'com.google.android.apps.docs',
    'photos': 'com.google.android.apps.photos',
    'google photos': 'com.google.android.apps.photos',
    'calendar': 'com.google.android.calendar',
    'agenda': 'com.google.android.calendar',
    'chrome': 'com.android.chrome',
    'google': 'com.google.android.googlequicksearchbox',
    'assistant': 'com.google.android.apps.googleassistant',
    'google assistant': 'com.google.android.apps.googleassistant',
    'keep': 'com.google.android.keep',
    'google keep': 'com.google.android.keep',
    'notes': 'com.google.android.keep',

    // Musique et streaming
    'spotify': 'com.spotify.music',
    'youtube music': 'com.google.android.apps.youtube.music',
    'yt music': 'com.google.android.apps.youtube.music',
    'deezer': 'deezer.android.app',
    'soundcloud': 'com.soundcloud.android',
    'netflix': 'com.netflix.mediaclient',
    'prime video': 'com.amazon.avod.thirdpartyclient',
    'amazon prime': 'com.amazon.avod.thirdpartyclient',
    'disney': 'com.disney.disneyplus',
    'disney+': 'com.disney.disneyplus',
    'twitch': 'tv.twitch.android.app',

    // Utilitaires
    'camera': 'com.android.camera',
    'appareil photo': 'com.android.camera',
    'calculatrice': 'com.google.android.calculator',
    'calculator': 'com.google.android.calculator',
    'calculette': 'com.google.android.calculator',
    'horloge': 'com.google.android.deskclock',
    'clock': 'com.google.android.deskclock',
    'alarme': 'com.google.android.deskclock',
    'alarm': 'com.google.android.deskclock',
    'fichiers': 'com.google.android.documentsui',
    'files': 'com.google.android.documentsui',
    'paramètres': 'com.android.settings',
    'settings': 'com.android.settings',
    'réglages': 'com.android.settings',

    // Shopping
    'amazon': 'com.amazon.mShop.android.shopping',
    'ebay': 'com.ebay.mobile',
    'aliexpress': 'com.alibaba.aliexpresshd',

    // Transport
    'uber': 'com.ubercab',
    'lyft': 'me.lyft.android',
    'bolt': 'ee.mtakso.client',
    'waze': 'com.waze',

    // Finance
    // Finance (supprimé — Fintecture utilise le web, pas d'app native)

    // Jeux
    'play games': 'com.google.android.play.games',
    'jeux': 'com.google.android.play.games',
  };

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;

    _initialized = true;
    // ignore: avoid_print
    print('[AppLauncher] Service initialisé avec ${_knownApps.length} apps connues');
  }

  /// Lance une application par son nom
  Future<AppLaunchResult> launchApp({
    required String appName,
    String? packageName,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // Si un package name est fourni, l'utiliser directement
      if (packageName != null && packageName.isNotEmpty) {
        return await _launchPackage(packageName);
      }

      // Sinon, chercher dans les apps connues
      final normalizedName = appName.toLowerCase().trim();
      final knownPackage = _knownApps[normalizedName];

      if (knownPackage != null) {
        return await _launchPackage(knownPackage);
      }

      // Recherche partielle dans les noms
      for (final entry in _knownApps.entries) {
        if (entry.key.contains(normalizedName) ||
            normalizedName.contains(entry.key)) {
          return await _launchPackage(entry.value);
        }
      }

      // Dernier recours: tenter de lancer avec le nom comme package
      // ignore: avoid_print
      print('[AppLauncher] App "$appName" non trouvée dans le mapping');
      return await _launchPackage('com.$normalizedName.android');
    } catch (e) {
      // ignore: avoid_print
      print('[AppLauncher] Erreur: $e');
      return AppLaunchResult.failure(e.toString());
    }
  }

  /// Lance une application par son package name
  Future<AppLaunchResult> _launchPackage(String packageName) async {
    // ignore: avoid_print
    print('[AppLauncher] Lancement: $packageName');

    try {
      // Utiliser launchApp qui est la méthode native de android_intent_plus
      // pour lancer une app par son package name
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: packageName,
        componentName: _getComponentName(packageName),
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      await intent.launch();

      // ignore: avoid_print
      print('[AppLauncher] App lancée: $packageName');
      return AppLaunchResult.success(packageName);
    } catch (e) {
      // ignore: avoid_print
      print('[AppLauncher] Erreur lancement $packageName: $e');
      return AppLaunchResult.failure('Application non installée ou inaccessible');
    }
  }

  /// Retourne le componentName (activité principale) pour les apps connues
  String? _getComponentName(String packageName) {
    // Mapping des activités principales pour les apps qui en ont besoin
    const componentNames = {
      'com.instagram.android': 'com.instagram.android/com.instagram.mainactivity.LauncherActivity',
      'com.facebook.katana': 'com.facebook.katana/com.facebook.katana.LoginActivity',
      'com.twitter.android': 'com.twitter.android/com.twitter.app.main.MainActivity',
      'com.snapchat.android': 'com.snapchat.android/com.snap.mushroom.MainActivity',
      'com.zhiliaoapp.musically': 'com.zhiliaoapp.musically/com.ss.android.ugc.aweme.splash.SplashActivity',
    };
    return componentNames[packageName];
  }

  /// Recherche une app dans le store
  Future<AppLaunchResult> searchInStore(String appName) async {
    // ignore: avoid_print
    print('[AppLauncher] Recherche dans le store: $appName');

    final encodedQuery = Uri.encodeComponent(appName);

    final intent = AndroidIntent(
      action: 'android.intent.action.VIEW',
      data: 'market://search?q=$encodedQuery',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();
    return AppLaunchResult.success('com.android.vending');
  }

  /// Vérifie si une app est installée
  Future<bool> isAppInstalled(String packageName) async {
    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      package: packageName,
    );

    return await intent.canResolveActivity() ?? false;
  }

  /// Retourne la liste des apps connues
  Map<String, String> get knownApps => Map.unmodifiable(_knownApps);

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
