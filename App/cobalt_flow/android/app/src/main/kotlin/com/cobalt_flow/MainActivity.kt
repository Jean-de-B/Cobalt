package com.cobalt_flow

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Activity Flutter pour l'app de paramétrage Cobalt Flow.
 * Communique les paramètres de Flutter vers SharedPreferences
 * (lues par le CobaltRecognitionService).
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.cobalt_flow/settings"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        SettingsManager.init(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSettings" -> {
                    result.success(mapOf(
                        "language" to SettingsManager.language,
                        "autoPunctuation" to SettingsManager.autoPunctuation,
                        "useGroq" to SettingsManager.useGroq,
                        "groqApiKey" to SettingsManager.groqApiKey
                    ))
                }
                "setLanguage" -> {
                    SettingsManager.language = call.argument<String>("value") ?: "fr"
                    result.success(true)
                }
                "setAutoPunctuation" -> {
                    SettingsManager.autoPunctuation = call.argument<Boolean>("value") ?: true
                    result.success(true)
                }
                "setUseGroq" -> {
                    SettingsManager.useGroq = call.argument<Boolean>("value") ?: true
                    result.success(true)
                }
                "setGroqApiKey" -> {
                    SettingsManager.groqApiKey = call.argument<String>("value") ?: ""
                    result.success(true)
                }
                "isRecognitionServiceEnabled" -> {
                    val enabled = isDefaultRecognitionService()
                    result.success(enabled)
                }
                "openVoiceInputSettings" -> {
                    try {
                        // Open the voice input settings where user can select Cobalt Flow
                        val intent = Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // Fallback: open general settings
                        try {
                            val intent = Intent(Settings.ACTION_SETTINGS)
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("SETTINGS_ERROR", "Impossible d'ouvrir les paramètres", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Check if Cobalt Flow is the default recognition service.
     * The system setting "voice_recognition_service" stores the current provider.
     */
    private fun isDefaultRecognitionService(): Boolean {
        return try {
            val currentService = Settings.Secure.getString(
                contentResolver,
                "voice_recognition_service"
            )
            currentService?.contains(packageName) == true
        } catch (e: Exception) {
            false
        }
    }
}
