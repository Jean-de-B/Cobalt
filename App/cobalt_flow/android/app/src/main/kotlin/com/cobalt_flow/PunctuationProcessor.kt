package com.cobalt_flow

/**
 * Post-traitement de la ponctuation pour les transcriptions vocales.
 * Applique capitalisation, points finaux et détection de questions.
 */
object PunctuationProcessor {

    private val questionStarters = listOf(
        "est-ce", "est ce", "quand", "comment", "pourquoi",
        "qui", "que", "qu'", "quel", "quelle", "combien", "où",
        "what", "when", "where", "why", "how", "who", "which",
        "is it", "are you", "do you", "can you", "will you"
    )

    fun process(text: String): String {
        var result = text.trim()
        if (result.isEmpty()) return result

        // Capitalise la première lettre
        result = result.replaceFirstChar { it.uppercase() }

        // Si pas de ponctuation finale, en ajouter une
        val lastChar = result.last()
        if (lastChar.isLetterOrDigit()) {
            result = if (isQuestion(result)) "$result?" else "$result."
        }

        return result
    }

    private fun isQuestion(text: String): Boolean {
        val lower = text.lowercase()
        return questionStarters.any { lower.startsWith(it) }
    }
}
