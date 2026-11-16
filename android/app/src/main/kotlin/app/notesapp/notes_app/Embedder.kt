package app.notesapp.notes_app

import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.EmbeddingEngine
import com.google.ai.edge.litertlm.EmbeddingEngineConfig
import com.google.ai.edge.litertlm.EmbeddingOptions
import com.google.ai.edge.litertlm.InputData
import java.io.File
import java.util.Timer
import kotlin.concurrent.schedule

/**
 * EmbeddingGemma 2 (Google, Apache-2.0), text and pictures in one space, for search by meaning: on the phone, through
 * LiteRT-LM, with the downloaded embeddinggemma-2-text-vision-440m.litertlm. Vectors come normalized, cut to
 * [SIZE] (its Matryoshka sizes keep nearly all their quality at 256). The callers add the model's prompts
 * ("task: search result | query: ..." for a query, "title: ... | text: ..." for what is searched); pictures go in
 * as they are. The engine (~300 MB) is let go after a minute without work.
 */
class Embedder(private val cacheDir: File) {
    private var engine: EmbeddingEngine? = null
    private var loadedFrom: String? = null
    private var idle: java.util.TimerTask? = null
    private val timer = Timer("embedder-idle", true)

    @Synchronized
    private fun engine(model: String): EmbeddingEngine {
        idle?.cancel()
        idle = timer.schedule(IDLE_MS) { close() }
        engine?.let { if (loadedFrom == model) return it }
        close()
        // LiteRT-LM refuses a cache folder that is not there yet.
        cacheDir.mkdirs()
        val e = EmbeddingEngine(
            EmbeddingEngineConfig(
                modelPath = model,
                backend = Backend.CPU(),
                visionBackend = Backend.CPU(),
                cacheDir = cacheDir.absolutePath,
            ),
        )
        e.initialize()
        engine = e
        loadedFrom = model
        return e
    }

    /** One vector per text, in order. */
    @Synchronized
    fun texts(directory: String, texts: List<String>): List<FloatArray> {
        val e = engine(model(directory))
        return texts.chunked(BATCH).flatMap { batch ->
            e.computeEmbeddingBatch(batch.map { listOf(InputData.Text(it)) }, OPTIONS).map { it.embedding }
        }
    }

    /** The vector of a picture ([bytes]: a JPEG, PNG or another format the engine decodes). */
    @Synchronized
    fun image(directory: String, bytes: ByteArray): FloatArray =
        engine(model(directory)).computeEmbedding(listOf(InputData.Image(bytes)), OPTIONS).embedding

    @Synchronized
    fun close() {
        idle?.cancel()
        idle = null
        engine?.close()
        engine = null
        loadedFrom = null
    }

    private fun model(directory: String) = "$directory/$FILE"

    companion object {
        const val FILE = "embeddinggemma-2-text-vision-440m.litertlm"
        const val SIZE = 256
        private const val BATCH = 16
        private const val IDLE_MS = 60_000L
        private val OPTIONS = EmbeddingOptions(normalize = true, outputSize = SIZE)
    }
}
