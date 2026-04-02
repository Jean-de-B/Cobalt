import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/ai_action.dart';
import 'json_sanitizer.dart';

/// =============================================================================
/// groq_client.dart
/// =============================================================================
/// Client pour l'API Groq avec Llama 3.
/// Utilise le Few-Shot Prompting pour extraire des actions structurées.
/// =============================================================================

class GroqClient {
  static GroqClient? _instance;

  final String _apiKey;
  final String _model;
  final String _baseUrl;

  // Utilisation du même modèle que AI_SORTER qui fonctionne
  static const String _defaultModel = 'llama-3.1-8b-instant';
  static const String _defaultBaseUrl =
      'https://api.groq.com/openai/v1/chat/completions';

  /// Constructeur privé
  GroqClient._({
    required String apiKey,
    String? model,
    String? baseUrl,
  })  : _apiKey = apiKey,
        _model = model ?? _defaultModel,
        _baseUrl = baseUrl ?? _defaultBaseUrl;

  /// Factory Singleton
  factory GroqClient({String? apiKey, String? model}) {
    _instance ??= GroqClient._(
      apiKey: apiKey ?? dotenv.env['GROQ_API_KEY'] ?? '',
      model: model,
    );
    return _instance!;
  }

  /// Reset singleton (pour tests)
  static void reset() => _instance = null;

  /// Vérifie si le client est configuré
  bool get isConfigured => _apiKey.isNotEmpty;

  // ===========================================================================
  // PROMPT SYSTÈME AVEC FEW-SHOT
  // ===========================================================================

