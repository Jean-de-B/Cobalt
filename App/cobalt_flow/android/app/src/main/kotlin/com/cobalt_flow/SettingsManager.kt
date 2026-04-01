package com.cobalt_flow

import android.content.Context
import android.content.SharedPreferences

/**
 * Gère les paramètres partagés entre l'app Flutter (écriture) et le service IME (lecture).
 * Utilise SharedPreferences comme pont — pas de MethodChannel possible entre IME et Activity.
 */
object SettingsManager {
    private const val PREFS_NAME = "cobalt_flow_settings"

    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    var language: String
        get() = prefs?.getString("language", "fr") ?: "fr"
        set(value) { prefs?.edit()?.putString("language", value)?.apply() }

    var autoPunctuation: Boolean
        get() = prefs?.getBoolean("auto_punctuation", true) ?: true
        set(value) { prefs?.edit()?.putBoolean("auto_punctuation", value)?.apply() }

    var useGroq: Boolean
        get() = prefs?.getBoolean("use_groq", true) ?: true
        set(value) { prefs?.edit()?.putBoolean("use_groq", value)?.apply() }

    var groqApiKey: String
        get() = prefs?.getString("groq_api_key", "") ?: ""
        set(value) { prefs?.edit()?.putString("groq_api_key", value)?.apply() }
}
