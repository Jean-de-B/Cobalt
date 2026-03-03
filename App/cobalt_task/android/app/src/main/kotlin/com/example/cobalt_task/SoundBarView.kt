package com.example.cobalt_task

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import android.view.animation.DecelerateInterpolator

/**
 * Vue personnalisee affichant 5 barres sonores animees.
 * Chaque barre reagit a l'amplitude audio avec une variation aleatoire
 * pour un rendu organique style equalizer.
 */
class SoundBarView(context: Context) : View(context) {

    companion object {
        private const val BAR_COUNT = 5
        private const val BAR_WIDTH_DP = 6f
        private const val BAR_SPACING_DP = 4f
        private const val MIN_HEIGHT_DP = 8f
        private const val MAX_HEIGHT_DP = 40f
        private const val ACCENT_COLOR = 0xFF00C471.toInt()
        private const val CORNER_RADIUS_DP = 3f
    }

    private val density = context.resources.displayMetrics.density
    private val barWidthPx = BAR_WIDTH_DP * density
    private val barSpacingPx = BAR_SPACING_DP * density
    private val minHeightPx = MIN_HEIGHT_DP * density
    private val maxHeightPx = MAX_HEIGHT_DP * density
    private val cornerRadiusPx = CORNER_RADIUS_DP * density

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ACCENT_COLOR
        style = Paint.Style.FILL
    }

    private val barHeights = FloatArray(BAR_COUNT) { minHeightPx }
    private val animators = arrayOfNulls<ValueAnimator>(BAR_COUNT)
    private val rect = RectF()

    /**
     * Met a jour l'amplitude (0.0..1.0 normalise).
     * Chaque barre recoit une variation aleatoire pour un look organique.
     */
    fun updateAmplitude(amplitude: Float) {
        for (i in 0 until BAR_COUNT) {
            val variation = 0.7f + (Math.random().toFloat() * 0.6f)
            val target = (minHeightPx + (maxHeightPx - minHeightPx) * amplitude * variation)
                .coerceIn(minHeightPx, maxHeightPx)

            animators[i]?.cancel()
            animators[i] = ValueAnimator.ofFloat(barHeights[i], target).apply {
                duration = 80
                interpolator = DecelerateInterpolator()
                addUpdateListener { anim ->
                    barHeights[i] = anim.animatedValue as Float
                    invalidate()
                }
                start()
            }
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val totalWidth = (BAR_COUNT * barWidthPx + (BAR_COUNT - 1) * barSpacingPx).toInt()
        val totalHeight = maxHeightPx.toInt()
        setMeasuredDimension(totalWidth, totalHeight)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val totalWidth = BAR_COUNT * barWidthPx + (BAR_COUNT - 1) * barSpacingPx
        val startX = (width - totalWidth) / 2f

        for (i in 0 until BAR_COUNT) {
            val left = startX + i * (barWidthPx + barSpacingPx)
            val barH = barHeights[i]
            val top = (height - barH) / 2f
            rect.set(left, top, left + barWidthPx, top + barH)
            canvas.drawRoundRect(rect, cornerRadiusPx, cornerRadiusPx, paint)
        }
    }

    fun cleanup() {
        animators.forEach { it?.cancel() }
    }
}
