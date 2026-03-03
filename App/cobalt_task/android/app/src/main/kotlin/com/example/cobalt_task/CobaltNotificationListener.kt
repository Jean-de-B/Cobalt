package com.example.cobalt_task

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
 */
class CobaltNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "CobaltNotifListener"
        private const val PREFS_NAME = "cobalt_incoming_history"
        private const val KEY_HISTORY = "history"
        private const val MAX_ENTRIES = 200
        // Garder les entrees pendant 7 jours
        private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

        // Mapping package → nom d'app interne
        private val APP_MAP = mapOf(
            "com.whatsapp" to "whatsapp",
            "com.whatsapp.w4b" to "whatsapp",
            "org.telegram.messenger" to "telegram",
            "org.thoughtcrime.securesms" to "signal",
            "com.facebook.orca" to "messenger",
            "com.google.android.apps.messaging" to "sms",
            "com.android.mms" to "sms",
            "com.samsung.android.messaging" to "sms",
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val appName = APP_MAP[sbn.packageName] ?: return

        val extras = sbn.notification.extras
        val senderName = extras?.getCharSequence("android.title")?.toString() ?: return

        // Ignorer les notifications de groupe generiques
        if (senderName.contains("messages") || senderName.contains("notification")) return

        try {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val history = loadHistory(prefs)

            val entry = JSONObject().apply {
                put("sender", senderName)
                put("app", appName)
                put("timestamp", System.currentTimeMillis())
            }

            history.put(entry)

            // Nettoyer les vieilles entrees et limiter la taille
            val cleaned = cleanHistory(history)
            prefs.edit().putString(KEY_HISTORY, cleaned.toString()).apply()

            Log.d(TAG, "Notification: $senderName via $appName")
        } catch (e: Exception) {
            Log.e(TAG, "Erreur traitement notification: ${e.message}")
        }
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
                val timestamp = entry.getLong("timestamp")
                if (now - timestamp < MAX_AGE_MS) {
                    cleaned.put(entry)
                }
            } catch (e: Exception) {
                // Ignorer les entrees malformees
            }
        }

        return cleaned
    }
}
