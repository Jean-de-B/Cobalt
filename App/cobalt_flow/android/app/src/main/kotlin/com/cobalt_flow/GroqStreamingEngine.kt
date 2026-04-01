package com.cobalt_flow

import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.DataOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Moteur de transcription streaming via Groq Whisper.
 *
 * Stratégie "chunk + accumulate" :
 * 1. Accumule l'audio dans un buffer
 * 2. Toutes les ~1.5s, envoie le buffer courant à Groq Whisper via HTTP
 * 3. Compare la nouvelle transcription avec la précédente → affiche les nouveaux mots
 * 4. Détecte le silence (800ms) → finalise la phrase et vide le buffer
 *
 * Résultat perçu : le texte s'affiche mot par mot avec ~1.5s de latence.
 */
class GroqStreamingEngine {
    companion object {
        private const val TAG = "GroqStreaming"
        private const val ENDPOINT = "https://api.groq.com/openai/v1/audio/transcriptions"
        private const val MODEL = "whisper-large-v3"
        private const val CHUNKS_PER_REQUEST = 15 // 15 × 100ms = 1.5s
    }

    private val audioBuffer = CopyOnWriteArrayList<ByteArray>()
    private var lastTranscription = ""
    private var committedText = "" // Texte déjà injecté dans le champ
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val silenceDetector = SilenceDetector(threshold = 400.0, ticksRequired = 8)
    private var chunkCount = 0
    @Volatile private var isTranscribing = false

    /**
     * Traite un chunk audio (100ms).
     * @param onResult (text, isFinal) — texte partiel ou final
     */
    fun sendChunk(audio: ByteArray, onResult: (String, Boolean) -> Unit) {
        audioBuffer.add(audio)
        chunkCount++

        val isSilent = silenceDetector.process(audio)

        if (isSilent && audioBuffer.isNotEmpty()) {
            // Silence détecté → transcription finale
            flush { text ->
                if (text.isNotBlank()) {
                    mainHandler.post { onResult(text, true) }
                }
            }
        } else if (chunkCount % CHUNKS_PER_REQUEST == 0 && !isTranscribing && audioBuffer.isNotEmpty()) {
            // Toutes les 1.5s → transcription partielle
            isTranscribing = true
            val snapshot = audioBuffer.toList()
            transcribeBuffer(snapshot) { text ->
                isTranscribing = false
                if (text.isNotBlank()) {
                    val newPart = extractNewWords(lastTranscription, text)
                    if (newPart.isNotBlank()) {
                        lastTranscription = text
                        mainHandler.post { onResult(text, false) }
                    }
                }
            }
        }
    }

    /**
     * Finalise la session : transcrit le buffer restant et le vide.
     */
    fun flush(onFinal: (String) -> Unit) {
        if (audioBuffer.isEmpty()) {
            onFinal("")
            return
        }

        val snapshot = audioBuffer.toList()
        audioBuffer.clear()
        chunkCount = 0
        silenceDetector.reset()

        transcribeBuffer(snapshot) { text ->
            val newText = if (committedText.isNotEmpty() && text.startsWith(committedText)) {
                text.substring(committedText.length).trim()
            } else {
                extractNewWords(committedText, text)
            }

            if (newText.isNotBlank()) {
                committedText += (if (committedText.isEmpty()) "" else " ") + newText
            }
            lastTranscription = ""
            mainHandler.post { onFinal(newText) }
        }
    }

    fun reset() {
        audioBuffer.clear()
        lastTranscription = ""
        committedText = ""
        chunkCount = 0
        silenceDetector.reset()
        isTranscribing = false
    }

    private fun transcribeBuffer(chunks: List<ByteArray>, onResult: (String) -> Unit) {
        executor.submit {
            try {
                val pcmData = chunks.fold(ByteArray(0)) { acc, chunk -> acc + chunk }
                val wavBytes = WavBuilder.build(pcmData)

                val apiKey = SettingsManager.groqApiKey
                if (apiKey.isBlank()) {
                    Log.e(TAG, "Clé API Groq manquante")
                    onResult("")
                    return@submit
                }

                val language = SettingsManager.language
                val prompt = if (SettingsManager.autoPunctuation) {
                    "Transcription avec ponctuation correcte."
                } else {
                    "Transcription sans ponctuation."
                }

                val result = sendToGroq(wavBytes, apiKey, language, prompt)
                onResult(result)
            } catch (e: Exception) {
                Log.e(TAG, "Erreur transcription: ${e.message}")
                onResult("")
            }
        }
    }

    private fun sendToGroq(wavBytes: ByteArray, apiKey: String, language: String, prompt: String): String {
        val boundary = "CobaltFlow${System.currentTimeMillis()}"
        val url = URL(ENDPOINT)
        val conn = url.openConnection() as HttpURLConnection

        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Authorization", "Bearer $apiKey")
            conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            conn.connectTimeout = 10000
            conn.readTimeout = 15000

            val outputStream = DataOutputStream(conn.outputStream)

            // model field
            writeFormField(outputStream, boundary, "model", MODEL)

            // language field
            writeFormField(outputStream, boundary, "language", language)

            // response_format field
            writeFormField(outputStream, boundary, "response_format", "json")

            // prompt field
            writeFormField(outputStream, boundary, "prompt", prompt)

            // audio file
            outputStream.writeBytes("--$boundary\r\n")
            outputStream.writeBytes("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
            outputStream.writeBytes("Content-Type: audio/wav\r\n\r\n")
            outputStream.write(wavBytes)
            outputStream.writeBytes("\r\n")

            // end boundary
            outputStream.writeBytes("--$boundary--\r\n")
            outputStream.flush()
            outputStream.close()

            val responseCode = conn.responseCode
            if (responseCode == 200) {
                val response = conn.inputStream.bufferedReader().readText()
                val json = JSONObject(response)
                return json.optString("text", "").trim()
            } else {
                val error = conn.errorStream?.bufferedReader()?.readText() ?: "Unknown error"
                Log.e(TAG, "Groq API error $responseCode: $error")
                return ""
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun writeFormField(os: DataOutputStream, boundary: String, name: String, value: String) {
        os.writeBytes("--$boundary\r\n")
        os.writeBytes("Content-Disposition: form-data; name=\"$name\"\r\n\r\n")
        os.writeBytes("$value\r\n")
    }

    private fun extractNewWords(previous: String, current: String): String {
        if (previous.isBlank()) return current
        val prevWords = previous.trim().split("\\s+".toRegex())
        val currWords = current.trim().split("\\s+".toRegex())
        return if (currWords.size > prevWords.size) {
            currWords.drop(prevWords.size).joinToString(" ")
        } else {
            ""
        }
    }
}
