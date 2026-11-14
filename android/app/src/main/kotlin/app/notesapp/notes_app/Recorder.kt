package app.notesapp.notes_app

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * The microphone into a raw file: 48 kHz mono 16-bit little-endian PCM, the rate Clear works
 * at, so the enhancer needs no resampling. Hold pauses (nothing is written while held), the
 * level drives the record screen's glow, and nothing leaves the phone.
 *
 * VOICE_RECOGNITION asks the platform for audio without automatic gain or heavy noise
 * suppression: Clear does the cleanup, and pumping AGC would only give it more to undo.
 */
class Recorder {
    companion object {
        const val SAMPLE_RATE = 48_000
    }

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var paused = false
    @Volatile private var samples = 0L
    @Volatile private var level = 0.0
    @Volatile private var failure: String? = null
    var file: File? = null
        private set

    /** Every block recorded (48 kHz mono floats, on the recorder's thread): the live transcript's feed. */
    @Volatile var onAudio: ((FloatArray) -> Unit)? = null

    val elapsedMs: Long get() = samples * 1000 / SAMPLE_RATE
    val isRecording: Boolean get() = running
    val isPaused: Boolean get() = paused

    /** 0..1, how loud the microphone hears it now. */
    val micLevel: Double get() = if (paused) 0.0 else level

    /** Why recording stopped by itself, if it did. */
    val problem: String? get() = failure

    @SuppressLint("MissingPermission") // asked for by MainActivity before this runs
    fun start(target: File) {
        stop()
        val min = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) throw IllegalStateException("this phone cannot record 48 kHz mono audio")
        val r = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(min * 4, SAMPLE_RATE), // half a second of headroom
        )
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            throw IllegalStateException("the microphone could not be opened")
        }
        target.parentFile?.mkdirs()
        file = target
        samples = 0
        failure = null
        paused = false
        running = true
        record = r
        r.startRecording()
        thread = Thread({ pump(r, target) }, "recorder").apply { start() }
    }

    private fun pump(r: AudioRecord, target: File) {
        val buffer = ShortArray(SAMPLE_RATE / 20) // 50 ms
        val bytes = ByteArray(buffer.size * 2)
        try {
            BufferedOutputStream(FileOutputStream(target), 1 shl 16).use { out ->
                while (running) {
                    val n = r.read(buffer, 0, buffer.size)
                    if (n < 0) throw IllegalStateException("the microphone stopped (error $n)")
                    if (n == 0 || paused) continue
                    var sum = 0.0
                    for (i in 0 until n) {
                        val s = buffer[i].toInt()
                        bytes[2 * i] = (s and 0xff).toByte()
                        bytes[2 * i + 1] = (s shr 8 and 0xff).toByte()
                        sum += (s * s).toDouble()
                    }
                    out.write(bytes, 0, n * 2)
                    samples += n
                    onAudio?.let { tap -> tap(FloatArray(n) { buffer[it] / 32768f }) }
                    // dBFS of the block, -60..0 mapped to 0..1.
                    val rms = sqrt(sum / n) / 32768.0
                    val db = if (rms > 0) 20 * log10(rms) else -100.0
                    level = ((db + 60) / 60).coerceIn(0.0, 1.0)
                }
            }
        } catch (e: Exception) {
            failure = e.message ?: "recording stopped"
            running = false
        }
    }

    fun pause() {
        paused = true
        level = 0.0
    }

    fun resume() {
        paused = false
    }

    /** Stop and close the file; returns it with its length in ms, or null when nothing was recording. */
    fun stop(): Pair<File, Long>? {
        val r = record ?: return null
        running = false
        try {
            r.stop()
        } catch (_: IllegalStateException) {
            // Already stopped.
        }
        thread?.join(2000)
        r.release()
        record = null
        thread = null
        level = 0.0
        val f = file ?: return null
        return f to elapsedMs
    }
}
