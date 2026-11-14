package app.notesapp.notes_app

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/**
 * Phonon-2.5 (25 languages) and Phonon-2.5 English, Fermion Research's speech recognizers, through libphonon_asr.so
 * (android/app/src/main/cpp/phonon_asr.c, tool/build_asr.sh). A model folder holds
 * `model.fermion` (the weights) and `config.json` (the vocabulary). Words and their times come from the token ids
 * and the encoder frames the decoder emitted them at.
 *
 * Only arm64-v8a has the native libraries: elsewhere (x86_64) [unavailable] says so and nothing else may be called.
 */
object PhononAsr {
    /** A word and where it was said, in seconds from the first sample of the audio given. */
    data class Word(val text: String, val start: Double, val end: Double)

    /** Why recognition cannot run in this build or on this phone, or null when it can. */
    val unavailable: String? by lazy {
        try {
            System.loadLibrary("phonon_asr")
            nativeEngine()
        } catch (e: UnsatisfiedLinkError) {
            "speech recognition is not in this build"
        }
    }

    /**
     * The engine's thread pools and scratch are process-wide (phonon2.h: one decode at a time per process), so
     * every native call, of any model, takes this lock.
     */
    private val engine = Any()

    /** What [Model] needs from the native side; a fake one in the unit tests. */
    internal interface Decoder {
        /** The first [n] samples of [pcm] -> triples [id, frame, duration, ...] (see nativeTranscribe); empty if too short. */
        fun decode(pcm: ShortArray, n: Int): IntArray

        fun release()
    }

    /** A loaded model; [release] frees its 0.7 GB. One call at a time. */
    class Model internal constructor(
        private val decoder: Decoder,
        private val vocabulary: List<String>,
        private val leadPadSec: Double,
        private val finalSigma: Boolean,
    ) {
        private var released = false

        /**
         * The first [n] samples of [pcm16k] (16 kHz mono) -> its words, timed from its first sample. For up to about
         * 30 s (what the engine is used with; memory grows with the length): use [transcribeLong] for recordings.
         * Empty for under about 80 ms (when there is no leading pad).
         */
        @Synchronized
        fun transcribe(pcm16k: ShortArray, n: Int = pcm16k.size): List<Word> {
            check(!released) { "the model was released" }
            require(n in 0..pcm16k.size) { "n = $n outside 0..${pcm16k.size}" }
            val pad = padSamples(leadPadSec)
            val triples = if (pad == 0) {
                decoder.decode(pcm16k, n)
            } else {
                // Digital silence in front: an abrupt start is what the transducer most often mis-hears (Fermion's
                // engine.py _decode_window); the times are moved back by it below.
                val padded = ShortArray(pad + n)
                System.arraycopy(pcm16k, 0, padded, pad, n)
                decoder.decode(padded, padded.size)
            }
            return words(triples, vocabulary, pad / RATE.toDouble(), n / RATE.toDouble(), finalSigma)
        }

        /**
         * A whole recording -> its words, timed from its first sample: decoded in windows of at most 30 s, each cut
         * at the quietest 20 ms frame of its last third.
         */
        @Synchronized
        fun transcribeLong(pcm16k: ShortArray): List<Word> {
            val bounds = windows(pcm16k, pcm16k.size)
            if (bounds.size == 2) return transcribe(pcm16k)
            val out = ArrayList<Word>()
            for (i in 0 until bounds.size - 1) {
                val from = bounds[i]
                val to = bounds[i + 1]
                val offset = from / RATE.toDouble()
                for (w in transcribe(pcm16k.copyOfRange(from, to))) out += Word(w.text, w.start + offset, w.end + offset)
            }
            return out
        }

        @Synchronized
        fun release() {
            if (released) return
            released = true
            decoder.release()
        }
    }