  /// Génère le prompt système avec contexte temporel (version optimisée)
  String _buildSystemPrompt() {
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return '''
Assistant vocal FR. JSON uniquement. Date:$dateStr Heure:$timeStr
Règles: reasoning=court, heure sans date=aujourd'hui(demain si passée), durée relative=heure exacte

INTENTS: calendar,sms,alarm,timer,system_control,call,messaging,message,navigation,media,app_launch,payment,none
system_control: volume_up/down/set/mute,vibrate/silent/normal,dnd_on/off,wifi_toggle,bluetooth_toggle,flashlight_on/off
media: play,pause,next,previous,stop,play_search(query+app optionnel),like,transfer(device_type:ordinateur/telephone/enceinte/tv)
"joue/mets/lance/écoute"+texte=TOUJOURS media play_search. Combinable avec device_type.
navigation: destination+mode optionnel(velo/voiture/pied/transport)
payment: recipient+amount+note. Montant€+destinataire=TOUJOURS payment. "rembourse/paye/envoie X€ à Y"=payment, PAS message.
alarm: UNIQUEMENT réveille-moi/alarme/réveil. "rappelle-moi"=none(mémo). "pense à/n'oublie pas"=none.

{"reasoning":"..","intent":"..","params":{..}}

"Timer 5 min"→{"reasoning":"Timer","intent":"timer","params":{"duration_seconds":300,"label":"Timer"}}
"RDV dentiste demain 14h30"→{"reasoning":"Cal","intent":"calendar","params":{"title":"Dentiste","start_time":"${now.add(const Duration(days: 1)).toString().split(' ')[0]}T14:30:00"}}
"SMS à maman: j'arrive"→{"reasoning":"SMS","intent":"sms","params":{"recipient":"maman","message":"J'arrive"}}
"Réveille-moi à 7h"→{"reasoning":"Alarme","intent":"alarm","params":{"time":"${_computeAlarmTime(now, 7, 0)}","label":"Réveil"}}
"Son à fond"→{"reasoning":"Vol max","intent":"system_control","params":{"control_type":"volume_set","value":100}}
"Acheter du lait"→{"reasoning":"Mémo","intent":"none","params":{"memo":"Acheter du lait"}}
"Rappelle-moi d'appeler le médecin"→{"reasoning":"Rappel=mémo","intent":"none","params":{"memo":"Rappelle-moi d'appeler le médecin"}}
"Appelle maman"→{"reasoning":"Appel","intent":"call","params":{"contact":"maman"}}
"WhatsApp à Pierre: en route"→{"reasoning":"WA","intent":"messaging","params":{"app":"whatsapp","recipient":"Pierre","message":"En route"}}
"Dis à Paul que j'arrive"→{"reasoning":"Msg","intent":"message","params":{"recipient":"Paul","message":"J'arrive"}}
"Emmène-moi gare de Lyon"→{"reasoning":"Nav","intent":"navigation","params":{"destination":"Gare de Lyon"}}
"Emmène-moi au travail en vélo"→{"reasoning":"Nav vélo","intent":"navigation","params":{"destination":"travail","mode":"velo"}}
"Amène-moi au cinéma en bus"→{"reasoning":"Nav bus","intent":"navigation","params":{"destination":"cinéma","mode":"bus"}}
"Ouvre Instagram"→{"reasoning":"App","intent":"app_launch","params":{"app_name":"Instagram"}}
"Mets pause"→{"reasoning":"Pause","intent":"media","params":{"control_type":"pause"}}
"Joue tant pis pour elle"→{"reasoning":"Musique","intent":"media","params":{"control_type":"play_search","query":"tant pis pour elle"}}
"Joue Stromae sur mon ordinateur"→{"reasoning":"Musique+device","intent":"media","params":{"control_type":"play_search","query":"Stromae","device_type":"ordinateur"}}
"Like ce titre"→{"reasoning":"Like","intent":"media","params":{"control_type":"like"}}
"Joue sur mon ordinateur"→{"reasoning":"Transfer","intent":"media","params":{"control_type":"transfer","device_type":"ordinateur"}}
"Allume la lampe"→{"reasoning":"Lampe","intent":"system_control","params":{"control_type":"flashlight_on"}}

"Rembourse 20 euros à Paul" → {"reasoning":"Montant + destinataire = paiement","intent":"payment","params":{"recipient":"Paul","amount":20}}

"Rembourse Paul de 10 euros" → {"reasoning":"Remboursement","intent":"payment","params":{"recipient":"Paul","amount":10}}

"Paye 30 euros à Julie" → {"reasoning":"Payer = paiement","intent":"payment","params":{"recipient":"Julie","amount":30}}

"Envoie 5 euros à Thomas pour la bière" → {"reasoning":"Envoi argent + motif","intent":"payment","params":{"recipient":"Thomas","amount":5,"note":"la bière"}}

"Demande à Marie de me rembourser 15 euros pour le resto" → {"reasoning":"Demande remboursement","intent":"payment","params":{"recipient":"Marie","amount":15,"note":"le resto"}}

"Transfère 50 euros à Sophie" → {"reasoning":"Transfert argent","intent":"payment","params":{"recipient":"Sophie","amount":50}}

"Je dois 12 euros à Marc" → {"reasoning":"Dette = paiement","intent":"payment","params":{"recipient":"Marc","amount":12}}

Analyse:
''';
  }

  /// Calcule l'heure d'alarme (aujourd'hui ou demain si passée)
  static String _computeAlarmTime(DateTime now, int hour, int minute) {
    var alarm = DateTime(now.year, now.month, now.day, hour, minute);
    if (alarm.isBefore(now)) {
      alarm = alarm.add(const Duration(days: 1));
    }
    return alarm.toIso8601String();
  }

  // ===========================================================================
  // APPEL API
  // ===========================================================================

