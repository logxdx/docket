package app.notesapp.notes_app

import java.io.File

/**
 * Gradium's Phonon text-to-speech (Phonon 31M, English, xn-ptts v0.6.0: MIT OR Apache-2.0; weights and
 * voices Apache-2.0), through a
 * small JNI shim (cpp/ptts_jni.c, tool/build_ptts_jni.sh) so a release build's R8 has nothing to strip.
 *
 * A model folder (tool/fetch_models.py, "phonon-tts"): config.json, tokenizer.json, model.q8.gguf,
 * default-voice.safetensors and voices/<Name>.safetensors. Every call blocks: make them off the main
 * thread, one at a time. Audio is 24 kHz mono floats in [-1, 1].
 */
class PhononTts private constructor(private var handle: Long) : AutoCloseable {
    companion object {
        const val SAMPLE_RATE = 24_000

        /** Why the voice cannot run in this build or on this phone, or null when it can. */
        val unavailable: String? by lazy {
            try {
                // Two threads: 8x faster than real time with first audio in about 50 ms.
                android.system.Os.setenv("RAYON_NUM_THREADS", "2", false)
                System.loadLibrary("ptts_jni")
                null
            } catch (e: Throwable) {
                "the reading voice is not in this build"
            }
        }

        /** Load the model in [dir] (text normalized as English); throws with the reason. */
        fun load(dir: File): PhononTts {
            unavailable?.let { throw IllegalStateException(it) }
            val h = nativeNew(dir.path, 0, "en")
            if (h == 0L) throw IllegalStateException(nativeError(0))
            return PhononTts(h)
        }

        @JvmStatic private external fun nativeNew(dir: String, threads: Int, lang: String): Long
        @JvmStatic private external fun nativeError(handle: Long): String
        @JvmStatic private external fun nativeVoices(handle: Long): Array<String>
        @JvmStatic private external fun nativeSetVoice(handle: Long, name: String): Boolean
        @JvmStatic private external fun nativeSpeak(handle: Long, text: String, listener: Listener): Boolean
        @JvmStatic private external fun nativeFree(handle: Long)
    }

    /** Gets each piece of audio as it is made; false stops early. */
    fun interface Listener {
        fun onAudio(pcm: FloatArray): Boolean
    }

    /** The voices this model ships. */
    val voices: List<String> by lazy { nativeVoices(open()).toList() }

    /** Speak in [name], one of [voices], from now on. */
    @Synchronized
    fun setVoice(name: String) {
        if (!nativeSetVoice(open(), name)) throw IllegalStateException(nativeError(open()))
    }

    /** Speak [text], handing [listener] the audio as it is made; returns once it is all handed over. */
    @Synchronized
    fun speak(text: String, listener: Listener) {
        var thrown: Throwable? = null
        val guarded = Listener { pcm ->
            try {
                listener.onAudio(pcm)
            } catch (t: Throwable) {
                thrown = t
                false
            }
        }
        val ok = nativeSpeak(open(), text, guarded)
        thrown?.let { throw it }
        if (!ok) {
            val error = nativeError(open())
            // Stopped early by the listener is not a failure.
            if (error.isNotBlank() && !error.contains("cancel", ignoreCase = true)) throw IllegalStateException(error)
        }
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) nativeFree(handle)
        handle = 0
    }

    private fun open(): Long = handle.takeIf { it != 0L } ?: throw IllegalStateException("the reading voice is closed")
}
