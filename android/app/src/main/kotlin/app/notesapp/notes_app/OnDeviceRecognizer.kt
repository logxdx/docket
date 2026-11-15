package app.notesapp.notes_app

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionPart
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import kotlin.coroutines.resume

/**
 * The phone's own recognizer, for a language Phonon does not know (Phonon has 25 European
 * languages; Ear names 102). Strictly on the device: [SpeechRecognizer.createOnDeviceSpeechRecognizer]
 * never sends audio anywhere, and a language without an installed offline pack is reported,
 * not sent online. It reads the recording from a file (Android 13+) and, from Android 14,
 * gives each word's start time.
 */
object OnDeviceRecognizer {

    data class Word(val text: String, val start: Double, val end: Double)

    sealed class Outcome {
        data class Heard(val tag: String, val text: String, val words: List<Word>, val timed: Boolean) : Outcome()
        /** The phone cannot transcribe [language] on the device: [reason] says what to do. */
        data class Unavailable(val reason: String) : Outcome()
    }

    /** Transcribe [pcm16] (16 kHz mono 16-bit PCM) in [language] (ISO 639-1/3, as Ear names it). */
    suspend fun transcribe(context: Context, pcm16: File, durationSec: Double, language: String): Outcome {
        if (Build.VERSION.SDK_INT < 33) {
            return Outcome.Unavailable("Transcribing this language on the phone needs Android 13 or later.")
        }
        return withContext(Dispatchers.Main) {
            if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
                return@withContext Outcome.Unavailable("This phone has no on-device speech recognizer.")
            }
            val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            try {
                val support = support(context, recognizer)
                val wanted = if (language == "no") "nb" else language
                fun matches(tag: String) = tag.substringBefore('-').substringBefore('_').equals(wanted, ignoreCase = true)
                val tag = support?.installedOnDeviceLanguages?.firstOrNull(::matches)
                    ?: return@withContext Outcome.Unavailable(
                        if (support?.supportedOnDeviceLanguages?.any(::matches) == true)
                            "The offline speech pack for this language is not installed. Install it in the phone's " +
                                "speech recognition settings (offline languages), then transcribe again."
                        else "This phone cannot transcribe this language offline.",
                    )
                withTimeout(((durationSec * 3 + 60) * 1000).toLong()) { listen(recognizer, pcm16, tag) }
            } finally {
                recognizer.destroy()
            }
        }
    }

    private suspend fun support(context: Context, recognizer: SpeechRecognizer): RecognitionSupport? =
        if (Build.VERSION.SDK_INT < 33) null else suspendCancellableCoroutine { done ->
            recognizer.checkRecognitionSupport(
                Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
                context.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        if (done.isActive) done.resume(support)
                    }

                    override fun onError(error: Int) {
                        if (done.isActive) done.resume(null)
                    }
                },
            )
        }

    private suspend fun listen(recognizer: SpeechRecognizer, pcm16: File, tag: String): Outcome =
        suspendCancellableCoroutine { done ->
            val audio = ParcelFileDescriptor.open(pcm16, ParcelFileDescriptor.MODE_READ_ONLY)
            val texts = mutableListOf<String>()
            val words = mutableListOf<Word>()
            var timed = Build.VERSION.SDK_INT >= 34

            fun take(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()
                if (text.isNullOrEmpty()) return
                texts += text
                val parts = if (Build.VERSION.SDK_INT >= 34) {
                    results.getParcelableArrayList(SpeechRecognizer.RECOGNITION_PARTS, RecognitionPart::class.java)
                } else null
                if (parts.isNullOrEmpty()) {
                    timed = false
                    text.split(Regex("\\s+")).filter { it.isNotEmpty() }.forEach { words += Word(it, -1.0, -1.0) }
                } else {
                    // A part carries its start only: it ends where the next begins (or 0.4 s on).
                    val starts = parts.map { it.timestampMillis / 1000.0 }
                    for ((i, p) in parts.withIndex()) {
                        val w = (p.formattedText ?: p.rawText).trim()
                        if (w.isEmpty()) continue
                        val end = starts.getOrNull(i + 1)?.takeIf { it > starts[i] } ?: (starts[i] + 0.4)
                        words += Word(w, starts[i], end)
                    }
                }
            }

            fun finish() {
                audio.close()
                if (done.isActive) done.resume(Outcome.Heard(tag, texts.joinToString(" "), words, timed && words.isNotEmpty()))
            }

            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onSegmentResults(segmentResults: Bundle) = take(segmentResults)
                override fun onEndOfSegmentedSession() = finish()
                override fun onResults(results: Bundle?) {
                    take(results)
                    finish()
                }

                override fun onError(error: Int) {
                    if (texts.isNotEmpty() || error == SpeechRecognizer.ERROR_NO_MATCH ||
                        error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
                    ) {
                        finish()
                    } else {
                        audio.close()
                        if (done.isActive) {
                            done.resume(Outcome.Unavailable("The phone's recognizer failed (error $error)."))
                        }
                    }
                }

                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audio)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16_000)
                // One session over the whole file, results per segment, rather than stopping at the first pause.
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
                putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
                if (Build.VERSION.SDK_INT >= 34) putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_TIMING, true)
            }
            done.invokeOnCancellation {
                recognizer.cancel()
                audio.close()
            }
            recognizer.startListening(intent)
        }
}
