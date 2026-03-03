import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// =============================================================================
/// paypal_payment_service.dart
/// =============================================================================
/// Service PayPal P2P : authentification OAuth, ouverture de l'app PayPal
/// ou fallback navigateur pour les paiements entre particuliers.
/// =============================================================================

class PaymentResult {
  final bool success;
  final String? error;

  const PaymentResult({required this.success, this.error});

  factory PaymentResult.success() => const PaymentResult(success: true);

  factory PaymentResult.failure(String error) =>
      PaymentResult(success: false, error: error);
}

class PayPalPaymentService {
  static PayPalPaymentService? _instance;

  factory PayPalPaymentService() {
    _instance ??= PayPalPaymentService._();
    return _instance!;
  }

  PayPalPaymentService._();

  static const String _paypalPackage = 'com.paypal.android.p2pmobile';
  static const String _liveUrl = 'https://api-m.paypal.com';
  static const String _sandboxUrl = 'https://api-m.sandbox.paypal.com';
  static const _paymentChannel = MethodChannel('com.cobalt_task/payment');
  static const _storage = FlutterSecureStorage();

  // Clés de stockage sécurisé
  static const _keyClientId = 'paypal_client_id';
  static const _keySecret = 'paypal_secret';
  static const _keyMode = 'paypal_mode'; // 'live' ou 'sandbox'

  // URL de base active (déterminée à l'auth)
  String _baseUrl = _liveUrl;

  // Cache du token OAuth
  String? _accessToken;
  DateTime? _tokenExpiry;

  // État de configuration (stream pour l'UI)
  bool _isConfigured = false;
  final _configuredController = StreamController<bool>.broadcast();

  bool get isConfigured => _isConfigured;
  Stream<bool> get configuredStream => _configuredController.stream;

  /// Initialise le service : charge les credentials et le mode stockés.
  Future<void> initialize() async {
    try {
      final clientId = await _storage.read(key: _keyClientId);
      final secret = await _storage.read(key: _keySecret);
      final mode = await _storage.read(key: _keyMode);
      _baseUrl = mode == 'sandbox' ? _sandboxUrl : _liveUrl;
      _isConfigured = clientId != null && secret != null && clientId.isNotEmpty && secret.isNotEmpty;
      _configuredController.add(_isConfigured);
      // ignore: avoid_print
      print('[PayPal] Initialisé — configuré: $_isConfigured, mode: ${mode ?? "live"}');
    } catch (e) {
      // ignore: avoid_print
      print('[PayPal] Erreur initialisation: $e');
      _isConfigured = false;
      _configuredController.add(false);
    }
  }

  /// Enregistre les credentials PayPal et valide la connexion.
  /// Teste d'abord en mode Live, puis Sandbox si Live échoue.
  /// Retourne true si les credentials sont valides.
  Future<bool> saveCredentials(String clientId, String secret) async {
    try {
      // Tester Live d'abord
      _baseUrl = _liveUrl;
      var token = await _authenticate(clientId, secret);
      String mode = 'live';

      // Si Live échoue, tester Sandbox
      if (token == null) {
        // ignore: avoid_print
        print('[PayPal] Live échoué, tentative Sandbox...');
        _baseUrl = _sandboxUrl;
        token = await _authenticate(clientId, secret);
        mode = 'sandbox';
      }

      if (token == null) return false;

      await _storage.write(key: _keyClientId, value: clientId);
      await _storage.write(key: _keySecret, value: secret);
      await _storage.write(key: _keyMode, value: mode);
      _isConfigured = true;
      _configuredController.add(true);
      // ignore: avoid_print
      print('[PayPal] Credentials sauvegardés (mode: $mode)');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[PayPal] Erreur sauvegarde credentials: $e');
      return false;
    }
  }

