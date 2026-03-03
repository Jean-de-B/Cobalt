package com.example.cobalt_task

import android.app.assist.AssistContent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.util.Log

/**
 * Cree des sessions d'interaction vocale quand le systeme le demande.
 * Delegue immediatement a AssistantActivity pour le traitement Flutter.
 */
class CobaltVoiceInteractionSessionService : VoiceInteractionSessionService() {

    companion object {
        private const val TAG = "CobaltSessionService"
    }

    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        Log.d(TAG, "New voice interaction session requested")
        return CobaltVoiceInteractionSession(this)
    }
}

/**
 * Session minimale qui lance AssistantActivity.
 * La session elle-meme ne fait pas de traitement audio.
 *
 * Utilise startAssistantActivity() (API 29+) au lieu de ctx.startActivity()
 * pour eviter le blocage Samsung One UI sur les lancements d'activite
 * depuis un contexte service.
 */
class CobaltVoiceInteractionSession(
    private val ctx: Context
) : VoiceInteractionSession(ctx) {

    companion object {
        private const val TAG = "CobaltVoiceSession"
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Log.d(TAG, "onShow - launching AssistantActivity (flags=$showFlags)")
        launchAssistantActivity()
    }

    @Suppress("DEPRECATION")
    override fun onHandleAssist(data: Bundle?, structure: AssistStructure?, content: AssistContent?) {
        super.onHandleAssist(data, structure, content)
        Log.d(TAG, "onHandleAssist called")
        // Le lancement est fait dans onShow() qui est appele en premier.
        // onHandleAssist sert de fallback si onShow n'a pas ete appele.
    }

    private fun launchAssistantActivity() {
        val intent = Intent(ctx, AssistantActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("source", "voice_interaction_session")
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // API 29+ : methode dediee pour lancer depuis une VoiceInteractionSession
                // Contourne les restrictions Samsung One UI sur startActivity depuis un service
                startAssistantActivity(intent)
                Log.d(TAG, "startAssistantActivity() OK")
            } else {
                ctx.startActivity(intent)
                Log.d(TAG, "ctx.startActivity() OK (pre-Q)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Erreur lancement AssistantActivity: ${e.message}", e)
            // Fallback: essayer ctx.startActivity si startAssistantActivity a echoue
            try {
                ctx.startActivity(intent)
                Log.d(TAG, "Fallback ctx.startActivity() OK")
            } catch (e2: Exception) {
                Log.e(TAG, "Fallback aussi echoue: ${e2.message}", e2)
            }
        }

        finish()
    }
}
