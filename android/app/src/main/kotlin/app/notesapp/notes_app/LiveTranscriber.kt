package app.notesapp.notes_app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Words while they are said, for the record screen: Desert Ant's Voz live session, which the
 * SDK ships for Apple only (Sources/Voz/Live.swift, `LiveTranscriber`), ported rule for rule.
 *
 * Voz reads a fixed 15 s window, so it cannot decode a frame at a time; instead the audio not
 * yet settled is transcribed again on every pass, and its words shown as tentative. A word two
 * passes in a row agree on (same text, same place, give or take [agreementTolerance]) is
 * settled: more context did not change it, so it will not change. Once the held audio passes
 * [commitAfter], anything [holdback] behind "now" is settled anyway, and the audio behind the
 * settled words is let go at the quietest moment near them, so a pass never outgrows the window.
 *
 * On Android a pass takes about 2 s whatever its length (measured on a Snapdragon 888), so with
 * the default 1 s [updateInterval] the passes simply run back to back while there is new audio.
 * The final transcript is not this: after Save the cleaned recording is transcribed whole.
 */
class LiveTranscriber(
    private val scope: CoroutineScope,
    /** One Voz pass over 16 kHz samples: words with times relative to them; null when it could not run now. */
    private val transcribe: suspend (FloatArray) -> List<Word>?,
    /** Settled words, then tentative ones, after every pass (on the pass's thread). */
    private val onUpdate: (settled: List<Word>, tentative: List<Word>) -> Unit,
    private val updateInterval: Double = 1.0,
    private val commitAfter: Double = 10.0,
    private val holdback: Double = 3.0,
    private val agreementTolerance: Double = 0.25,
) {
    data class Word(val text: String, val start: Double, val end: Double)

    private val rate = 16_000.0
    private val lock = Any()

    // All below guarded by [lock].
    private var buffer = FloatArray(0)
    private var bufferStart = 0.0
    private val committed = ArrayList<Word>()
    private var committedEnd = 0.0
    private var previous: List<Word> = emptyList()
    private var samplesSinceRun = 0
    private var running = false
    private var stopped = false
    private var job: Job? = null

    /** Captured audio, 16 kHz mono. */
    fun append(samples: FloatArray) {
        if (samples.isEmpty()) return
        synchronized(lock) {
            if (stopped) return
            buffer += samples
            samplesSinceRun += samples.size
        }
        runIfDue()
    }

    /** Seconds of audio held for the next pass (tests: it must stay bounded). */
    fun heldSeconds(): Double = synchronized(lock) { buffer.size / rate }

    /** Whether a pass is under way (tests wait for it). */
    fun busy(): Boolean = synchronized(lock) { running }

    /** No more audio; nothing more is shown (the saved recording is transcribed whole instead). */
    fun stop() {
        synchronized(lock) { stopped = true }
        job?.cancel()
    }

    private fun runIfDue() {
        synchronized(lock) {
            if (running || stopped || samplesSinceRun / rate < updateInterval) return
            running = true
            samplesSinceRun = 0
        }
        job = scope.launch { runOnce() }
    }

    private suspend fun runOnce() {
        // Snapshot: append may extend the buffer while the pass is away; those samples are the next pass's.
        val samples: FloatArray
        val start: Double
        synchronized(lock) {
            samples = buffer
            start = bufferStart
        }
        val heard = try {
            transcribe(samples)
        } catch (e: Exception) {
            null // a failed pass is retried by the next one, with more audio
        }
        if (heard == null) {
            synchronized(lock) { running = false }
            runIfDue()
            return
        }
        val words = heard.map { Word(it.text, it.start + start, it.end + start) }
        val settled: List<Word>
        val tentative: List<Word>
        synchronized(lock) {
            if (stopped) return
            // The pass re-read audio behind committedEnd for context; its words there are spoken for.
            val fresh = words.filter { it.start >= committedEnd - agreementTolerance / 2 }
            val stable = agreedPrefix(previous, fresh).toMutableList()
            // The safety valve: audio the passes keep disagreeing about must not pin the tail
            // against the window; well behind "now", the latest reading wins.
            val duration = samples.size / rate
            if (duration > commitAfter) {
                val deadline = start + duration - holdback
                for (w in fresh.drop(stable.size)) if (w.end <= deadline) stable += w
            }
            if (stable.isNotEmpty()) {
                committed += stable
                committedEnd = stable.last().end
            }
            previous = fresh.drop(stable.size)
            release(samples, start)
            settled = committed.toList()
            tentative = previous
            running = false
        }
        onUpdate(settled, tentative)
        // Audio that arrived during the pass may already be due.
        runIfDue()
    }

    /** The words at the front of [current] that [earlier] already gave: same text, same place. */
    private fun agreedPrefix(earlier: List<Word>, current: List<Word>): List<Word> {
        val out = ArrayList<Word>()
        for ((a, b) in earlier.zip(current)) {
            if (a.text != b.text || abs(a.start - b.start) > agreementTolerance) break
            out += b
        }
        return out
    }

    /** Let go of audio behind the settled words once the held audio is long, at a quiet moment. */
    private fun release(samples: FloatArray, start: Double) {
        val duration = samples.size / rate
        if (duration <= commitAfter || committedEnd <= start) return
        val cut = min(quietestPoint(samples, committedEnd - start) + start, committedEnd)
        val drop = min(((cut - start) * rate).toInt(), buffer.size)
        if (drop <= 0) return
        buffer = buffer.copyOfRange(drop, buffer.size)
        bufferStart += drop / rate
    }

    /** The quietest 20 ms within a second either side of [at] (seconds into [samples]). */
    private fun quietestPoint(samples: FloatArray, at: Double): Double {
        val frame = max(1, (0.02 * rate).toInt())
        val first = max(0, ((at - 1) * rate).toInt())
        val last = min(samples.size - frame, ((at + 1) * rate).toInt())
        if (last <= first) return at
        var bestAt = (at * rate).toInt()
        var best = Float.MAX_VALUE
        var i = first
        while (i + frame <= last) {
            var sum = 0f
            for (k in i until i + frame) sum += samples[k] * samples[k]
            if (sum < best) {
                best = sum
                bestAt = i + frame / 2
            }
            i += frame
        }
        return bestAt / rate
    }
}
