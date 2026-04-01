package com.example.cobalt_task

import android.content.Intent
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Service qui ecoute les notifications entrantes des apps de messagerie.
 * Stocke l'historique dans SharedPreferences pour permettre a Flutter
 * de savoir sur quelle app un contact nous a ecrit recemment.
 *
 * Diffuse aussi un broadcast local pour le streaming temps reel vers Flutter.
 */
class CobaltNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "CobaltNotifListener"
        private const val PREFS_NAME = "cobalt_incoming_history"
        private const val KEY_HISTORY = "history"
        private const val MAX_ENTRIES = 200
        // Garder les entrees pendant 7 jours
        private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

        const val ACTION_NEW_MESSAGE = "com.cobalt_task.NEW_INCOMING_MESSAGE"
        const val EXTRA_SENDER = "sender"
        const val EXTRA_PREVIEW = "preview"
        const val EXTRA_PACKAGE = "package_name"
        const val EXTRA_TIMESTAMP = "timestamp"

        // Mapping package → nom d'app interne
        private val APP_MAP = mapOf(
            "com.whatsapp" to "whatsapp",
            "com.whatsapp.w4b" to "whatsapp",
            "org.telegram.messenger" to "telegram",
            "org.thoughtcrime.securesms" to "signal",
            "com.facebook.orca" to "messenger",
            "com.instagram.android" to "instagram",
            "com.linkedin.android" to "linkedin",
            "com.google.android.apps.messaging" to "sms",
            "com.android.mms" to "sms",
            "com.samsung.android.messaging" to "sms",
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val appName = APP_MAP[sbn.packageName] ?: return

        // Ignorer les résumés de groupe (notifications empilées Android)
        if (sbn.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY != 0) return

        val extras = sbn.notification.extras ?: return

        // === EXTRACTION DU MESSAGE ===
        // Les apps de messagerie utilisent MessagingStyle qui peuple android.messages.
        // On extrait le dernier message structuré pour avoir sender + texte propre.

        val senderName: String
        val messagePreview: String

        val messagesArray = extras.getParcelableArray("android.messages")

        if (messagesArray != null && messagesArray.isNotEmpty()) {
            // --- MessagingStyle disponible (WhatsApp, Telegram, Signal, Messenger, Instagram) ---

            // Filtrer les groupes via le flag officiel
            if (extras.getBoolean("android.isGroupConversation", false)) {
                Log.d(TAG, "Ignore groupe: ${extras.getCharSequence("android.title")} via $appName")
                return
            }

            // conversationTitle présent = groupe (WhatsApp, Telegram)
            val convTitle = extras.getCharSequence("android.conversationTitle")?.toString()
            if (!convTitle.isNullOrEmpty()) {
                // Vérifier si c'est un vrai groupe (titre != sender)
                val title = extras.getCharSequence("android.title")?.toString() ?: ""
                if (convTitle != title) {
                    Log.d(TAG, "Ignore groupe (convTitle=$convTitle): via $appName")
                    return
                }
            }

            // Extraire le dernier message du bundle
            val lastBundle = messagesArray.last() as? android.os.Bundle
            if (lastBundle == null) return

            val text = lastBundle.getCharSequence("text")?.toString() ?: ""

            // Filtrer messages vides ou emoji-only (réactions)
            if (text.isBlank() || isEmojiOnly(text)) {
                Log.d(TAG, "Ignore (vide/emoji): '$text' via $appName")
                return
            }

            // Sender : du bundle message, ou du titre de la notification
            senderName = lastBundle.getCharSequence("sender")?.toString()?.takeIf { it.isNotEmpty() }
                ?: extras.getCharSequence("android.title")?.toString()
                ?: return

            // Filtrer les réactions (likes, "a réagi", etc.)
            if (isReaction(text, senderName)) {
                Log.d(TAG, "Ignore (réaction): '$text' de $senderName via $appName")
                return
            }

            messagePreview = text

        } else {
            // --- Fallback : pas de MessagingStyle (SMS natif, LinkedIn, apps anciennes) ---
            senderName = extras.getCharSequence("android.title")?.toString() ?: return
            val text = extras.getCharSequence("android.text")?.toString() ?: ""

            // Filtrer les notifications système, appels, génériques
            val lower = (senderName + " " + text).lowercase()
            if (lower.contains("appel") || lower.contains("call")
                || lower.contains("missed") || lower.contains("manqué")
                || lower.contains("notification") || lower.contains("sauvegarde")
                || lower.contains("backup") || lower.contains("mise à jour")) {
                Log.d(TAG, "Ignore (système): '$senderName: $text' via $appName")
                return
            }

            // Filtrer messages vides ou emoji-only
            if (text.isBlank() || isEmojiOnly(text)) return

            // Filtrer les réactions
            if (isReaction(text, senderName)) {
                Log.d(TAG, "Ignore (réaction): '$text' de $senderName via $appName")
                return
            }

            messagePreview = text
        }

        val timestamp = System.currentTimeMillis()

        try {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val history = loadHistory(prefs)

            val entry = JSONObject().apply {
                put("sender", senderName)
                put("app", appName)
                put("timestamp", timestamp)
            }

            history.put(entry)

            // Nettoyer les vieilles entrees et limiter la taille
            val cleaned = cleanHistory(history)
            prefs.edit().putString(KEY_HISTORY, cleaned.toString()).apply()

            Log.d(TAG, "Notification: $senderName via $appName")
        } catch (e: Exception) {
            Log.e(TAG, "Erreur traitement notification: ${e.message}")
        }

        // Broadcast vers MainActivity pour streaming temps reel vers Flutter
        try {
            val intent = Intent(ACTION_NEW_MESSAGE).apply {
                setPackage(packageName)
                putExtra(EXTRA_SENDER, senderName)
                putExtra(EXTRA_PREVIEW, messagePreview)
                putExtra(EXTRA_PACKAGE, sbn.packageName)
                putExtra(EXTRA_TIMESTAMP, timestamp)
            }
            sendBroadcast(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Erreur broadcast: ${e.message}")
        }
    }

    /**
     * Vérifie si le texte ne contient que des emojis (réactions).
     * Heuristique : si après suppression de tous les caractères non-lettre/non-chiffre
     * il ne reste rien ET le texte fait ≤ 10 caractères, c'est un emoji/réaction.
     */
    private fun isEmojiOnly(text: String): Boolean {
        if (text.length > 10) return false
        val letters = text.replace(Regex("[^\\p{L}\\p{N}]"), "")
        return letters.isEmpty()
    }

    /**
     * Vérifie si le message est une notification de réaction (pas un vrai message).
     * Les apps de messagerie envoient des notifications pour les réactions/likes
     * qui ressemblent à des messages mais n'en sont pas.
     */
    private fun isReaction(text: String, senderName: String): Boolean {
        val lower = text.lowercase()
        val senderLower = senderName.lowercase()

        // Patterns de réaction courants (FR + EN)
        val reactionPatterns = listOf(
            // Messenger
            "a réagi", "a aimé", "liked a message", "reacted",
            "loved a message", "a réagi à votre",
            // WhatsApp
            "a réagi avec", "reacted with",
            // Instagram
            "a aimé votre message", "liked your message",
            "a répondu à votre story", "replied to your story",
            "a mentionné", "mentioned you",
            // Générique
            "a réagi", "reaction", "liked",
        )

        if (reactionPatterns.any { lower.contains(it) }) return true

        // Réaction = texte très court qui est juste un emoji dans un message plus long
        // Ex: "👍" seul ou "❤️" seul (déjà filtré par isEmojiOnly, mais double check)
        val trimmed = text.trim()
        if (trimmed.length <= 2 && trimmed.isNotEmpty()) {
            val letters = trimmed.replace(Regex("[^\\p{L}\\p{N}]"), "")
            if (letters.isEmpty()) return true
        }

        return false
    }

    private fun loadHistory(prefs: SharedPreferences): JSONArray {
        val raw = prefs.getString(KEY_HISTORY, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            JSONArray()
        }
    }

    private fun cleanHistory(history: JSONArray): JSONArray {
        val now = System.currentTimeMillis()
        val cleaned = JSONArray()

        // Parcourir en ordre inverse pour garder les plus recents
        val startIndex = if (history.length() > MAX_ENTRIES) history.length() - MAX_ENTRIES else 0

        for (i in startIndex until history.length()) {
            try {
                val entry = history.getJSONObject(i)
                val ts = entry.getLong("timestamp")
                if (now - ts < MAX_AGE_MS) {
                    cleaned.put(entry)
                }
            } catch (e: Exception) {
                // Ignorer les entrees malformees
            }
        }

        return cleaned
    }
}
