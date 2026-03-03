package com.example.cobalt_task

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator

/**
 * Vue plein ecran qui dessine un halo bleu anime sur les 4 bords.
 * Effet "edge lighting" qui pulse pendant l'ecoute.
 */
class EdgeGlowView(context: Context) : View(context) {

    companion object {
        private const val GLOW_WIDTH_DP = 40f
        private const val MIN_ALPHA = 0.3f
        private const val MAX_ALPHA = 0.9f
        private const val PULSE_DURATION_MS = 1200L
        private const val GLOW_COLOR = 0xFF2979FF.toInt() // Bleu Cobalt
    }

    private val density = context.resources.displayMetrics.density
    private val glowWidth = GLOW_WIDTH_DP * density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var currentAlpha = MAX_ALPHA
    private var animator: ValueAnimator? = null

    init {
        // Vue transparente, ne bloque pas les touches
        setLayerType(LAYER_TYPE_HARDWARE, null)
        startPulse()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        val gw = glowWidth

        val alphaInt = (currentAlpha * 255).toInt().coerceIn(0, 255)
        val colorWithAlpha = (alphaInt shl 24) or (GLOW_COLOR and 0x00FFFFFF)
        val transparent = 0x00000000

        // Bord haut
        paint.shader = LinearGradient(0f, 0f, 0f, gw, colorWithAlpha, transparent, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w, gw, paint)

        // Bord bas
        paint.shader = LinearGradient(0f, h, 0f, h - gw, colorWithAlpha, transparent, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, h - gw, w, h, paint)

        // Bord gauche
        paint.shader = LinearGradient(0f, 0f, gw, 0f, colorWithAlpha, transparent, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, gw, h, paint)

        // Bord droit
        paint.shader = LinearGradient(w, 0f, w - gw, 0f, colorWithAlpha, transparent, Shader.TileMode.CLAMP)
        canvas.drawRect(w - gw, 0f, w, h, paint)
    }

    private fun startPulse() {
        animator?.cancel()
        animator = ValueAnimator.ofFloat(MIN_ALPHA, MAX_ALPHA).apply {
            duration = PULSE_DURATION_MS
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { anim ->
                currentAlpha = anim.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    fun cleanup() {
        animator?.cancel()
        animator = null
    }
}
