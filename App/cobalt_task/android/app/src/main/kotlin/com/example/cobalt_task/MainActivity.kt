package com.example.cobalt_task

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Activity
import android.app.PendingIntent
import android.app.SearchManager
import android.app.role.RoleManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.app.KeyguardManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Log
import android.view.KeyEvent
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val TAG = "CobaltMain"
    private val CHANNEL = "com.cobalt_task/media_keys"
    private val SMS_CHANNEL = "com.cobalt_task/sms"
    private val OVERLAY_CHANNEL = "com.cobalt_task/overlay_permission"
    private val DEVICE_STATE_CHANNEL = "com.cobalt_task/device_state"
    private val NOTIFICATION_CHANNEL = "com.cobalt_task/notification_listener"
    private val SPOTIFY_AUTH_CHANNEL = "com.cobalt_task/spotify_auth"
    private val ASSISTANT_CHANNEL = "com.cobalt_task/assistant"
    private val CUSTOM_NOTIF_CHANNEL = "com.cobalt_task/custom_notification"
    private val ASSISTANT_DIAG_CHANNEL = "com.cobalt_task/assistant_diagnostics"
    private val COBALT_OVERLAY_CHANNEL = "com.cobalt_task/cobalt_overlay"
    private val PAYMENT_CHANNEL = "com.cobalt_task/payment"
    private val MIC_RECORD_ACTION = "com.cobalt_task.MIC_RECORD"
    private val ASSIST_RECORD_ACTION = "com.cobalt_task.ASSIST_RECORD"
    private val REQUEST_ROLE_ASSISTANT = 42

    companion object {
        /** true quand FlutterEngine est configure et les MethodChannels sont prets. */
        @Volatile
        var isEngineReady = false
    }

    private var spotifyAuthChannel: MethodChannel? = null
    private var assistantChannel: MethodChannel? = null
    private var customNotifChannel: MethodChannel? = null
    private var assistantDiagChannel: MethodChannel? = null
    private var cobaltOverlayChannel: MethodChannel? = null
    private var fintectureChannel: MethodChannel? = null
    private var micButtonReceiver: BroadcastReceiver? = null
    private var notificationReceiver: BroadcastReceiver? = null
    private var notificationEventSink: EventChannel.EventSink? = null
    private var pendingRoleResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Canal permission overlay (SYSTEM_ALERT_WINDOW)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "requestOverlayPermission" -> {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Canal état du device (écran verrouillé)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_STATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isScreenLocked" -> {
                    val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    result.success(keyguardManager.isKeyguardLocked)
                }
                else -> result.notImplemented()
            }
        }

        // Canal NotificationListener (historique des messages entrants)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> {
                    val listeners = android.provider.Settings.Secure.getString(
                        contentResolver,
                        "enabled_notification_listeners"
                    ) ?: ""
                    result.success(listeners.contains(packageName))
                }
                "requestPermission" -> {
                    val intent = android.content.Intent(
                        android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS
                    )
                    intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                }
                "getIncomingHistory" -> {
                    val prefs = getSharedPreferences("cobalt_incoming_history", Context.MODE_PRIVATE)
                    val history = prefs.getString("history", "[]") ?: "[]"
                    result.success(history)
                }
                else -> result.notImplemented()
            }
        }

        // Canal SMS direct
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val phoneNumber = call.argument<String>("phoneNumber")
                    val message = call.argument<String>("message")

                    if (phoneNumber != null && message != null) {
                        sendSmsDirectly(phoneNumber, message, result)
                    } else {
                        result.error("INVALID_ARGUMENT", "phoneNumber and message are required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Canal Media Keys
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendMediaKey" -> {
                    val keyCode = call.argument<Int>("keyCode")
                    if (keyCode != null) {
                        val success = sendMediaKeyEvent(keyCode)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "keyCode is required", null)
                    }
                }
                "play" -> {
                    val success = sendMediaKeyEvent(KeyEvent.KEYCODE_MEDIA_PLAY)
                    result.success(success)
                }
                "pause" -> {
                    val success = sendMediaKeyEvent(KeyEvent.KEYCODE_MEDIA_PAUSE)
                    result.success(success)
                }
                "playPause" -> {
                    // Verifier si un appel est en cours via TelephonyManager
                    val callHandled = handleCallIfActive()
                    if (callHandled) {
                        result.success(true)
                    } else {
                        // Pas d'appel → media play/pause classique
                        val success = sendMediaKeyEvent(KeyEvent.KEYCODE_HEADSETHOOK)
                        result.success(success)
                    }
                }
                "next" -> {
                    val success = sendMediaKeyEvent(KeyEvent.KEYCODE_MEDIA_NEXT)
                    result.success(success)
                }
                "previous" -> {
                    val success = sendMediaKeyEvent(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                    result.success(success)
                }
                "stop" -> {
                    val success = sendMediaKeyEvent(KeyEvent.KEYCODE_MEDIA_STOP)
                    result.success(success)
                }
                "playSearch" -> {
                    val query = call.argument<String>("query") ?: ""
                    val app = call.argument<String>("app")
                    val success = playSearchMedia(query, app)
                    result.success(success)
                }
                "openSamsungNotes" -> {
                    val text = call.argument<String>("text") ?: ""
                    try {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                            setPackage("com.samsung.android.app.notes")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // Fallback : intent générique
                        try {
                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(Intent.createChooser(intent, "Enregistrer la note"))
                            result.success(true)
                        } catch (e2: Exception) {
                            result.success(false)
                        }
                    }
                }
                "isMusicActive" -> {
                    val isActive = isMusicPlaying()
                    result.success(isActive)
                }
                "volumeUp" -> {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0)
                    val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                    val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    result.success(mapOf("current" to current, "max" to max))
                }
                "volumeDown" -> {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0)
                    val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                    val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    result.success(mapOf("current" to current, "max" to max))
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Canal Spotify OAuth2 callback
        spotifyAuthChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPOTIFY_AUTH_CHANNEL)

        // Vérifier si l'app a été lancée par un deep link Spotify (cold start)
        intent?.data?.let { uri ->
            if (uri.scheme == "cobalttask" && uri.host == "spotify-callback") {
                val code = uri.getQueryParameter("code")
                val error = uri.getQueryParameter("error")
                if (code != null) {
                    spotifyAuthChannel?.invokeMethod("onAuthCode", mapOf("code" to code))
                } else if (error != null) {
                    spotifyAuthChannel?.invokeMethod("onAuthError", mapOf("error" to error))
                }
            }
        }

        // Canal Assistant (detection du mode de lancement ASSIST)
        assistantChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ASSISTANT_CHANNEL)
        assistantChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPendingAssist" -> {
                    val prefs = getSharedPreferences("cobalt_launch", Context.MODE_PRIVATE)
                    val pending = prefs.getBoolean("pending_assist", false)
                    if (pending) {
                        prefs.edit().remove("pending_assist").apply()
                    }
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        }

        // Verifier si l'app a ete lancee en mode assistant (ASSIST intent)
        intent?.getStringExtra("launch_mode")?.let { mode ->
            if (mode == "assist") {
                Log.d(TAG, "configureFlutterEngine: ASSIST launch via trampoline detected")
                val prefs = getSharedPreferences("cobalt_launch", Context.MODE_PRIVATE)
                prefs.edit().putBoolean("pending_assist", true).apply()
                assistantChannel?.invokeMethod("onAssistLaunch", mapOf(
                    "source" to (intent?.getStringExtra("assist_source") ?: "unknown")
                ))
            }
        }

        // Verifier ASSIST intent direct (Samsung peut envoyer directement)
        if (intent?.action == "android.intent.action.ASSIST" ||
            intent?.action == "android.intent.action.VOICE_COMMAND") {
            Log.d(TAG, "configureFlutterEngine: DIRECT ASSIST intent at cold start! action=${intent?.action}")
            val prefs = getSharedPreferences("cobalt_launch", Context.MODE_PRIVATE)
            prefs.edit().putBoolean("pending_assist", true).apply()
            assistantChannel?.invokeMethod("onAssistLaunch", mapOf(
                "source" to (intent?.action ?: "direct_assist_cold")
            ))
        }

        // Canal notification custom (bouton micro natif Android)
        customNotifChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CUSTOM_NOTIF_CHANNEL)
        customNotifChannel?.setMethodCallHandler { call, result ->
            Log.d(TAG, "customNotifChannel: method=${call.method}")
            when (call.method) {
                "showMicNotification" -> {
                    val title = call.argument<String>("title") ?: "Cobalt Task"
                    val text = call.argument<String>("text") ?: ""
                    val isRecording = call.argument<Boolean>("isRecording") ?: false
                    showMicNotification(title, text, isRecording)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Canal diagnostics assistant (verifier config + ouvrir parametres Samsung)
        assistantDiagChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ASSISTANT_DIAG_CHANNEL)
        assistantDiagChannel?.setMethodCallHandler { call, result ->
            Log.d(TAG, "assistantDiag: method=${call.method}")
            when (call.method) {
                "getAssistantStatus" -> {
                    result.success(getAssistantDiagnostics())
                }
                "requestAssistantRole" -> {
                    requestAssistantRole(result)
                }
                "openDefaultAssistantSettings" -> {
                    openDefaultAssistantSettings()
                    result.success(true)
                }
                "openSideKeySettings" -> {
                    openSideKeySettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Canal overlay vocal Cobalt (bulle par-dessus toute app)
        cobaltOverlayChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COBALT_OVERLAY_CHANNEL)
        cobaltOverlayChannel?.setMethodCallHandler { call, result ->
            val overlayManager = CobaltOverlayManager.getInstance(applicationContext)
            when (call.method) {
                "showOverlay" -> {
                    Log.d(TAG, "showOverlay called")
                    overlayManager.show {
                        cobaltOverlayChannel?.invokeMethod("onOverlayDismissed", null)
                    }
                    result.success(true)
                }
                "hideOverlay" -> {
                    Log.d(TAG, "hideOverlay called")
                    overlayManager.hide()
                    result.success(true)
                }
                "updateAmplitude" -> {
                    val amp = (call.arguments as? Double)?.toFloat() ?: 0f
                    overlayManager.updateAmplitude(amp)
                    result.success(true)
                }
"isOverlayVisible" -> {
                    result.success(overlayManager.isVisible())
                }
                else -> result.notImplemented()
            }
        }

        // Canal payment (lancement d'apps de paiement)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PAYMENT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "launchPackage" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.error("INVALID_ARG", "packageName requis", null)
                        return@setMethodCallHandler
                    }
                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                    if (launchIntent != null) {
                        launchIntent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launchIntent)
                        Log.d(TAG, "Package $packageName lancé via getLaunchIntentForPackage")
                        result.success(true)
                    } else {
                        Log.d(TAG, "Package $packageName: pas de launch intent trouvé")
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Canal Fintecture (deep link callback)
        fintectureChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.cobalt_task/fintecture")

        // EventChannel pour streamer les notifications en temps réel vers Flutter
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.cobalt_task/notification_stream")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    notificationEventSink = events
                    Log.d(TAG, "Notification EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    notificationEventSink = null
                    Log.d(TAG, "Notification EventChannel: onCancel")
                }
            })

        // BroadcastReceiver pour relayer les notifications du NotificationListenerService
        registerNotificationReceiver()

        // BroadcastReceiver pour le bouton micro de la notification
        // Utilise getBroadcast() au lieu de getActivity() → pas d'ouverture de l'app
        registerMicButtonReceiver()

        isEngineReady = true
        Log.d(TAG, "configureFlutterEngine: all channels configured (isEngineReady=true)")
    }

    /**
     * Enregistre un BroadcastReceiver pour le bouton micro de la notification.
     * Le broadcast est envoye par le PendingIntent de la notification action,
     * sans ouvrir l'app au premier plan.
     */
    private fun registerMicButtonReceiver() {
        if (micButtonReceiver != null) return // Deja enregistre

        micButtonReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                Log.d(TAG, "MicButtonReceiver: broadcast received! action=${intent?.action}")
                when (intent?.action) {
                    MIC_RECORD_ACTION -> {
                        customNotifChannel?.invokeMethod("onMicButtonPressed", null)
                    }
                    ASSIST_RECORD_ACTION -> {
                        Log.d(TAG, "MicButtonReceiver: ASSIST_RECORD → onAssistRecordPressed")
                        customNotifChannel?.invokeMethod("onAssistRecordPressed", null)
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(MIC_RECORD_ACTION)
            addAction(ASSIST_RECORD_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(micButtonReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(micButtonReceiver, filter)
        }
        Log.d(TAG, "MicButtonReceiver registered (MIC_RECORD + ASSIST_RECORD)")
    }

    private fun registerNotificationReceiver() {
        if (notificationReceiver != null) return

        notificationReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != CobaltNotificationListener.ACTION_NEW_MESSAGE) return

                val data = hashMapOf<String, Any?>(
                    "senderName" to intent.getStringExtra(CobaltNotificationListener.EXTRA_SENDER),
                    "messagePreview" to intent.getStringExtra(CobaltNotificationListener.EXTRA_PREVIEW),
                    "packageName" to intent.getStringExtra(CobaltNotificationListener.EXTRA_PACKAGE),
                    "timestamp" to intent.getLongExtra(CobaltNotificationListener.EXTRA_TIMESTAMP, 0L),
                )

                Handler(Looper.getMainLooper()).post {
                    notificationEventSink?.success(data)
                }
            }
        }

        val filter = IntentFilter(CobaltNotificationListener.ACTION_NEW_MESSAGE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(notificationReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(notificationReceiver, filter)
        }
        Log.d(TAG, "NotificationReceiver registered")
    }

    override fun onDestroy() {
        isEngineReady = false
        micButtonReceiver?.let {
            try {
                unregisterReceiver(it)
                Log.d(TAG, "MicButtonReceiver unregistered")
            } catch (e: Exception) {
                Log.w(TAG, "Error unregistering receiver: ${e.message}")
            }
        }
        micButtonReceiver = null
        notificationReceiver?.let {
            try {
                unregisterReceiver(it)
                Log.d(TAG, "NotificationReceiver unregistered")
            } catch (e: Exception) {
                Log.w(TAG, "Error unregistering receiver: ${e.message}")
            }
        }
        notificationReceiver = null
        notificationEventSink = null
        super.onDestroy()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // Intercepter le bouton assistant des casques BT
        if (keyCode == KeyEvent.KEYCODE_VOICE_ASSIST) {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val headsetEnabled = prefs.getBoolean("flutter.headset_assistant", false)
            if (headsetEnabled) {
                Log.d(TAG, "Headset VOICE_ASSIST → lancement assistant Cobalt")
                customNotifChannel?.invokeMethod("onAssistRecordPressed", null)
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent: action=${intent.action}, extras=${intent.extras?.keySet()}")

        // Bouton micro de la notification custom
        if (intent.action == "com.cobalt_task.MIC_RECORD") {
            Log.d(TAG, "onNewIntent: MIC_RECORD action detected!")
            customNotifChannel?.invokeMethod("onMicButtonPressed", null)
            return
        }

        // ASSIST intent direct (Samsung peut envoyer directement a MainActivity)
        if (intent.action == "android.intent.action.ASSIST" ||
            intent.action == "android.intent.action.VOICE_COMMAND") {
            Log.d(TAG, "onNewIntent: DIRECT ASSIST intent detected! action=${intent.action}")
            assistantChannel?.invokeMethod("onAssistLaunch", mapOf(
                "source" to (intent.action ?: "direct_assist")
            ))
            return
        }

        // Deep links
        intent.data?.let { uri ->
            if (uri.scheme == "cobalttask" && uri.host == "spotify-callback") {
                val code = uri.getQueryParameter("code")
                val error = uri.getQueryParameter("error")
                if (code != null) {
                    spotifyAuthChannel?.invokeMethod("onAuthCode", mapOf("code" to code))
                } else if (error != null) {
                    spotifyAuthChannel?.invokeMethod("onAuthError", mapOf("error" to error))
                }
            }
            // Fintecture payment callback
            if (uri.scheme == "cobalt" && uri.host == "fintecture") {
                Log.d(TAG, "Fintecture callback: $uri")
                fintectureChannel?.invokeMethod("onPaymentCallback", mapOf(
                    "state" to (uri.getQueryParameter("state") ?: ""),
                    "status" to (uri.getQueryParameter("status") ?: "")
                ))
            }
        }

        // Lancement en mode assistant (via AssistantActivity trampoline)
        intent.getStringExtra("launch_mode")?.let { mode ->
            when (mode) {
                "assist" -> {
                    Log.d(TAG, "onNewIntent: ASSIST via trampoline, source=${intent.getStringExtra("assist_source")}")
                    assistantChannel?.invokeMethod("onAssistLaunch", mapOf(
                        "source" to (intent.getStringExtra("assist_source") ?: "unknown")
                    ))
                }
            }
        }
    }

    // =========================================================================
    // NOTIFICATION CUSTOM AVEC BOUTON MICRO
    // =========================================================================

    /**
     * Cree/met a jour une notification avec un bouton micro natif Android.
     * Remplace la notification du plugin flutter_foreground_task (meme ID 1000)
     * pour garantir l'affichage du bouton sur Samsung One UI.
     */
    private fun showMicNotification(title: String, text: String, isRecording: Boolean) {
        Log.d(TAG, "showMicNotification: title=$title, text=$text, isRecording=$isRecording")

        val channelId = "cobalt_foreground_v2"
        val notificationId = 1000

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // S'assurer que le canal existe avec la bonne importance
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existingChannel = nm.getNotificationChannel(channelId)
            if (existingChannel == null) {
                Log.d(TAG, "showMicNotification: creating notification channel $channelId")
                val channel = NotificationChannel(
                    channelId,
                    "Cobalt Task Service",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Service d'écoute Cobalt Task"
                    enableVibration(false)
                    setSound(null, null)
                }
                nm.createNotificationChannel(channel)
            } else {
                Log.d(TAG, "showMicNotification: channel exists, importance=${existingChannel.importance}")
            }
        }

        // PendingIntent pour ouvrir l'app au tap sur la notification
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // PendingIntent pour le bouton micro (broadcast → BroadcastReceiver, PAS d'ouverture app)
        val micIntent = PendingIntent.getBroadcast(
            this, 100,
            Intent(MIC_RECORD_ACTION).apply {
                setPackage(packageName)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Recuperer l'icone de l'app pour la notification
        val iconResId = resources.getIdentifier("ic_notification", "drawable", packageName)
        val smallIcon = if (iconResId != 0) iconResId else android.R.drawable.ic_btn_speak_now

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val builder = Notification.Builder(this, channelId)
                .setSmallIcon(smallIcon)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true) // Non-dismissable
                .setContentIntent(contentIntent)
                .setShowWhen(false)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }

            // Bouton micro avec icone explicite (garanti visible sur Samsung)
            val micIconRes = if (isRecording) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_btn_speak_now
            }
            val micLabel = if (isRecording) "⏹ Arrêter" else "🎤 Enregistrer"

            val micAction = Notification.Action.Builder(
                Icon.createWithResource(this, micIconRes),
                micLabel,
                micIntent
            ).build()
            builder.addAction(micAction)

            // MediaStyle : affiche le bouton micro dans la vue COMPACTE (repliée)
            // Sans ça, le bouton n'apparait que quand on déplie la notification
            val mediaStyle = Notification.MediaStyle()
                .setShowActionsInCompactView(0) // index 0 = bouton micro
            builder.setStyle(mediaStyle)

            Log.d(TAG, "showMicNotification: posting notification id=$notificationId with mic button (MediaStyle compact)")
            nm.notify(notificationId, builder.build())
        } else {
            Log.d(TAG, "showMicNotification: pre-O device, skipping custom notification")
        }
    }

    // =========================================================================
    // DIAGNOSTICS ASSISTANT VOCAL
    // =========================================================================

    /**
     * Retourne un Map avec l'etat complet de la configuration assistant.
     * Permet a Flutter d'afficher un guide de configuration a l'utilisateur.
     */
    private fun getAssistantDiagnostics(): Map<String, Any> {
        val diag = mutableMapOf<String, Any>()

        // Info device
        diag["manufacturer"] = Build.MANUFACTURER
        diag["model"] = Build.MODEL
        diag["sdk"] = Build.VERSION.SDK_INT
        diag["isSamsung"] = Build.MANUFACTURER.equals("samsung", ignoreCase = true)

        // Verifier si Cobalt detient le role ASSISTANT (API 29+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val roleManager = getSystemService(Context.ROLE_SERVICE) as RoleManager
                val isAssistant = roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)
                diag["isRoleAssistantHeld"] = isAssistant
                diag["isRoleAvailable"] = roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)
                Log.d(TAG, "DIAG: ROLE_ASSISTANT held=$isAssistant")
            } catch (e: Exception) {
                diag["isRoleAssistantHeld"] = false
                diag["roleError"] = e.message ?: "unknown"
                Log.e(TAG, "DIAG: Error checking role: ${e.message}")
            }
        } else {
            diag["isRoleAssistantHeld"] = false
            diag["roleNote"] = "RoleManager requires API 29+"
        }

        // Verifier le service assistant actif via Settings.Secure
        try {
            val activeAssistant = Settings.Secure.getString(
                contentResolver, "assistant"
            )
            diag["currentAssistant"] = activeAssistant ?: "none"
            diag["isCobaltActiveAssistant"] = activeAssistant?.contains("cobalt_task") == true
            Log.d(TAG, "DIAG: current assistant=$activeAssistant")
        } catch (e: Exception) {
            diag["currentAssistant"] = "error: ${e.message}"
        }

        // Verifier le VoiceInteractionService actif
        try {
            val voiceService = Settings.Secure.getString(
                contentResolver, "voice_interaction_service"
            )
            diag["currentVoiceService"] = voiceService ?: "none"
            diag["isCobaltVoiceService"] = voiceService?.contains("cobalt_task") == true
            Log.d(TAG, "DIAG: voice_interaction_service=$voiceService")
        } catch (e: Exception) {
            diag["currentVoiceService"] = "error: ${e.message}"
        }

        // Verifier l'ASSIST activity configuree
        try {
            val assistApp = Settings.Secure.getString(
                contentResolver, "assist_structure"
            )
            diag["assistStructure"] = assistApp ?: "none"
        } catch (e: Exception) {
            diag["assistStructure"] = "error"
        }

        Log.d(TAG, "DIAG: full diagnostics = $diag")
        return diag
    }

    /**
     * Demande le role ASSISTANT via RoleManager (API 29+).
     * Ouvre un dialog systeme pour que l'utilisateur confirme.
     */
    private fun requestAssistantRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val roleManager = getSystemService(Context.ROLE_SERVICE) as RoleManager
                if (roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
                    if (roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
                        Log.d(TAG, "ROLE_ASSISTANT already held")
                        result.success(mapOf("status" to "already_held"))
                    } else {
                        pendingRoleResult = result
                        val intent = roleManager.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT)
                        startActivityForResult(intent, REQUEST_ROLE_ASSISTANT)
                        Log.d(TAG, "Requesting ROLE_ASSISTANT via RoleManager")
                    }
                } else {
                    Log.w(TAG, "ROLE_ASSISTANT not available on this device")
                    result.success(mapOf("status" to "not_available"))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error requesting role: ${e.message}", e)
                result.success(mapOf("status" to "error", "message" to (e.message ?: "unknown")))
            }
        } else {
            // Pre-Q: ouvrir les parametres manuels
            openDefaultAssistantSettings()
            result.success(mapOf("status" to "manual_settings_opened"))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_ROLE_ASSISTANT) {
            val granted = resultCode == RESULT_OK
            Log.d(TAG, "ROLE_ASSISTANT result: granted=$granted")
            pendingRoleResult?.success(mapOf(
                "status" to if (granted) "granted" else "denied"
            ))
            pendingRoleResult = null
        }
    }

    /**
     * Ouvre la page Parametres > Apps par defaut > Assistant numerique
     */
    private fun openDefaultAssistantSettings() {
        try {
            // Essayer d'abord la page specifique "default assistant"
            val intent = Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            Log.d(TAG, "Opened ACTION_VOICE_INPUT_SETTINGS")
        } catch (e: Exception) {
            Log.w(TAG, "ACTION_VOICE_INPUT_SETTINGS failed, trying MANAGE_DEFAULT_APPS_SETTINGS")
            try {
                val intent = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "Could not open default apps settings: ${e2.message}")
            }
        }
    }

    /**
     * Ouvre la page Samsung Parametres > Fonctions avancees (pour Side Key)
     */
    private fun openSideKeySettings() {
        try {
            // Samsung-specific: Advanced Features
            val intent = Intent("android.settings.ADVANCED_FEATURES_SETTINGS")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            Log.d(TAG, "Opened Samsung Advanced Features")
        } catch (e: Exception) {
            Log.w(TAG, "Samsung Advanced Features not found, trying general settings")
            try {
                // Fallback: ouvrir les parametres generaux
                val intent = Intent(Settings.ACTION_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "Could not open settings: ${e2.message}")
            }
        }
    }

    // =========================================================================
    // CONTROLE D'APPELS VIA TELECOMMANAGER (Samsung compatible)
    // =========================================================================

    /**
     * Verifie si un appel est actif (sonnerie ou en cours) et agit en consequence.
     * - Sonnerie (RINGING) → decrocher via TelecomManager.acceptRingingCall()
     * - En cours (OFFHOOK) → raccrocher via TelecomManager.endCall()
     * Retourne true si un appel a ete gere, false sinon (= mode media).
     */
    @Suppress("DEPRECATION")
    private fun handleCallIfActive(): Boolean {
        try {
            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            val callState = telephonyManager.callState

            Log.d(TAG, "handleCallIfActive: callState=$callState (0=IDLE, 1=RINGING, 2=OFFHOOK)")

            when (callState) {
                TelephonyManager.CALL_STATE_RINGING -> {
                    // Appel entrant → decrocher
                    Log.d(TAG, "RINGING → acceptRingingCall via TelecomManager")
                    val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        telecom.acceptRingingCall()
                        return true
                    }
                }
                TelephonyManager.CALL_STATE_OFFHOOK -> {
                    // En communication → raccrocher
                    Log.d(TAG, "OFFHOOK → endCall via TelecomManager")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                        telecom.endCall()
                        return true
                    }
                }
                // CALL_STATE_IDLE → pas d'appel, mode media
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "handleCallIfActive: permission manquante: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "handleCallIfActive: erreur: ${e.message}")
        }

        return false
    }

    private fun sendMediaKeyEvent(keyCode: Int): Boolean {
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val eventTime = SystemClock.uptimeMillis()

            // Envoyer KEY_DOWN puis KEY_UP
            val downEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_DOWN, keyCode, 0)
            audioManager.dispatchMediaKeyEvent(downEvent)

            val upEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_UP, keyCode, 0)
            audioManager.dispatchMediaKeyEvent(upEvent)

            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    /**
     * Vérifie si de la musique est actuellement en cours de lecture
     */
    private fun isMusicPlaying(): Boolean {
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.isMusicActive
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    /**
     * Lance une recherche musicale et joue automatiquement
     * Spotify ne supporte pas l'auto-play via intent standard
     */
    private fun playSearchMedia(query: String, app: String?): Boolean {
        return try {
            val packageName = app?.let { getMediaAppPackage(it) }
            var intentSent = false

            // ACTION_MEDIA_PLAY_FROM_SEARCH avec les bons extras
            val intent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
                putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/audio")
                putExtra(SearchManager.QUERY, query)
                putExtra(MediaStore.EXTRA_MEDIA_TITLE, query)
                putExtra(MediaStore.EXTRA_MEDIA_ARTIST, query)
                putExtra("query", query)

                if (packageName != null) {
                    setPackage(packageName)
                }

                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            // Essayer avec le package spécifique
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                intentSent = true
            } else {
                // Essayer sans package spécifique
                intent.setPackage(null)
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    intentSent = true
                }
            }

            // Si l'intent n'a pas fonctionné, ouvrir l'app directement
            if (!intentSent && packageName != null) {
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                    intentSent = true
                }
            }

            // Envoyer PLAY directement à l'app via ACTION_MEDIA_BUTTON
            if (intentSent && packageName != null) {
                android.os.Handler(mainLooper).postDelayed({
                    sendMediaButtonToApp(packageName, KeyEvent.KEYCODE_MEDIA_PLAY)
                }, 2000)

                android.os.Handler(mainLooper).postDelayed({
                    sendMediaButtonToApp(packageName, KeyEvent.KEYCODE_MEDIA_PLAY)
                }, 3000)

                // Fallback: aussi via AudioManager
                android.os.Handler(mainLooper).postDelayed({
                    sendMediaKeyEvent(KeyEvent.KEYCODE_MEDIA_PLAY)
                }, 3500)
            }

            intentSent
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    /**
     * Envoie un bouton média directement à une app spécifique via broadcast
     */
    private fun sendMediaButtonToApp(packageName: String, keyCode: Int) {
        try {
            val eventTime = SystemClock.uptimeMillis()

            // Envoyer KEY_DOWN
            val downIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                setPackage(packageName)
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(eventTime, eventTime, KeyEvent.ACTION_DOWN, keyCode, 0))
            }
            sendBroadcast(downIntent)

            // Envoyer KEY_UP
            val upIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                setPackage(packageName)
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(eventTime, eventTime, KeyEvent.ACTION_UP, keyCode, 0))
            }
            sendBroadcast(upIntent)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Retourne le package name d'une app média connue
     */
    private fun getMediaAppPackage(appName: String): String? {
        // Si c'est déjà un package name (contient un point), le retourner tel quel
        if (appName.contains('.')) return appName

        return when (appName.lowercase()) {
            "spotify" -> "com.spotify.music"
            "youtube_music", "youtubemusic", "youtube music" -> "com.google.android.apps.youtube.music"
            "deezer" -> "deezer.android.app"
            "amazon_music", "amazonmusic", "amazon music" -> "com.amazon.mp3"
            "apple_music", "applemusic", "apple music" -> "com.apple.android.music"
            "soundcloud" -> "com.soundcloud.android"
            "tidal" -> "com.aspiro.tidal"
            "pandora" -> "com.pandora.android"
            else -> null
        }
    }

    // =========================================================================
    // SMS DIRECT (sans UI)
    // =========================================================================

    /**
     * Envoie un SMS directement sans ouvrir l'application Messages.
     * Nécessite la permission SEND_SMS.
     *
     * Le résultat est renvoyé à Flutter via [result] une fois que l'OS a
     * confirmé (ou rejeté) l'envoi grâce au sentIntent / BroadcastReceiver.
     * Cela évite le faux-positif de l'ancienne implémentation fire-and-forget.
     */
    private fun sendSmsDirectly(phoneNumber: String, message: String, result: MethodChannel.Result) {
        try {
            // Obtenir le SmsManager adapté au SIM par défaut (API 31+ / dual-SIM)
            @Suppress("DEPRECATION")
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                applicationContext.getSystemService(SmsManager::class.java)
            } else {
                SmsManager.getDefault()
            }

            // Action unique pour éviter les collisions entre envois simultanés
            val sentAction = "com.cobalt_task.SMS_SENT_${System.currentTimeMillis()}"

            val sentIntent = PendingIntent.getBroadcast(
                this, 0,
                Intent(sentAction),
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
            )

            // Receiver one-shot : l'OS nous donne le vrai résultat réseau
            // AtomicBoolean pour éviter que le timeout ET le receiver appellent
            // result.success() en même temps
            val responded = AtomicBoolean(false)

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (!responded.compareAndSet(false, true)) return
                    try { unregisterReceiver(this) } catch (_: Exception) {}
                    val success = resultCode == Activity.RESULT_OK
                    if (success) {
                        Log.d("CobaltSMS", "SMS confirmé par l'OS → $phoneNumber")
                    } else {
                        Log.e("CobaltSMS", "SMS rejeté par l'OS (code $resultCode) → $phoneNumber")
                    }
                    result.success(success)
                }
            }

            // RECEIVER_EXPORTED requis : le callback est envoyé par le service téléphonie
            // (processus système séparé) — NOT_EXPORTED l'empêche de livrer le broadcast.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, IntentFilter(sentAction), RECEIVER_EXPORTED)
            } else {
                registerReceiver(receiver, IntentFilter(sentAction))
            }

            // Timeout de sécurité : si le broadcast ne revient pas dans 10s
            // (SIM absent, réseau indisponible, OS qui oublie le PendingIntent),
            // on désenregistre le receiver et on retourne true (SMS soumis à l'OS).
            Handler(Looper.getMainLooper()).postDelayed({
                if (!responded.compareAndSet(false, true)) return@postDelayed
                try { unregisterReceiver(receiver) } catch (_: Exception) {}
                Log.w("CobaltSMS", "Timeout sentIntent — SMS supposé envoyé à $phoneNumber")
                result.success(true)
            }, 10_000L)

            // Envoi — long message : découpage automatique
            if (message.length > 160) {
                val parts = smsManager.divideMessage(message)
                val sentIntents = ArrayList<PendingIntent?>().apply {
                    add(sentIntent) // callback sur la première partie suffit
                    repeat(parts.size - 1) { add(null) }
                }
                smsManager.sendMultipartTextMessage(phoneNumber, null, parts, sentIntents, null)
            } else {
                smsManager.sendTextMessage(phoneNumber, null, message, sentIntent, null)
            }

            Log.d("CobaltSMS", "SMS soumis au SmsManager → $phoneNumber")

        } catch (e: Exception) {
            Log.e("CobaltSMS", "Erreur envoi SMS: ${e.message}")
            e.printStackTrace()
            result.success(false)
        }
    }
}
