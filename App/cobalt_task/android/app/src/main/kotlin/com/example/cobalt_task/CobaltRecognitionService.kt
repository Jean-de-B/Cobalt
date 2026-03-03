package com.example.cobalt_task

import android.content.Intent
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log

/**
 * Stub RecognitionService requis par VoiceInteractionServiceInfo (AOSP).
 *
 * Le framework Android exige que le metadata XML du VoiceInteractionService
 * declare un android:recognitionService non-null. Sans cela, le service
 * est silencieusement rejete (getParseError() != null) et jamais binde.
 *
 * La reconnaissance vocale reelle est geree par Sherpa ONNX cote Flutter.
 * Cette classe existe uniquement pour satisfaire la validation du framework.
 */
class CobaltRecognitionService : RecognitionService() {

    companion object {
        private const val TAG = "CobaltRecognition"
    }

    override fun onStartListening(intent: Intent?, callback: Callback?) {
        Log.d(TAG, "onStartListening (stub - Cobalt utilise Sherpa ONNX)")
        callback?.error(SpeechRecognizer.ERROR_SERVER)
    }

    override fun onCancel(callback: Callback?) {
        Log.d(TAG, "onCancel (stub)")
    }

    override fun onStopListening(callback: Callback?) {
        Log.d(TAG, "onStopListening (stub)")
    }
}
