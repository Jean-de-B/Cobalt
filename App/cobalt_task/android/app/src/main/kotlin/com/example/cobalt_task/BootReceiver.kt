package com.example.cobalt_task

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON") return

        Log.d("CobaltBoot", "BOOT_COMPLETED reçu — démarrage automatique Cobalt")

        // Stocker le flag pour que Flutter sache qu'on démarre depuis le boot
        context.getSharedPreferences("cobalt_launch", Context.MODE_PRIVATE)
            .edit().putBoolean("boot_autostart", true).apply()

        // Lancer MainActivity en arrière-plan pour déclencher l'init BLE
        // Fonctionne grâce à la permission SYSTEM_ALERT_WINDOW déjà accordée
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("launch_mode", "boot")
            }
            context.startActivity(launchIntent)
            Log.d("CobaltBoot", "MainActivity lancée au boot")
        } catch (e: Exception) {
            Log.w("CobaltBoot", "Impossible de lancer MainActivity: ${e.message}")
        }
    }
}
