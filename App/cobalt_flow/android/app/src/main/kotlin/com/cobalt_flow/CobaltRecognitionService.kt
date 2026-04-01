package com.cobalt_flow

import android.content.Intent
import android.os.Bundle
import android.os.RemoteException
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log

/**
 * Service de reconnaissance vocale Cobalt Flow.
 *
 * Remplace le moteur de reconnaissance vocale par défaut (Google/Samsung)
 * pour que le bouton micro du clavier Samsung utilise Groq Whisper.
 *
 * Flow :
 * 1. Samsung Keyboard appuie sur le micro → Android déclenche onStartListening()
 * 2. Cobalt capture l'audio via AudioCaptureService (PCM 16kHz mono)
 * 3. L'audio est envoyé à Groq Whisper toutes les ~1.5s
 * 4. Les résultats partiels sont renvoyés au clavier via callback.partialResults()
 * 5. Silence détecté → résultat final via callback.results()
 * 6. Samsung Keyboard injecte le texte dans le champ de saisie
 */
class CobaltRecognitionService : RecognitionService() {

    companion object {
        private const val TAG = "CobaltRecognition"
    }

    private val audioCapture = AudioCaptureService()
    private val groqEngine = GroqStreamingEngine()

    override fun onCreate() {
        super.onCreate()
        SettingsManager.init(this)
        Log.d(TAG, "CobaltRecognitionService créé")
    }

    override fun onStartListening(recognizerIntent: Intent?, callback: Callback?) {
        if (callback == null) return

        Log.d(TAG, "onStartListening — démarrage de la reconnaissance vocale Cobalt")

        // Extract language from intent if provided, fallback to settings
        val intentLanguage = recognizerIntent?.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE)
        if (intentLanguage != null) {
            // Map locale codes (fr-FR, en-US...) to our short codes (fr, en...)
            val shortLang = intentLanguage.split("-", "_").firstOrNull()?.lowercase() ?: "fr"
            if (shortLang in listOf("fr", "en", "es", "de")) {
                SettingsManager.language = shortLang
            }
        }

        groqEngine.reset()

        // Notify the client that we're ready to listen
        try {
            callback.readyForSpeech(Bundle())
        } catch (e: RemoteException) {
            Log.e(TAG, "Erreur callback readyForSpeech", e)
        }

        audioCapture.start { audioChunk ->
            // Notify that we're receiving audio (beginningOfSpeech on first voiced chunk)
            notifyBeginningOfSpeech(callback)

            // Send audio to Groq for transcription
            groqEngine.sendChunk(audioChunk) { text, isFinal ->
                if (isFinal) {
                    sendFinalResult(callback, text)
                } else {
                    sendPartialResult(callback, text)
                }
            }
        }
    }

    override fun onStopListening(callback: Callback?) {
        Log.d(TAG, "onStopListening")
        audioCapture.stop()

        groqEngine.flush { finalText ->
            if (finalText.isNotBlank()) {
                sendFinalResult(callback, finalText)
            } else {
                // Send empty result to signal end
                sendFinalResult(callback, "")
            }
        }
    }

    override fun onCancel(callback: Callback?) {
        Log.d(TAG, "onCancel")
        audioCapture.stop()
        groqEngine.reset()
    }

    override fun onDestroy() {
        audioCapture.stop()
        groqEngine.reset()
        Log.d(TAG, "CobaltRecognitionService détruit")
        super.onDestroy()
    }

    // --- Flag to send beginningOfSpeech only once per session ---
    @Volatile
    private var speechBegun = false

    private fun notifyBeginningOfSpeech(callback: Callback?) {
        if (speechBegun) return
        speechBegun = true
        try {
            callback?.beginningOfSpeech()
        } catch (e: RemoteException) {
            Log.e(TAG, "Erreur callback beginningOfSpeech", e)
        }
    }

    private fun sendPartialResult(callback: Callback?, text: String) {
        if (callback == null || text.isBlank()) return
        try {
            val processed = if (SettingsManager.autoPunctuation) {
                PunctuationProcessor.process(text)
            } else {
                text
            }

            val bundle = Bundle().apply {
                putStringArrayList(
                    SpeechRecognizer.RESULTS_RECOGNITION,
                    arrayListOf(processed)
                )
            }
            callback.partialResults(bundle)
            Log.d(TAG, "Résultat partiel: '$processed'")
        } catch (e: RemoteException) {
            Log.e(TAG, "Erreur callback partialResults", e)
        }
    }

    private fun sendFinalResult(callback: Callback?, text: String) {
        if (callback == null) return
        try {
            val processed = if (text.isNotBlank() && SettingsManager.autoPunctuation) {
                PunctuationProcessor.process(text)
            } else {
                text
            }

            val bundle = Bundle().apply {
                putStringArrayList(
                    SpeechRecognizer.RESULTS_RECOGNITION,
                    arrayListOf(processed)
                )
                putFloatArray(
                    SpeechRecognizer.CONFIDENCE_SCORES,
                    floatArrayOf(0.95f)
                )
            }
            callback.results(bundle)
            speechBegun = false
            Log.d(TAG, "Résultat final: '$processed'")
        } catch (e: RemoteException) {
            Log.e(TAG, "Erreur callback results", e)
        }
    }
}