    /**
     * Load the model in [dir] on [threads] threads (one per big core). [leadPadSec] is the catalog's `lead_pad_s`
     * (0.25 for Phonon-2.5, 0 for Phonon-2.5 English) and [finalSigma] its `final_sigma` (Phonon-2.5: a word-final
     * Greek "σ" is written "ς"). Throws with the reason. Takes seconds: not on the main thread.
     */
    fun load(dir: File, threads: Int, leadPadSec: Double, finalSigma: Boolean): Model {
        unavailable?.let { throw IllegalStateException(it) }
        require(leadPadSec >= 0) { "leadPadSec < 0" }
        val weights = File(dir, "model.fermion")
        val index = index(weights)
        val config = JSONObject(File(dir, "config.json").readText())
        val vocab = config.optJSONArray("vocabulary") ?: config.getJSONObject("joint").getJSONArray("vocabulary")
        val vocabulary = List(vocab.length()) { vocab.getString(it) }
        // The decoder is built for 8192 pieces + blank (phonon_asr.c checks the tables too).
        if (vocabulary.size != 8192) throw IllegalStateException("unexpected vocabulary of ${vocabulary.size} pieces")
        val error = arrayOfNulls<String>(1)
        val handle = synchronized(engine) { nativeLoad(weights.path, index, threads, error) }
        if (handle == 0L) throw IllegalStateException(error[0] ?: "the model would not load")
        val decoder = object : Decoder {
            override fun decode(pcm: ShortArray, n: Int): IntArray =
                synchronized(engine) { nativeTranscribe(handle, pcm, n) } ?: IntArray(0)

            override fun release() = synchronized(engine) { nativeRelease(handle) }
        }
        return Model(decoder, vocabulary, leadPadSec, finalSigma)
    }

    /**
     * The container's records, one a line (name kind offset bytes shape...), for the native loader: the file is an
     * 8-byte little-endian length, that many bytes of JSON whose `index` lists the records in order, then the records.
     */
    private fun index(weights: File): String = RandomAccessFile(weights, "r").use { file ->
        val head = ByteArray(8)
        file.readFully(head)
        var n = 0L
        for (i in 7 downTo 0) n = (n shl 8) or (head[i].toLong() and 0xff)
        require(n in 1..(16 shl 20)) { "not a model file" }
        val json = ByteArray(n.toInt())
        file.readFully(json)
        val records = JSONObject(String(json)).getJSONArray("index")
        var offset = 8 + n
        buildString {
            for (i in 0 until records.length()) {
                val r = records.getJSONObject(i)
                val bytes = r.getLong("b")
                val shape = r.getJSONArray("shape")
                append(r.getString("n")).append(' ').append(r.getString("k")).append(' ').append(offset).append(' ').append(bytes)
                for (d in 0 until shape.length()) append(' ').append(shape.getInt(d))
                append('\n')
                offset += bytes
            }
        }
    }

    // ------------------------------------------------------------------ pure Kotlin (PhononAsrTest)

    internal const val RATE = 16_000

    /** Seconds per encoder frame: subsampling 8 x hop 160 samples at 16 kHz (phonon2.h, docs/android.md). */
    internal const val FRAME_S = 8 * 160 / 16_000.0

    /** Samples per level frame when cutting windows (20 ms). */
    internal const val LEVEL_FRAME = 320

    /** The longest window [transcribeLong] decodes at once, in samples. */
    internal const val WINDOW = 30 * RATE

    internal fun padSamples(leadPadSec: Double): Int = Math.round(leadPadSec * RATE).toInt()

    /** The special pieces left out of the text: `<unk>`, `<pad>` and `<|...|>`. */
    internal fun special(piece: String) = piece == "<unk>" || piece == "<pad>" || piece.startsWith("<|")

    /** A piece with no letter or digit (".", ","): it joins the word before it even after a "▁" (Fermion's segment.py). */
    private fun punctuation(piece: String) = piece.isNotEmpty() && piece.none { it.isLetterOrDigit() }

