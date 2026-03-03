package com.example.cobalt_task

import android.os.Build
import android.service.voice.VoiceInteractionService
import android.util.Log

/**
 * Service d'interaction vocale pour apparaitre comme Assistant Digital
 * dans Parametres > Apps > Apps par defaut > App d'assistance numerique.
 *
 * Ce service est minimal - son existence suffit pour l'enregistrement systeme.
 * Le travail reel est fait par:
 *   1. CobaltVoiceInteractionSessionService (cree les sessions)
 *   2. CobaltVoiceInteractionSession (lance AssistantActivity)
 *   3. AssistantActivity (redirige vers MainActivity en mode assist)
 */
class CobaltVoiceInteractionService : VoiceInteractionService() {

    companion object {
        private const val TAG = "CobaltVoiceService"
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate() - service cree")
    }

    override fun onReady() {
        super.onReady()
        Log.d(TAG, "========================================")
        Log.d(TAG, "VoiceInteractionService READY")
        Log.d(TAG, "  device: ${Build.MANUFACTURER} ${Build.MODEL}")
        Log.d(TAG, "  SDK: ${Build.VERSION.SDK_INT}")
        Log.d(TAG, "  Cobalt est maintenant l'assistant par defaut")
        Log.d(TAG, "========================================")
    }

    override fun onShutdown() {
        Log.d(TAG, "onShutdown() - service arrete")
        super.onShutdown()
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy()")
        super.onDestroy()
    }
}
