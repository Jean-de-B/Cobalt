package com.example.cobalt_task

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.view.View

/**
 * Halo lumineux bleu qui pulse avec l'amplitude vocale.
 * Dessin leger : un seul cercle avec gradient radial.
 * Lerp a 60fps pour un rendu fluide sans ValueAnimator.
 */
class VoiceRingView(context: Context) : View(context) {

    companion object {
        private const val BASE_RADIUS_DP = 60f
        private const val MAX_EXTRA_DP = 35f
        private const val LERP_SPEED = 0.15f // vitesse d'interpolation (0-1, plus haut = plus reactif)
        private const val GLOW_COLOR = 0xFF2979FF.toInt()
    }

    private val density = context.resources.displayMetrics.density
    private val baseRadius = BASE_RADIUS_DP * density
    private val maxExtra = MAX_EXTRA_DP * density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    private var targetAmplitude = 0f
    private var currentAmplitude = 0f
    private var isActive = true

    init {
        setLayerType(LAYER_TYPE_HARDWARE, null)
    }

    fun updateAmplitude(amplitude: Float) {
        targetAmplitude = amplitude.coerceIn(0f, 1f)
        if (isActive) invalidate()
    }

    fun cleanup() {
        isActive = false
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = ((baseRadius + maxExtra) * 2).toInt() + 4
        setMeasuredDimension(size, size)
    }

    override fun onDraw(canvas: Canvas) {
        if (!isActive) return

        // Lerp vers la cible
        currentAmplitude += (targetAmplitude - currentAmplitude) * LERP_SPEED

        val cx = width / 2f
        val cy = height / 2f
        val radius = baseRadius + currentAmplitude * maxExtra

        // Gradient : bleu semi-transparent au centre → transparent au bord
        val alpha = (0.35f + currentAmplitude * 0.35f).coerceIn(0f, 0.7f)
        val centerColor = Color.argb((alpha * 255).toInt(), 41, 121, 255)
        val edgeColor = Color.argb(0, 41, 121, 255)

        paint.shader = RadialGradient(
            cx, cy, radius.coerceAtLeast(1f),
            intArrayOf(centerColor, centerColor, edgeColor),
            floatArrayOf(0f, 0.4f, 1f),
            Shader.TileMode.CLAMP
        )

        canvas.drawCircle(cx, cy, radius, paint)

        // Continuer a animer tant que l'ecart est visible
        if (Math.abs(targetAmplitude - currentAmplitude) > 0.005f) {
            invalidate()
        }
    }
}
