package app.notesapp.notes_app

import ai.desertant.align.Align
import ai.desertant.align.WordTiming
import ai.desertant.title.Title
import android.content.Context

/**
 * The two models Desert Ant ships for Apple only, ported to Android in
 * third_party/desert-ant-core: Align (tighter word times, branch android-align) and Title
 * (a note's title and a one-line description, branch android-title). Each runs only from
 * its offline folder; without it the notes do without: Voz's own word times, and a title
 * taken from the text.
 */
class Extras(
    private val context: Context,
    private val offline: OfflineModels,
    /** Closes the bridge's heavy models: one heavy model in memory at a time (DesertAntBridge.model). */
    private val releaseOthers: () -> Unit,
) {
    private var align: Align? = null
    private var titler: Title? = null

    @Synchronized
    private fun aligner(): Align? {
        align?.let { return it }
        val dir = offline.directory("align") ?: return null
        releaseOthers()
        titler?.close()
        titler = null
        return Align(context, dir).also { align = it }
    }

    @Synchronized
    private fun titler(): Title? {
        titler?.let { return it }
        val dir = offline.directory("title") ?: return null
        releaseOthers()
        align?.close()
        align = null
        return Title(context, dir).also { titler = it }
    }

    /** Close Align and Title (another heavy model is about to load). */
    @Synchronized
    fun release() {
        align?.close()
        align = null
        titler?.close()
        titler = null
    }

    val canAlign: Boolean get() = offline.isReady("align")
    val canTitle: Boolean get() = offline.isReady("title")

    /**
     * Refined [words] ([text, start, end]), or null when Align cannot run or does not know
     * [language] (it has nine: de en es fr it ja ko pt zh). Words it could not safely improve
     * keep their times, so a refinement only helps or leaves a word alone.
     */
    suspend fun align(samples: FloatArray, rate: Int, words: List<List<Any>>, language: String): List<List<Any>>? {
        if (words.isEmpty() || !Align.isSupported(language)) return null
        val aligner = aligner() ?: return null
        val input = words.map { WordTiming(it[0] as String, (it[1] as Number).toDouble(), (it[2] as Number).toDouble()) }
        val out = aligner.refine(samples, rate.toDouble(), input, language)
        return out.map { listOf(it.text, it.start, it.end, it.refined) }
    }

    /**
     * {title, description}: a plain 3-8 word title and a one- or two-sentence description, in
     * the passage's own language; null when Title cannot run or wrote nothing.
     */
    suspend fun title(text: String): Map<String, String>? {
        val card = titler()?.describe(text) ?: return null
        if (card.isEmpty) return null
        return mapOf("title" to card.title, "description" to card.description)
    }
}
