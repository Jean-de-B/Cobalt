package com.example.cobalt_task

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager

/**
 * Activite transparente qui intercepte le intent ASSIST (assistant vocal par defaut).
 * Lance immediatement MainActivity en mode "assist" et se ferme.
 *
 * Gere l'affichage au-dessus de l'ecran de verrouillage pour permettre
 * l'activation vocale depuis le lock screen.
 *
 * Declenchee par:
 *   - Appui long bouton Home (si Cobalt = assistant par defaut)
 *   - Appui long bouton Power/Side Key (Samsung: Parametres > Fonctions avancees > Touche laterale > Maintien > Assistant numerique)
 *   - VoiceInteractionSession (via CobaltVoiceInteractionSessionService)
 */
class AssistantActivity : Activity() {

    companion object {
        private const val TAG = "CobaltAssistant"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "========================================")
        Log.d(TAG, "AssistantActivity.onCreate()")
        Log.d(TAG, "  intent action: ${intent?.action}")
        Log.d(TAG, "  intent extras: ${intent?.extras?.keySet()?.joinToString()}")
        Log.d(TAG, "  intent source extra: ${intent?.getStringExtra("source")}")
        Log.d(TAG, "  device: ${Build.MANUFACTURER} ${Build.MODEL}")
        Log.d(TAG, "  SDK: ${Build.VERSION.SDK_INT}")
        Log.d(TAG, "========================================")

        // Permettre l'affichage au-dessus de l'ecran de verrouillage
        // PAS de requestDismissKeyguard : l'overlay fonctionne par-dessus le lock screen
        // sans demander le code PIN/biometrie
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        // MODE ASSISTANT : overlay bleu + pipeline IA
        // Afficher l'overlay immediatement pour feedback visuel instantane
        // (Flutter gerera l'enregistrement une fois le MethodChannel pret)
        try {
            if (Settings.canDrawOverlays(this)) {
                val overlayMgr = CobaltOverlayManager.getInstance(applicationContext)
                overlayMgr.show {
                    Log.d(TAG, "  Overlay dismiss avant que Flutter soit pret - masquage")
                    overlayMgr.hide()
                }
                Log.d(TAG, "  Overlay affiche immediatement depuis AssistantActivity")
            }
        } catch (e: Exception) {
            Log.w(TAG, "  Impossible d'afficher l'overlay: ${e.message}")
        }

        // Stocker le flag pending_assist dans tous les cas (filet de securite cold start)
        val prefs = getSharedPreferences("cobalt_launch", Context.MODE_PRIVATE)
        prefs.edit().putBoolean("pending_assist", true).apply()

        if (MainActivity.isEngineReady) {
            // WARM START: Flutter tourne deja, envoyer un broadcast sans ouvrir l'app
            // Le BroadcastReceiver dans MainActivity transmettra via MethodChannel
            val assistIntent = Intent("com.cobalt_task.ASSIST_RECORD").apply {
                setPackage(packageName)
            }
            sendBroadcast(assistIntent)
            Log.d(TAG, "  ASSIST broadcast envoye (warm start, pas de startActivity)")
        } else {
            // COLD START: FlutterEngine pas pret, il faut lancer MainActivity
            // Le flag pending_assist sera verifie quand Flutter demarre
            val mainIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra("launch_mode", "assist")
                putExtra("assist_source", intent?.action ?: "unknown")
            }
            try {
                startActivity(mainIntent)
                Log.d(TAG, "  MainActivity lancee (cold start)")
            } catch (e: Exception) {
                Log.e(TAG, "  ERREUR lancement MainActivity: ${e.message}", e)
            }
        }

        finish()
        Log.d(TAG, "  AssistantActivity finished")
    }
}
