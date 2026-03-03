/// =============================================================================
/// json_sanitizer.dart
/// =============================================================================
/// Utilitaire pour nettoyer et extraire du JSON depuis les réponses LLM.
/// Gère les cas où le modèle ajoute du texte avant/après le JSON.
/// =============================================================================

class JsonSanitizer {
  /// Extrait le premier bloc JSON valide d'une chaîne
  ///
  /// Gère les cas courants:
  /// - JSON pur
  /// - JSON avec texte avant ("Voici le résultat: {...}")
  /// - JSON avec texte après ("{...} J'espère que cela aide")
  /// - JSON dans des blocs markdown (```json ... ```)
  /// - Objets et tableaux JSON
  static String extractJson(String input) {
    if (input.isEmpty) {
      throw const FormatException('Input is empty');
    }

    String cleaned = input.trim();

    // Cas 1: Extraire depuis un bloc markdown ```json ... ```
    final markdownMatch = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
      multiLine: true,
    ).firstMatch(cleaned);

    if (markdownMatch != null) {
      cleaned = markdownMatch.group(1)?.trim() ?? cleaned;
    }

    // Cas 2: Trouver le premier '{' ou '['
    final objectStart = cleaned.indexOf('{');
    final arrayStart = cleaned.indexOf('[');

    int start;
    String closeChar;

    if (objectStart == -1 && arrayStart == -1) {
      throw const FormatException('No JSON object or array found');
    } else if (objectStart == -1) {
      start = arrayStart;
      closeChar = ']';
    } else if (arrayStart == -1) {
      start = objectStart;
      closeChar = '}';
    } else {
      // Prendre le premier des deux
      if (objectStart < arrayStart) {
        start = objectStart;
        closeChar = '}';
      } else {
        start = arrayStart;
        closeChar = ']';
      }
    }

    // Cas 3: Trouver la fermeture correspondante (gestion des imbrications)
    final end = _findMatchingClose(
      cleaned,
      start,
      closeChar == '}' ? '{' : '[',
      closeChar,
    );

    if (end == -1) {
      throw FormatException(
        'No matching closing bracket found for ${closeChar == "}" ? "{" : "["}',
      );
    }

    return cleaned.substring(start, end + 1);
  }

  /// Trouve la position du caractère de fermeture correspondant
  static int _findMatchingClose(
    String input,
    int start,
    String openChar,
    String closeChar,
  ) {
    int depth = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = start; i < input.length; i++) {
      final char = input[i];

      // Gestion des chaînes (ignorer les accolades dans les strings)
      if (char == '"' && !escaped) {
        inString = !inString;
      }

      // Gestion de l'échappement
      escaped = (char == '\\' && !escaped);

      if (!inString) {
        if (char == openChar) {
          depth++;
        } else if (char == closeChar) {
          depth--;
          if (depth == 0) {
            return i;
          }
        }
      }
    }

    return -1;
  }

  /// Tente d'extraire le JSON, retourne null si échec
  static String? tryExtractJson(String input) {
    try {
      return extractJson(input);
    } catch (_) {
      return null;
    }
  }

  /// Nettoie les caractères de contrôle problématiques
  static String cleanControlChars(String input) {
    // Supprimer les caractères de contrôle sauf newline et tab
    return input.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
  }

  /// Corrige les erreurs JSON courantes
  static String fixCommonErrors(String input) {
    String fixed = input;

    // Virgules trailing avant } ou ]
    fixed = fixed.replaceAll(RegExp(r',\s*}'), '}');
    fixed = fixed.replaceAll(RegExp(r',\s*\]'), ']');

    // Guillemets simples -> doubles (attention aux apostrophes)
    // Ne pas faire cette correction car trop risquée

    return fixed;
  }

  /// Pipeline complet de nettoyage
  static String sanitize(String input) {
    String result = cleanControlChars(input);
    result = extractJson(result);
    result = fixCommonErrors(result);
    return result;
  }
}