    /**
     * Greek final sigma (Fermion's engine.py): "σ" not followed by a letter becomes "ς". Python's `[^\W\d_]` is a
     * letter or a non-decimal number.
     */
    private val finalSigmaRule = Regex("σ(?![\\p{L}\\p{Nl}\\p{No}])")

    internal fun finalSigma(text: String): String = if ('σ' in text) finalSigmaRule.replace(text, "ς") else text

    /**
     * Decoder triples ([id, frame, duration] per token, frames and durations in 80 ms encoder frames) -> words.
     *
     * A piece starting with "▁" starts a word, unless it is only punctuation (then it stays with the word before);
     * special pieces are dropped. A token spans [frame, frame + duration] x 80 ms, both moved back by [padSec] (the
     * leading silence that was prepended) and clamped at 0, as Fermion's engine.py does. A word starts where its
     * first piece starts and ends where its last piece ends, clamped to [limitSec] (the audio's length: the last
     * duration can run up to a frame past it) and never before its start. With [finalSigma] the Greek rule is applied.
     */
    internal fun words(
        triples: IntArray,
        vocabulary: List<String>,
        padSec: Double,
        limitSec: Double,
        finalSigma: Boolean,
    ): List<Word> {
        val out = ArrayList<Word>()
        val text = StringBuilder()
        var start = 0.0
        var end = 0.0
        fun flush() {
            val t = text.toString().trim()
            if (t.isNotEmpty()) {
                val e = maxOf(start, minOf(end, limitSec))
                out += Word(if (finalSigma) finalSigma(t) else t, start, e)
            }
            text.setLength(0)
        }
        var i = 0
        while (i + 2 < triples.size) {
            val piece = vocabulary.getOrNull(triples[i])
            val frame = triples[i + 1]
            val duration = triples[i + 2]
            i += 3
            if (piece == null || special(piece)) continue
            val p = piece.replace('▁', ' ')
            val s = maxOf(0.0, frame * FRAME_S - padSec)
            val e = maxOf(s, (frame + duration) * FRAME_S - padSec)
            if (p.startsWith(' ') && text.isNotEmpty() && (p.isBlank() || !punctuation(p.trim()))) flush()
            if (text.isEmpty()) start = s
            text.append(p)
            end = e
        }
        flush()
        return out
    }

    /**
     * Window bounds for the first [n] samples: [0, cut1, ..., n], each window at most 30 s. While more than 30 s is
     * left, the cut is the start of the quietest 20 ms frame (frames counted from the window's start) in the last
     * third of the window, or the window's end if none is quieter (AsrBridge.whole).
     */
    internal fun windows(pcm: ShortArray, n: Int): IntArray {
        val bounds = ArrayList<Int>()
        bounds += 0
        var start = 0
        while (n - start > WINDOW) {
            val lo = (WINDOW * 2 / 3) / LEVEL_FRAME
            val hi = WINDOW / LEVEL_FRAME
            var cut = hi
            var quietest = level(pcm, start + hi * LEVEL_FRAME, n)
            for (f in lo until hi) {
                val l = level(pcm, start + f * LEVEL_FRAME, n)
                if (l < quietest) {
                    quietest = l
                    cut = f
                }
            }
            start += cut * LEVEL_FRAME
            bounds += start
        }
        bounds += n
        return bounds.toIntArray()
    }

    /** Mean square of the 20 ms frame at [from] (fewer samples at the end of the audio). */
    private fun level(pcm: ShortArray, from: Int, n: Int): Double {
        val to = minOf(from + LEVEL_FRAME, n)
        if (to <= from) return 0.0
        var sum = 0.0
        for (i in from until to) sum += pcm[i].toDouble() * pcm[i]
        return sum / (to - from)
    }

    @JvmStatic private external fun nativeEngine(): String?
    @JvmStatic private external fun nativeLoad(path: String, index: String, threads: Int, error: Array<String?>): Long
    @JvmStatic private external fun nativeTranscribe(handle: Long, pcm: ShortArray, n: Int): IntArray?
    @JvmStatic private external fun nativeRelease(handle: Long)
}
