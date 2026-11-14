package app.notesapp.notes_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Handler
import android.os.Looper
import java.io.File

/**
 * A note read aloud: its sentences synthesized one after another by
 * [PhononTts] on one worker thread, ahead of playback, into a 24 kHz float AudioTrack. Each sentence's
 * first frame is noted, and a watcher on the play head says which sentence is being *heard* (not
 * synthesized), so the highlight in the app moves with the voice. Speed by PlaybackParams (pitch kept);
 * transient audio focus, ducking others. The model is let go after five idle minutes.
 */
class ReadAloud(
    private val context: Context,
    private val modelDir: () -> File?,
    /** The user's own voices (<Name>.safetensors), kept apart from the models so pushing models never touches them. */
    private val customDir: File,
) {
    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(AudioManager::class.java)
    private var tts: PhononTts? = null
    private val lock = Object()

    // One reading at a time; a new one (or stop) bumps the generation and the old one ends.
    @Volatile private var generation = 0
    @Volatile private var paused = false
    private var track: AudioTrack? = null
    private var focus: AudioFocusRequest? = null
    private val releaseIdle = Runnable { synchronized(lock) { tts?.close(); tts = null } }

    init {
        // The app makes (and so owns) its voices folder: it can then add, rename and remove in it, whatever
        // else put files there (adb, a file manager).
        customDir.mkdirs()
    }

    /** Whether the voice can run: its model here and its library in this build. */
    fun available(): Boolean = PhononTts.unavailable == null && modelDir() != null

    /** The voices to choose from (loads the model): the stock ones and the user's own. */
    fun voices(): List<String> = model().voices

    /** The user's own voices that are valid Phonon voices, by name. */
    fun customVoices(): List<String> =
        (customDir.listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(".safetensors") && VoiceFile.problem(it) == null }
            .map { it.name.removeSuffix(".safetensors") }
            .sorted()

    /**
     * Add [source] as the user's voice [name]: refused unless it is a Phonon voice file (VoiceFile) and the
     * voice engine loads it too. Returns the name kept.
     */
    fun addVoice(source: File, name: String): String = synchronized(lock) {
        val clean = VoiceFile.cleanName(name)
        require(clean.isNotEmpty()) { "Give the voice a name." }
        VoiceFile.problem(source)?.let { throw IllegalArgumentException(it) }
        if (clean in stockVoices()) throw IllegalArgumentException("$clean is already a voice here: choose another name.")
        customDir.mkdirs()
        val target = File(customDir, "$clean.safetensors")
        if (target.exists()) throw IllegalArgumentException("You already have a voice called $clean.")
        source.copyTo(target)
        reload()
        try {
            model().setVoice(clean)
        } catch (e: Throwable) {
            target.delete()
            reload()
            throw IllegalArgumentException("The voice engine could not use this file: ${e.message}")
        }
        clean
    }

    fun removeVoice(name: String) = synchronized(lock) {
        File(customDir, "$name.safetensors").delete()
        reload()
    }

    fun renameVoice(from: String, to: String): String = synchronized(lock) {
        val clean = VoiceFile.cleanName(to)
        require(clean.isNotEmpty()) { "Give the voice a name." }
        if (clean == from) return clean
        if (clean in stockVoices() || File(customDir, "$clean.safetensors").exists()) {
            throw IllegalArgumentException("There is already a voice called $clean.")
        }
        if (!File(customDir, "$from.safetensors").renameTo(File(customDir, "$clean.safetensors"))) {
            throw IllegalStateException("$from could not be renamed.")
        }
        reload()
        clean
    }

    private fun stockVoices(): Set<String> =
        (modelDir()?.let { File(it, "voices").listFiles() } ?: emptyArray())
            .map { it.name.removeSuffix(".safetensors") }.toSet()

    /** Let go of the loaded model so the next use sees the voices as they are now. */
    private fun reload() {
        stop()
        tts?.close()
        tts = null
    }

    private fun model(): PhononTts = synchronized(lock) {
        main.removeCallbacks(releaseIdle)
        tts ?: PhononTts.load(checkpoint()).also { tts = it }
    }

    /**
     * The folder the voice engine loads: links to the bundled model's files and its voices, and to each valid
     * voice of the user's. Made again on every load.
     */
    private fun checkpoint(): File {
        val base = modelDir() ?: throw IllegalStateException("the reading voice is not on this phone")
        val dir = File(context.filesDir, "tts-checkpoint")
        dir.deleteRecursively()
        File(dir, "voices").mkdirs()
        for (f in base.listFiles() ?: emptyArray()) {
            if (f.isFile) android.system.Os.symlink(f.absolutePath, File(dir, f.name).absolutePath)
        }
        for (f in File(base, "voices").listFiles() ?: emptyArray()) {
            android.system.Os.symlink(f.absolutePath, File(dir, "voices/${f.name}").absolutePath)
        }
        for (name in customVoices()) {
            val link = File(dir, "voices/$name.safetensors")
            if (!link.exists()) android.system.Os.symlink(File(customDir, "$name.safetensors").absolutePath, link.absolutePath)
        }
        return dir
    }

    /**
     * Read [sentences] from [from] in [voice] (null or blank: the default) at [speed]. [onSentence] gets the
     * index of each sentence as it starts being heard, [onDone] true once the last one has been heard,
     * false when it stopped (stop(), another start(), or a failure, with its message).
     */
    fun start(
        sentences: List<String>,
        from: Int,
        voice: String?,
        speed: Float,
        onSentence: (Int) -> Unit,
        onDone: (completed: Boolean, error: String?) -> Unit,
    ) {
        stop()
        val mine = ++generation
        paused = false
        Thread({ run(mine, sentences, from, voice, speed, onSentence, onDone) }, "read-aloud").start()
    }

    fun pause() {
        paused = true
        track?.pause()
    }

    fun resume() {
        paused = false
        track?.play()
    }

    fun stop() {
        generation++
        paused = false
        track?.let {
            try {
                it.pause()
                it.flush()
            } catch (_: IllegalStateException) {
            }
        }
    }

    private fun run(
        mine: Int,
        sentences: List<String>,
        from: Int,
        voice: String?,
        speed: Float,
        onSentence: (Int) -> Unit,
        onDone: (Boolean, String?) -> Unit,
    ) {
        fun live() = generation == mine
        var error: String? = null
        val starts = LongArray(sentences.size) { Long.MAX_VALUE } // first frame of each sentence
        var written = 0L
        var heard = -1
        val t = newTrack(speed)
        track = t
        takeFocus()
        // The watcher: which sentence the play head is in.
        val watch = object : Runnable {
            override fun run() {
                if (!live()) return
                val head = t.playbackHeadPosition.toLong() and 0xffffffffL
                var now = heard
                for (i in from until sentences.size) if (starts[i] <= head) now = i
                if (now != heard && now >= 0) {
                    heard = now
                    onSentence(now)
                }
                main.postDelayed(this, 50)
            }
        }
        try {
            val tts = model()
            if (!voice.isNullOrBlank() && voice in tts.voices) tts.setVoice(voice)
            t.play()
            main.post(watch)
            for (i in from until sentences.size) {
                if (!live()) break
                var first = true
                tts.speak(sentences[i]) { pcm ->
                    if (!live()) return@speak false
                    if (first) {
                        starts[i] = written
                        first = false
                    }
                    var at = 0
                    while (at < pcm.size) {
                        if (!live()) return@speak false
                        if (paused) {
                            Thread.sleep(30)
                            continue
                        }
                        val n = t.write(pcm, at, pcm.size - at, AudioTrack.WRITE_BLOCKING)
                        if (n < 0) throw IllegalStateException("audio output failed ($n)")
                        at += n
                    }
                    written += pcm.size
                    true
                }
            }
            // Until the last of it has been heard.
            while (live() && (t.playbackHeadPosition.toLong() and 0xffffffffL) < written) Thread.sleep(40)
        } catch (e: Throwable) {
            // Any failure (an Error from native code too) ends this reading, never the app.
            error = e.message ?: e.javaClass.simpleName
        } finally {
            main.removeCallbacks(watch)
            val completed = live() && error == null
            try {
                t.stop()
            } catch (_: IllegalStateException) {
            }
            t.release()
            if (track === t) track = null
            if (generation == mine || error != null) {
                dropFocus()
                main.post { onDone(completed, error) }
            }
            main.removeCallbacks(releaseIdle)
            main.postDelayed(releaseIdle, 5 * 60 * 1000L)
        }
    }

    private fun newTrack(speed: Float): AudioTrack {
        val min = AudioTrack.getMinBufferSize(PhononTts.SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(PhononTts.SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(min, PhononTts.SAMPLE_RATE * 4 / 5)) // about 0.2 s
            .build()
        if (speed != 1f) t.playbackParams = PlaybackParams().setSpeed(speed).setPitch(1f)
        return t
    }

    private fun takeFocus() {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .build()
        focus = request
        audio?.requestAudioFocus(request)
    }

    private fun dropFocus() {
        focus?.let { audio?.abandonAudioFocusRequest(it) }
        focus = null
    }
}