  /// Supprime les credentials PayPal.
  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyClientId);
    await _storage.delete(key: _keySecret);
    await _storage.delete(key: _keyMode);
    _accessToken = null;
    _tokenExpiry = null;
    _baseUrl = _liveUrl;
    _isConfigured = false;
    _configuredController.add(false);
    // ignore: avoid_print
    print('[PayPal] Credentials supprimés');
  }

  /// Teste la connexion avec les credentials actuels.
  Future<bool> testConnection() async {
    try {
      final token = await _getAccessToken();
      return token != null;
    } catch (_) {
      return false;
    }
  }

  /// Envoie un paiement P2P via PayPal.
  /// 1. Vérifie la configuration
  /// 2. Valide le token OAuth
  /// 3. Ouvre l'app PayPal (ou fallback navigateur)
  Future<PaymentResult> sendPayment({
    required String phone,
    required double amount,
    String? note,
  }) async {
    if (!_isConfigured) {
      return PaymentResult.failure('PayPal non configuré');
    }

    // Valider le token OAuth (preuve que les credentials fonctionnent)
    final token = await _getAccessToken();
    if (token == null) {
      return PaymentResult.failure('Authentification PayPal échouée');
    }

    // ignore: avoid_print
    print('[PayPal] Token validé, ouverture de PayPal...');

    // Tenter d'ouvrir l'app PayPal
    if (await _tryLaunchPayPalApp()) {
      return PaymentResult.success();
    }

    // Fallback : ouvrir PayPal web
    if (await _openPayPalWeb()) {
      return PaymentResult.success();
    }

    return PaymentResult.failure('Impossible d\'ouvrir PayPal');
  }

  // ---------------------------------------------------------------------------
  // Méthodes privées
  // ---------------------------------------------------------------------------

  /// Authentification OAuth : Client ID + Secret → Bearer token.
  Future<String?> _authenticate(String clientId, String secret) async {
    try {
      final credentials = base64Encode(utf8.encode('$clientId:$secret'));
      final response = await http.post(
        Uri.parse('$_baseUrl/v1/oauth2/token'),
        headers: {
          'Authorization': 'Basic $credentials',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=client_credentials',
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _accessToken = data['access_token'] as String;
        final expiresIn = data['expires_in'] as int;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
        // ignore: avoid_print
        print('[PayPal] Authentification réussie (expire dans ${expiresIn}s)');
        return _accessToken;
      }
      // ignore: avoid_print
      print('[PayPal] Auth échouée: ${response.statusCode} ${response.body}');
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[PayPal] Erreur auth: $e');
      return null;
    }
  }

  /// Obtient un access token (cache ou rafraîchissement).
  Future<String?> _getAccessToken() async {
    // Utiliser le cache si le token est encore valide
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _accessToken;
    }

    // Rafraîchir le token
    final clientId = await _storage.read(key: _keyClientId);
    final secret = await _storage.read(key: _keySecret);
    if (clientId == null || secret == null) return null;

    return _authenticate(clientId, secret);
  }

  /// Tente d'ouvrir l'app PayPal via getLaunchIntentForPackage natif.
  Future<bool> _tryLaunchPayPalApp() async {
    try {
      final launched = await _paymentChannel.invokeMethod<bool>(
        'launchPackage',
        {'packageName': _paypalPackage},
      );
      if (launched == true) {
        // ignore: avoid_print
        print('[PayPal] App PayPal lancée');
        return true;
      }
      // ignore: avoid_print
      print('[PayPal] App PayPal non trouvée');
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('[PayPal] Erreur lancement app: $e');
      return false;
    }
  }

  /// Fallback : ouvre PayPal web (page send money).
  Future<bool> _openPayPalWeb() async {
    try {
      final uri = Uri.parse('https://www.paypal.com/myaccount/transfer/send');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        // ignore: avoid_print
        print('[PayPal] Web PayPal ouvert');
        return true;
      }
      // ignore: avoid_print
      print('[PayPal] Impossible d\'ouvrir le navigateur');
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('[PayPal] Erreur ouverture web: $e');
      return false;
    }
  }

  void dispose() {
    _configuredController.close();
  }
}
