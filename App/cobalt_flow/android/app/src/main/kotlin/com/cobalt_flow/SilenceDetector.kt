package com.cobalt_flow

import kotlin.math.sqrt

/**
 * Détecte les silences dans un flux audio PCM 16-bit mono.
 *
 * @param threshold Seuil RMS en dessous duquel on considère le silence
 * @param ticksRequired Nombre de chunks silencieux consécutifs pour confirmer
 */
class SilenceDetector(
    private val threshold: Double = 400.0,
    private val ticksRequired: Int = 8
) {
    private var silenceTicks = 0

    fun process(audio: ByteArray): Boolean {
        val rms = calculateRMS(audio)
        return if (rms < threshold) {
            silenceTicks++
            silenceTicks >= ticksRequired
        } else {
            silenceTicks = 0
            false
        }
    }

    fun reset() {
        silenceTicks = 0
    }

    companion object {
        fun calculateRMS(audio: ByteArray): Double {
            if (audio.size < 2) return 0.0
            var sum = 0.0
            val samples = audio.size / 2
            for (i in 0 until audio.size - 1 step 2) {
                val sample = (audio[i].toInt() and 0xFF) or (audio[i + 1].toInt() shl 8)
                val signed = sample.toShort().toDouble()
                sum += signed * signed
            }
            return sqrt(sum / samples)
        }
    }
}
