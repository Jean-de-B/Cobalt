import 'dart:async';
import 'package:flutter/services.dart';

/// =============================================================================
/// assistant_launch_service.dart
/// =============================================================================
/// Detecte quand l'app est lancee via l'intent ASSIST
/// (long-press home, headphone button, geste systeme).
///
/// Quand Cobalt est configure comme assistant par defaut dans
/// Parametres > Apps > Apps par defaut > App d'assistance numerique,
/// le systeme envoie ACTION_ASSIST qui arrive ici via MethodChannel.
///
/// Flow:
///   Android ASSIST → AssistantActivity → MainActivity (launch_mode=assist)
///   → MethodChannel "onAssistLaunch" → assistLaunchStream → HomeScreen
///   → AudioService.startRecording()
/// =============================================================================

class AssistantLaunchService {
  static AssistantLaunchService? _instance;

  static const _channel = MethodChannel('com.cobalt_task/assistant');
  static const _diagChannel =
      MethodChannel('com.cobalt_task/assistant_diagnostics');

  final _assistLaunchController = StreamController<String>.broadcast();

  /// Stream qui emet quand un lancement ASSIST est detecte.
  /// La valeur est la source (ex: "android.intent.action.ASSIST").
  Stream<String> get assistLaunchStream => _assistLaunchController.stream;

  /// Singleton
  factory AssistantLaunchService() {
    _instance ??= AssistantLaunchService._internal();
    return _instance!;
  }

  AssistantLaunchService._internal() {
    _channel.setMethodCallHandler(_handleMethodCall);
    // ignore: avoid_print
    print('[AssistantLaunch] Service initialisé');
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onAssistLaunch':
        final source = call.arguments?['source'] as String? ?? 'unknown';
        // ignore: avoid_print
        print('[AssistantLaunch] ASSIST detecte - source: $source');
        _assistLaunchController.add(source);
        break;
    }
  }

  /// Verifie si un lancement ASSIST est en attente (cold start).
  ///
  /// Au cold start, le MethodChannel peut ne pas etre pret quand
  /// MainActivity envoie "onAssistLaunch". On stocke donc un flag
  /// dans SharedPreferences cote natif, et Flutter le verifie ici.
  Future<void> checkPendingAssistLaunch() async {
    try {
      final result = await _channel.invokeMethod('checkPendingAssist');
      if (result == true) {
        // ignore: avoid_print
        print('[AssistantLaunch] Pending ASSIST detecte (cold start)');
        _assistLaunchController.add('cold_start');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[AssistantLaunch] Erreur check pending: $e');
    }
  }

  // ===========================================================================
  // DIAGNOSTICS : verifier la configuration assistant et ouvrir les parametres
  // ===========================================================================

  /// Retourne un Map avec l'etat complet de la configuration assistant.
  /// Cles importantes:
  ///   - isRoleAssistantHeld: true si Cobalt detient le role ASSISTANT
  ///   - isCobaltVoiceService: true si le VoiceInteractionService est actif
  ///   - isSamsung: true si l'appareil est Samsung
  ///   - currentAssistant: le package de l'assistant actuel
  Future<Map<String, dynamic>> getAssistantStatus() async {
    try {
      final result = await _diagChannel.invokeMethod('getAssistantStatus');
      // ignore: avoid_print
      print('[AssistantLaunch] Diagnostics: $result');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      // ignore: avoid_print
      print('[AssistantLaunch] Erreur diagnostics: $e');
      return {'error': e.toString()};
    }
  }

  /// Demande le role ASSISTANT via RoleManager (API 29+).
  /// Ouvre un dialog systeme pour confirmation utilisateur.
  /// Retourne: {status: "granted"|"denied"|"already_held"|"not_available"|"error"}
  Future<Map<String, dynamic>> requestAssistantRole() async {
    try {
      final result = await _diagChannel.invokeMethod('requestAssistantRole');
      // ignore: avoid_print
      print('[AssistantLaunch] Role request result: $result');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      // ignore: avoid_print
      print('[AssistantLaunch] Erreur role request: $e');
      return {'status': 'error', 'message': e.toString()};
    }
  }

  /// Ouvre la page Parametres > Apps par defaut > Assistant numerique
  Future<void> openDefaultAssistantSettings() async {
    try {
      await _diagChannel.invokeMethod('openDefaultAssistantSettings');
    } catch (e) {
      // ignore: avoid_print
      print('[AssistantLaunch] Erreur open settings: $e');
    }
  }

  /// Ouvre la page Samsung Parametres > Fonctions avancees (Side Key)
  Future<void> openSideKeySettings() async {
    try {
      await _diagChannel.invokeMethod('openSideKeySettings');
    } catch (e) {
      // ignore: avoid_print
      print('[AssistantLaunch] Erreur open side key settings: $e');
    }
  }

  void dispose() {
    _assistLaunchController.close();
  }
}