  /// Analyse une transcription et retourne une action structurée
  Future<AiAction> analyzeTranscript(String transcript) async {
    if (!isConfigured) {
      throw GroqClientException('API key not configured');
    }

    if (transcript.trim().isEmpty) {
      return NoAction(
        reasoning: 'Transcription vide',
        memo: null,
      );
    }

    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'system',
              'content': _buildSystemPrompt(),
            },
            {
              'role': 'user',
              'content': transcript,
            },
          ],
          'response_format': {'type': 'json_object'},
          'temperature': 0.3, // Basse pour plus de cohérence
          'max_tokens': 500,
        }),
      );

      // ignore: avoid_print
      print('[GroqClient] API Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print('[GroqClient] API Error Body: ${response.body}');
        throw GroqClientException(
          'API error: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final content = data['choices']?[0]?['message']?['content'] as String?;

      if (content == null || content.isEmpty) {
        throw GroqClientException('Empty response from API');
      }

      // ignore: avoid_print
      print('[GroqClient] Réponse brute du modèle: $content');

      // Sanitize et parse le JSON
      final cleanJson = JsonSanitizer.extractJson(content);
      // ignore: avoid_print
      print('[GroqClient] JSON nettoyé: $cleanJson');

      final actionJson = jsonDecode(cleanJson) as Map<String, dynamic>;
      // ignore: avoid_print
      print('[GroqClient] Intent détecté: ${actionJson['intent']}');

      // Ajouter le texte original pour référence
      actionJson['original_text'] = transcript;

      return AiAction.fromJson(actionJson);
    } on FormatException catch (e) {
      // Erreur de parsing JSON - retourner un mémo
      // ignore: avoid_print
      print('[GroqClient] JSON parse error: $e');
      return NoAction(
        reasoning: 'Erreur de parsing JSON: ${e.message}',
        memo: transcript,
      );
    } on http.ClientException catch (e) {
      throw GroqClientException('Network error: $e');
    }
  }

  /// Analyse avec retry automatique et gestion du rate limiting
  Future<AiAction> analyzeWithRetry(
    String transcript, {
    int maxRetries = 2,
  }) async {
    GroqClientException? lastError;

    for (int i = 0; i <= maxRetries; i++) {
      try {
        // ignore: avoid_print
        print('[GroqClient] Tentative ${i + 1}/${maxRetries + 1}...');
        return await analyzeTranscript(transcript);
      } on GroqClientException catch (e) {
        lastError = e;
        // ignore: avoid_print
        print('[GroqClient] Échec tentative ${i + 1}: ${e.message}');

        if (i < maxRetries) {
          // Vérifier si c'est une erreur de rate limiting (429)
          int delayMs;
          if (e.message.contains('429') || e.message.contains('rate_limit')) {
            // Parser le temps d'attente depuis le message d'erreur
            final waitTime = _parseRetryAfter(e.message);
            delayMs = (waitTime * 1000).toInt();
            // ignore: avoid_print
            print('[GroqClient] Rate limit - attente ${waitTime}s...');
          } else {
            // Backoff exponentiel standard
            delayMs = 1000 * (i + 1);
          }
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      } catch (e) {
        // ignore: avoid_print
        print('[GroqClient] Erreur inattendue tentative ${i + 1}: $e');
        if (i < maxRetries) {
          await Future.delayed(Duration(milliseconds: 1000 * (i + 1)));
        }
      }
    }

    // Après tous les retries, retourner un mémo par défaut
    // ignore: avoid_print
    print('[GroqClient] ÉCHEC TOTAL après ${maxRetries + 1} tentatives: $lastError');
    return NoAction(
      reasoning: 'Échec de l\'analyse après $maxRetries tentatives',
      memo: transcript,
    );
  }

  /// Parse le temps d'attente depuis un message d'erreur 429
  double _parseRetryAfter(String errorMessage) {
    // Chercher "try again in X.XXs" ou "try again in Xs"
    final regex = RegExp(r'try again in (\d+\.?\d*)s');
    final match = regex.firstMatch(errorMessage);
    if (match != null) {
      return double.tryParse(match.group(1)!) ?? 16.0;
    }
    // Défaut: 16 secondes (un peu plus que la limite typique de 15s)
    return 16.0;
  }
}

/// Exception spécifique au client Groq
class GroqClientException implements Exception {
  final String message;

  GroqClientException(this.message);

  @override
  String toString() => 'GroqClientException: $message';
}
