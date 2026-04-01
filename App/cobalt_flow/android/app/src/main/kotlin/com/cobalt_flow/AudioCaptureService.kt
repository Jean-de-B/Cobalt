package com.cobalt_flow

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Capture audio PCM 16kHz mono depuis le microphone.
 * Envoie des chunks de 100ms au callback pour traitement temps réel.
 */
class AudioCaptureService {
    companion object {
        private const val TAG = "AudioCapture"
        private const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val CHUNK_DURATION_MS = 100
    }

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var isCapturing = false

    /**
     * Démarre la capture audio.
     * @param onChunk Callback appelé toutes les 100ms avec les données PCM brutes
     */
    fun start(onChunk: (ByteArray) -> Unit) {
        if (isCapturing) return

        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        if (bufferSize == AudioRecord.ERROR_BAD_VALUE || bufferSize == AudioRecord.ERROR) {
            Log.e(TAG, "Buffer size invalide: $bufferSize")
            return
        }

        try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                AUDIO_FORMAT,
                bufferSize * 2
            )

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord non initialisé")
                audioRecord?.release()
                audioRecord = null
                return
            }

            audioRecord?.startRecording()
            isCapturing = true

            val chunkSize = SAMPLE_RATE * 2 * CHUNK_DURATION_MS / 1000 // bytes per chunk
            captureThread = Thread({
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
                val buffer = ByteArray(chunkSize)
                while (isCapturing) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                    if (read > 0) {
                        onChunk(buffer.copyOf(read))
                    }
                }
            }, "CobaltFlow-AudioCapture")
            captureThread?.start()

            Log.d(TAG, "Capture démarrée (${SAMPLE_RATE}Hz, chunks ${CHUNK_DURATION_MS}ms)")
        } catch (e: SecurityException) {
            Log.e(TAG, "Permission RECORD_AUDIO manquante", e)
        }
    }

    fun stop() {
        isCapturing = false
        captureThread?.join(500)
        captureThread = null

        try {
            audioRecord?.stop()
        } catch (_: Exception) {}
        audioRecord?.release()
        audioRecord = null

        Log.d(TAG, "Capture arrêtée")
    }

    val isActive: Boolean get() = isCapturing
}
