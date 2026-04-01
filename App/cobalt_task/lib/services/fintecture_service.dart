import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import '../models/fintecture_transaction.dart';
import 'database_service.dart';

/// =============================================================================
/// fintecture_service.dart
/// =============================================================================
/// Service Fintecture (Open Banking PSD2 Request-to-Pay).
/// Singleton — OAuth2 + génération RTP + polling statut + stockage IBAN.
/// =============================================================================

class FintectureService {
  static FintectureService? _instance;
  factory FintectureService() {
    _instance ??= FintectureService._internal();
    return _instance!;
  }
  FintectureService._internal();

  final _storage = const FlutterSecureStorage();
  final _db = DatabaseService();

  // --- Config ---
  static const _keyIban = 'fintecture_user_iban';
  static const _keyBic = 'fintecture_user_bic';

  String get _appId => dotenv.env['FINTECTURE_APP_ID'] ?? '';
  String get _appSecret => dotenv.env['FINTECTURE_APP_SECRET'] ?? '';
  String get _privateKeyPem => dotenv.env['FINTECTURE_PRIVATE_KEY'] ?? '';
  bool get _isSandbox => (dotenv.env['FINTECTURE_ENV'] ?? 'sandbox') == 'sandbox';
  String get _baseUrl => _isSandbox
      ? 'https://api-sandbox.fintecture.com'
      : 'https://api.fintecture.com';

  // --- State ---
  String? _accessToken;
  DateTime? _tokenExpiry;
  bool _initialized = false;

  final _transactionsController =
      StreamController<List<FintectureTransaction>>.broadcast();
  Stream<List<FintectureTransaction>> get transactionsStream =>
      _transactionsController.stream;

  List<FintectureTransaction> _cachedTransactions = [];
  List<FintectureTransaction> get transactions => _cachedTransactions;

  final _configuredController = StreamController<bool>.broadcast();
  Stream<bool> get configuredStream => _configuredController.stream;

  Timer? _pollTimer;

  // =========================================================================
  // Initialisation
  // =========================================================================

