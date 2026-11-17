package app.notesapp.notes_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import java.util.Locale

/**
 * Reading aloud with Android's own text-to-speech (Settings › Speech › Read aloud: Android's own), in the same
 * shape as [ReadAloud]: sentences read one after another, each announced as it starts. Only the phone's offline
 * voices are used, never one that needs the network, so nothing read leaves the phone. Android's engine cannot
 * pause: pausing stops after noting where it was, and resuming starts that sentence again.
 */
class AndroidReader(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ready = false
    private val waiting = mutableListOf<(TextToSpeech) -> Unit>()

    private var sentences: List<String> = emptyList()
    private var index = 0
    private var onSentence: (Int) -> Unit = {}
    private var onDone: (Boolean, String?) -> Unit = { _, _ -> }

    /** Raised by every start, pause and stop: callbacks from an earlier reading are ignored. */
    private var generation = 0

    /** [block] with the engine, once it is up (it starts on first use). */
    private fun withEngine(block: (TextToSpeech) -> Unit) {
        val engine = tts
        if (engine != null && ready) {
            block(engine)
            return
        }
        waiting += block
        if (engine != null) return
        tts = TextToSpeech(context) { status ->
            main.post {
                val up = tts
                if (status == TextToSpeech.SUCCESS && up != null) {
                    ready = true
                    up.setOnUtteranceProgressListener(listener)
                    val queued = waiting.toList()
                    waiting.clear()
                    queued.forEach { it(up) }
                } else {
                    waiting.clear()
                    tts = null
                    onDone(false, "Android's text-to-speech is not available on this phone.")
                }
            }
        }
    }

    private fun offline(engine: TextToSpeech): List<Voice> = (engine.voices ?: emptySet()).filter {
        !it.isNetworkConnectionRequired && TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in it.features
    }

    /** The phone's offline voices, by name. */
    fun voices(result: (List<String>) -> Unit) = main.post {
        withEngine { engine -> result(offline(engine).map { it.name }.sorted()) }
    }

    fun start(
        sentences: List<String>,
        from: Int,
        voice: String?,
        speed: Float,
        onSentence: (Int) -> Unit,
        onDone: (Boolean, String?) -> Unit,
    ) = main.post {
        generation++
        tts?.stop()
        this.sentences = sentences
        this.index = from
        this.onSentence = onSentence
        this.onDone = onDone
        withEngine { engine ->
            val voices = offline(engine)
            val chosen = voices.firstOrNull { it.name == voice }
                ?: engine.defaultVoice?.takeIf { it in voices }
                ?: voices.firstOrNull { it.locale.language == Locale.getDefault().language }
                ?: voices.firstOrNull()
            if (chosen == null) {
                onDone(false, "This phone has no offline voice: add one in Android's text-to-speech settings.")
                return@withEngine
            }
            engine.voice = chosen
            engine.setSpeechRate(speed)
            speakFrom(engine, index)
        }
    }

    private fun speakFrom(engine: TextToSpeech, from: Int) {
        val mine = generation
        if (from >= sentences.size) {
            onDone(true, null)
            return
        }
        for (i in from until sentences.size) {
            engine.speak(sentences[i], TextToSpeech.QUEUE_ADD, null, "$mine:$i")
        }
    }

    private val listener = object : UtteranceProgressListener() {
        private fun parse(id: String?): Pair<Int, Int>? =
            id?.split(':')?.takeIf { it.size == 2 }?.let { (g, i) -> g.toIntOrNull()?.let { gen -> i.toIntOrNull()?.let { gen to it } } }

        override fun onStart(utteranceId: String?) {
            val (g, i) = parse(utteranceId) ?: return
            main.post {
                if (g != generation) return@post
                index = i
                onSentence(i)
            }
        }

        override fun onDone(utteranceId: String?) {
            val (g, i) = parse(utteranceId) ?: return
            main.post { if (g == generation && i == sentences.size - 1) onDone(true, null) }
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            val (g, _) = parse(utteranceId) ?: return
            main.post { if (g == generation) onDone(false, "Android's text-to-speech could not read this.") }
        }
    }

    fun pause() = main.post {
        generation++
        tts?.stop()
    }

    fun resume() = main.post {
        generation++
        withEngine { speakFrom(it, index) }
    }

    fun stop() = main.post {
        generation++
        tts?.stop()
    }
}
