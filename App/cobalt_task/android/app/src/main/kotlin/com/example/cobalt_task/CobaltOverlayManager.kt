package com.example.cobalt_task

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout

/**
 * Singleton gerant l'overlay vocal Cobalt.
 *
 * Affiche par-dessus toute app (y compris barres systeme) :
 * - Fond semi-transparent
 * - Halo lumineux reactif a la voix (VoiceRingView) derriere le logo
 * - Logo Cobalt detoure
 *
 * L'utilisateur tape n'importe ou pour dismiss.
 */
class CobaltOverlayManager private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "CobaltOverlay"

        @Volatile
        private var instance: CobaltOverlayManager? = null

        fun getInstance(context: Context): CobaltOverlayManager {
            return instance ?: synchronized(this) {
                instance ?: CobaltOverlayManager(context.applicationContext).also {
                    instance = it
                }
            }
        }
    }

    private var overlayView: View? = null
    private var windowManager: WindowManager? = null
    private var voiceRingView: VoiceRingView? = null
    private var onDismissCallback: (() -> Unit)? = null
    private var isShowing = false
    private val mainHandler = Handler(Looper.getMainLooper())

    fun show(onDismiss: () -> Unit) {
        if (isShowing) {
            Log.d(TAG, "Overlay deja visible - mise a jour du callback")
            onDismissCallback = onDismiss
            return
        }

        if (!Settings.canDrawOverlays(appContext)) {
            Log.e(TAG, "Permission SYSTEM_ALERT_WINDOW non accordee")
            return
        }

        onDismissCallback = onDismiss
        windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

        val root = buildOverlayView()
        overlayView = root

        // Recuperer la taille reelle de l'ecran (incluant barres systeme)
        val wm = windowManager!!
        var screenWidth: Int
        var screenHeight: Int
        var statusBarHeight = 0

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = wm.currentWindowMetrics
            val bounds = metrics.bounds
            screenWidth = bounds.width()
            screenHeight = bounds.height()
            // Ajouter la hauteur des barres systeme pour les depasser
            val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
            )
            statusBarHeight = insets.top
            screenHeight += insets.top + insets.bottom
        } else {
            val dm = appContext.resources.displayMetrics
            screenWidth = dm.widthPixels
            screenHeight = dm.heightPixels
        }

        val params = WindowManager.LayoutParams(
            screenWidth,
            screenHeight,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.LEFT
        params.x = 0
        params.y = -statusBarHeight

        // Permettre le dessin dans la zone du cutout (encoche/camera)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            params.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

        try {
            windowManager?.addView(root, params)
            isShowing = true

            root.alpha = 0f
            root.animate().alpha(1f).setDuration(200).start()

            Log.d(TAG, "Overlay affiche")
        } catch (e: Exception) {
            Log.e(TAG, "Erreur affichage overlay: ${e.message}")
        }
    }

    fun hide() {
        if (!isShowing) return

        val view = overlayView ?: return
        view.animate()
            .alpha(0f)
            .setDuration(150)
            .withEndAction {
                try {
                    voiceRingView?.cleanup()
                    windowManager?.removeView(view)
                } catch (e: Exception) {
                    Log.w(TAG, "Erreur suppression overlay: ${e.message}")
                }
                overlayView = null
                voiceRingView = null
                isShowing = false
                Log.d(TAG, "Overlay masque")
            }
            .start()
    }

    fun updateAmplitude(amplitude: Float) {
        voiceRingView?.updateAmplitude(amplitude)
    }

    fun isVisible(): Boolean = isShowing

    // =========================================================================
    // CONSTRUCTION DE LA VUE
    // =========================================================================

    private fun buildOverlayView(): FrameLayout {
        val density = appContext.resources.displayMetrics.density

        // Root : fond semi-transparent, capture le touch pour dismiss
        val root = FrameLayout(appContext).apply {
            setBackgroundColor(Color.parseColor("#80000000"))
            setOnTouchListener { _, event ->
                if (event.action == MotionEvent.ACTION_UP) {
                    Log.d(TAG, "Overlay tape - dismiss")
                    mainHandler.post {
                        onDismissCallback?.invoke()
                    }
                }
                true
            }
        }

        // Container central vertical
        val centerContainer = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        // Zone logo : FrameLayout pour superposer le halo derriere le logo
        val logoArea = FrameLayout(appContext)
        val logoSize = (100 * density).toInt()
        val ringSize = (190 * density).toInt() // halo plus grand que le logo

        // Halo lumineux reactif (derriere le logo)
        voiceRingView = VoiceRingView(appContext)
        val ringParams = FrameLayout.LayoutParams(ringSize, ringSize).apply {
            gravity = Gravity.CENTER
        }
        logoArea.addView(voiceRingView, ringParams)

        // Logo Cobalt detoure (par-dessus le halo)
        val logo = ImageView(appContext).apply {
            val logoRes = appContext.resources.getIdentifier(
                "cobalt_logo", "drawable", appContext.packageName
            )
            if (logoRes != 0) setImageResource(logoRes)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        val logoParams = FrameLayout.LayoutParams(logoSize, logoSize).apply {
            gravity = Gravity.CENTER
        }
        logoArea.addView(logo, logoParams)

        val logoAreaParams = LinearLayout.LayoutParams(ringSize, ringSize).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        }

        // Assemblage
        centerContainer.addView(logoArea, logoAreaParams)
        root.addView(centerContainer, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT
        ).apply { gravity = Gravity.CENTER })

        return root
    }
}
