package app.notesapp.notes_app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The live session's rules (ported from Desert Ant's Swift LiveTranscriber) against a fake Voz:
 * scripted speech, a word every 0.4 s for 60 s. A pass sees only its samples, each carrying its
 * absolute index, so the fake knows which words fall in the window; the newest word, still
 * being said, comes out wrong ("word?"), as a real pass's last word does.
 */
class LiveTranscriberTest {
    private val rate = 16_000

    private val script = (0 until 150).map { i ->
        LiveTranscriber.Word("w$i", i * 0.4 + 0.05, i * 0.4 + 0.35)
    }

    private suspend fun fakeVoz(samples: FloatArray): List<LiveTranscriber.Word> {
        delay(5) // a pass takes time
        val start = samples.first().toDouble() / rate
        val end = start + samples.size.toDouble() / rate
        return script.filter { it.start >= start && it.end <= end }.map { w ->
            val unstable = end - w.end < 0.5
            LiveTranscriber.Word(if (unstable) "${w.text}?" else w.text, w.start - start, w.end - start)
        }
    }

    @Test
    fun settlesWordsInOrderAndKeepsTheHeldAudioBounded() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var settled = emptyList<LiveTranscriber.Word>()
        var tentative = emptyList<LiveTranscriber.Word>()
        val live = LiveTranscriber(scope, ::fakeVoz, { s, t -> settled = s; tentative = t })
        var maxHeld = 0.0
        var index = 0
        val block = rate / 20 // 50 ms, as the recorder hands them over
        while (index < 60 * rate) {
            live.append(FloatArray(block) { (index + it).toFloat() })
            index += block
            // Real time is not needed: let each due pass finish before more audio comes.
            while (live.busy()) delay(1)
            maxHeld = maxOf(maxHeld, live.heldSeconds())
        }
        live.stop()

        val texts = settled.map { it.text }
        // Settled words are the script's, in order, each once, never a mid-speech reading.
        assertEquals(script.take(texts.size).map { it.text }, texts)
        assertTrue("most of a minute of speech is settled (${texts.size})", texts.size > 130)
        // The held audio never outgrows the model's 15 s window.
        assertTrue("held at most $maxHeld s", maxHeld < 15.0)
        // What is not settled yet is the latest speech.
        assertTrue(tentative.isNotEmpty() && tentative.first().start >= settled.last().end - 0.2)
    }
}