  static const _fintectureChannel = MethodChannel('com.cobalt_task/fintecture');

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Écouter les callbacks deep link depuis le natif
    _fintectureChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPaymentCallback') {
        final state = call.arguments['state'] as String? ?? '';
        if (state.isNotEmpty) {
          await handleCallback(Uri.parse('cobalt://fintecture/callback?state=$state'));
        }
      }
    });

    await _refreshTransactions();
    _startPolling();
    // ignore: avoid_print
    print('[Fintecture] Service initialisé (${_isSandbox ? "sandbox" : "production"})');
  }

  void dispose() {
    _pollTimer?.cancel();
    _transactionsController.close();
    _configuredController.close();
  }

  // =========================================================================
  // IBAN configuration
  // =========================================================================

  Future<bool> hasIban() async {
    final iban = await _storage.read(key: _keyIban);
    return iban != null && iban.isNotEmpty;
  }

  Future<String> getMaskedIban() async {
    final iban = await _storage.read(key: _keyIban);
    if (iban == null || iban.length < 8) return '—';
    return '${iban.substring(0, 4)}${'*' * (iban.length - 8)}${iban.substring(iban.length - 4)}';
  }

  Future<bool> setupUserIban(String iban, String bic) async {
    final cleanIban = iban.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (!_validateIban(cleanIban)) return false;

    await _storage.write(key: _keyIban, value: cleanIban);
    await _storage.write(key: _keyBic, value: bic.toUpperCase().trim());
    _configuredController.add(true);
    // ignore: avoid_print
    print('[Fintecture] IBAN configuré: ${cleanIban.substring(0, 4)}****');
    return true;
  }

  Future<void> clearIban() async {
    await _storage.delete(key: _keyIban);
    await _storage.delete(key: _keyBic);
    _configuredController.add(false);
  }

  bool _validateIban(String iban) {
    if (iban.length < 15 || iban.length > 34) return false;
    if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(iban)) return false;

    // Checksum mod-97
    final rearranged = iban.substring(4) + iban.substring(0, 4);
    final numeric = rearranged.split('').map((c) {
      final code = c.codeUnitAt(0);
      return code >= 65 ? (code - 55).toString() : c;
    }).join();

    BigInt value = BigInt.parse(numeric);
    return value % BigInt.from(97) == BigInt.one;
  }

  // =========================================================================
  // OAuth2
  // =========================================================================

  Future<String> _getAccessToken() async {
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _accessToken!;
    }
    return await _authenticate();
  }

  Future<String> _authenticate() async {
    final credentials = base64Encode(utf8.encode('$_appId:$_appSecret'));

    final response = await http.post(
      Uri.parse('$_baseUrl/oauth/accesstoken'),
      headers: {
        'Authorization': 'Basic $credentials',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'grant_type=client_credentials&scope=PIS',
    );

    if (response.statusCode != 200) {
      throw Exception('Fintecture auth failed: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body);
    _accessToken = json['access_token'] as String;
    final expiresIn = json['expires_in'] as int? ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));

    return _accessToken!;
  }

  // =========================================================================
  // Request-to-Pay
  // =========================================================================

  Future<FintectureTransaction?> createRequestToPay({
    required String recipientName,
    required String recipientPhone,
    required double amount,
    String note = '',
  }) async {
    try {
      final iban = await _storage.read(key: _keyIban);
      final bic = await _storage.read(key: _keyBic);
      if (iban == null || iban.isEmpty) {
        // ignore: avoid_print
        print('[Fintecture] IBAN non configuré');
        return null;
      }

      final token = await _getAccessToken();
      final state = const Uuid().v4();

      final payload = {
        'data': {
          'type': 'REQUEST_TO_PAY',
          'attributes': {
            'amount': amount.toStringAsFixed(2),
            'currency': 'EUR',
            'communication': note.isNotEmpty ? note : 'Remboursement via Cobalt',
          },
        },
        'meta': {
          'psu_name': recipientName,
          'psu_phone': recipientPhone,
          'beneficiary': {
            'name': recipientName, // Will be replaced by IBAN holder
            'iban': iban,
            if (bic != null && bic.isNotEmpty) 'swift_bic': bic,
          },
        },
      };

      final bodyJson = jsonEncode(payload);
      final digest = _computeDigest(bodyJson);
      final signature = _signPayload(digest);

      final response = await http.post(
        Uri.parse('$_baseUrl/pis/v2/request-to-pay?state=$state'
            '&redirect_uri=${Uri.encodeComponent("cobalt://fintecture/callback")}'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Digest': 'SHA-256=$digest',
          'Signature': signature,
          'X-Request-Id': const Uuid().v4(),
        },
        body: bodyJson,
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        // ignore: avoid_print
        print('[Fintecture] RTP failed: ${response.statusCode} ${response.body}');
        return null;
      }

      final json = jsonDecode(response.body);
      final paymentUrl = json['meta']?['url'] as String? ?? '';

      final tx = FintectureTransaction(
        id: state,
        recipientName: recipientName,
        recipientPhone: recipientPhone,
        amount: amount,
        note: note,
        paymentUrl: paymentUrl,
        status: FintectureStatus.pending,
        createdAt: DateTime.now(),
      );

      await _db.insertFintectureTransaction(tx);
      await _refreshTransactions();

      // ignore: avoid_print
      print('[Fintecture] RTP créé: $state → $paymentUrl');
      return tx;
    } catch (e) {
      // ignore: avoid_print
      print('[Fintecture] Erreur RTP: $e');
      return null;
    }
  }

  // =========================================================================
  // Digest / Signature RSA
  // =========================================================================

  String _computeDigest(String body) {
    final bytes = utf8.encode(body);
    final digest = sha256.convert(bytes);
    return base64Encode(digest.bytes);
  }

  String _signPayload(String digest) {
    if (_privateKeyPem.isEmpty) return '';

    try {
      final privateKey = _parseRsaPrivateKey(_privateKeyPem);
      final signingString = 'digest: SHA-256=$digest';
      final signer = RSASigner(SHA256Digest(), '0609608648016503040201');

      signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
      final sig = signer.generateSignature(
        Uint8List.fromList(utf8.encode(signingString)),
      );
      final b64 = base64Encode(sig.bytes);

      return 'keyId="$_appId",algorithm="rsa-sha256",headers="digest",signature="$b64"';
    } catch (e) {
      // ignore: avoid_print
      print('[Fintecture] Erreur signature: $e');
      return '';
    }
  }

  RSAPrivateKey _parseRsaPrivateKey(String pem) {
    final rows = pem
        .replaceAll('\\n', '\n')
        .split('\n')
        .where((line) => !line.startsWith('-----') && line.trim().isNotEmpty)
        .join();

    final keyBytes = base64Decode(rows);

    final asn1Parser = ASN1Parser(Uint8List.fromList(keyBytes));
    final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;

    // PKCS#1 format
    final elements = topLevelSeq.elements!;
    final modulus = (elements[1] as ASN1Integer).valueAsBigInteger;
    final publicExponent = (elements[2] as ASN1Integer).valueAsBigInteger;
    final privateExponent = (elements[3] as ASN1Integer).valueAsBigInteger;
    final p = (elements[4] as ASN1Integer).valueAsBigInteger;
    final q = (elements[5] as ASN1Integer).valueAsBigInteger;

    return RSAPrivateKey(modulus, privateExponent, p, q, publicExponent);
  }

  // =========================================================================
  // Polling statut
  // =========================================================================

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pollPendingTransactions());
  }

  Future<void> _pollPendingTransactions() async {
    final pending = _cachedTransactions
        .where((tx) => tx.status == FintectureStatus.pending)
        .toList();

    if (pending.isEmpty) return;

    for (final tx in pending) {
      // Expire après 24h
      if (DateTime.now().difference(tx.createdAt).inHours >= 24) {
        await _db.updateFintectureTransactionStatus(tx.id, FintectureStatus.expired);
        continue;
      }

      try {
        final token = await _getAccessToken();
        final response = await http.get(
          Uri.parse('$_baseUrl/pis/v2/payments?state=${tx.id}'),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          final sessions = json['data'] as List<dynamic>?;
          if (sessions != null && sessions.isNotEmpty) {
            final status = sessions.first['attributes']?['status'] as String? ?? '';

            if (status == 'payment_received' || status == 'payment_created') {
              await _db.updateFintectureTransactionStatus(
                tx.id,
                FintectureStatus.paid,
                paidAt: DateTime.now(),
              );
              _showPaymentNotification(tx);
            }
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('[Fintecture] Poll error for ${tx.id}: $e');
      }
    }

    await _refreshTransactions();
  }

  Future<void> _showPaymentNotification(FintectureTransaction tx) async {
    // Notification locale via MethodChannel
    try {
      const channel = MethodChannel('com.cobalt_task/notifications');
      await channel.invokeMethod('showNotification', {
        'title': 'Paiement reçu',
        'body': '${tx.recipientName} t\'a remboursé ${tx.formattedAmount} \u2713',
      });
    } catch (_) {
      // ignore
    }
  }

  // =========================================================================
  // Gestion transactions (DB)
  // =========================================================================

  Future<void> _refreshTransactions() async {
    _cachedTransactions = await _db.getFintectureTransactions();
    _transactionsController.add(List.unmodifiable(_cachedTransactions));
  }

  Future<void> deleteTransaction(String id) async {
    await _db.deleteFintectureTransaction(id);
    await _refreshTransactions();
  }

  // =========================================================================
  // Deep link callback
  // =========================================================================

  Future<void> handleCallback(Uri uri) async {
    final state = uri.queryParameters['state'];
    if (state == null) return;

    // ignore: avoid_print
    print('[Fintecture] Callback reçu: state=$state');

    // Force un poll immédiat pour cette transaction
    await _pollPendingTransactions();
  }
}
