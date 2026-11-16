package app.notesapp.notes_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.TensorBuffer
import java.io.ByteArrayInputStream
import java.io.File
import java.util.Timer
import kotlin.concurrent.schedule
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * EmbeddingGemma 2 (Google, Apache-2.0), text and pictures in one space, for search by meaning: its LiteRT graphs run
 * on the app's one LiteRT (libLiteRt.so, shared with Desert Ant's models), no runtime of its own. The downloaded model
 * is kept cut up (OfflineModels): each graph in a folder with its weights beside it as 'tflite_weights', where LiteRT
 * finds them; the tokenizer and the end-of-image graph at the top. This does what LiteRT-LM's embedding engine does
 * with them (runtime/core/embedding_engine_impl.cc): text vectors are the very same, pictures' within 0.01 (LiteRT-LM
 * runs the vision graph in fp16, this in fp32). Vectors come cut to [SIZE] and normalized. The callers add the model's
 * prompts ("task: search result | query: ..." for a query, "title: ... | text: ..." for what is searched). Everything
 * is let go after a minute without work.
 */
class Embedder(@Suppress("unused") private val cacheDir: File) {
    private var models: Models? = null
    private var idle: java.util.TimerTask? = null
    private val timer = Timer("embedder-idle", true)

    @Synchronized
    private fun models(directory: String): Models {
        idle?.cancel()
        idle = timer.schedule(IDLE_MS) { close() }
        models?.let { if (it.dir == directory) return it }
        close()
        return Models(directory).also { models = it }
    }

    /** One vector per text, in order. */
    @Synchronized
    fun texts(directory: String, texts: List<String>): List<FloatArray> {
        val m = models(directory)
        return texts.map { text -> m.encode(m.tokenRows(intArrayOf(BOS) + m.tokenizer.encode(text) + intArrayOf(EOS))) }
    }

    /** The vector of a picture ([bytes]: any format Android decodes). */
    @Synchronized
    fun image(directory: String, bytes: ByteArray): FloatArray {
        val m = models(directory)
        val soft = m.picture(bytes)
        val rows = ArrayList<FloatArray>(soft.size + 4)
        rows += m.tokenRow(BOS)
        rows += m.tokenRow(m.startOfImage)
        rows += soft
        rows += m.endOfImage
        rows += m.tokenRow(EOS)
        return m.encode(rows)
    }

    @Synchronized
    fun close() {
        idle?.cancel()
        idle = null
        models?.close()
        models = null
    }

    /** The graphs of the model in [dir], each loaded on first use. */
    private class Models(val dir: String) : AutoCloseable {
        init {
            // The LiteRT Kotlin API's JNI; it opens libLiteRt.so, the copy the app already loads.
            System.loadLibrary("litert_jni")
        }

        val tokenizer by lazy { SentencePiece.load(File(dir, "tokenizer.spm")) }
        val startOfImage by lazy { tokenizer.idOf("<|image>") ?: error("no <|image> token") }
        private val options = CompiledModel.Options(Accelerator.CPU)
        private val opened = ArrayList<AutoCloseable>()
        private fun open(path: String) = CompiledModel.create("$dir/$path", options).also { opened += it }

        private val embedder by lazy { open("embedder/model.tflite") }
        private val textEncoder by lazy { open("text_encoder/model.tflite") }
        private val visionEncoder by lazy { open("vision_encoder/model.tflite") }
        private val visionAdapter by lazy { open("vision_adapter/model.tflite") }

        /** What follows a picture's tokens (the end-of-image graph's one row). */
        val endOfImage: FloatArray by lazy {
            open("end_of_vision.tflite").use { eov ->
                val out = eov.createOutputBuffer("eoi_embedding", "eoi")
                eov.run(emptyMap(), mapOf("eoi_embedding" to out), "eoi")
                out.readFloat().also { out.close() }
            }
        }

        private val tokenIn by lazy { embedder.createInputBuffer("token_ids", "embedder_1x1") }
        private val tokenOut by lazy { embedder.createOutputBuffer("embeddings", "embedder_1x1") }

        /** Token [id]'s row (the embedder's lookup). */
        fun tokenRow(id: Int): FloatArray {
            tokenIn.writeInt(intArrayOf(id))
            embedder.run(mapOf("token_ids" to tokenIn), mapOf("embeddings" to tokenOut), "embedder_1x1")
            return tokenOut.readFloat()
        }

        fun tokenRows(ids: IntArray): List<FloatArray> = ids.map(::tokenRow)

        /** The text encoder's buffers by signature: built once each. */
        private val encoderBuffers = HashMap<String, Triple<TensorBuffer, TensorBuffer, TensorBuffer>>()

        /** [rows] (the sequence, each a token's or a picture token's row) as the model's vector. */
        fun encode(rows: List<FloatArray>): FloatArray {
            val length = TEXT_LENGTHS.firstOrNull { it >= rows.size }
                ?: throw IllegalArgumentException("too long: ${rows.size} tokens")
            val signature = "encoder_1x$length"
            val (emb, mask, out) = encoderBuffers.getOrPut(signature) {
                Triple(
                    textEncoder.createInputBuffer("embeddings", signature),
                    textEncoder.createInputBuffer("input_mask", signature),
                    textEncoder.createOutputBuffer("encodings", signature),
                )
            }
            val e = FloatArray(length * WIDTH)
            for ((i, r) in rows.withIndex()) System.arraycopy(r, 0, e, i * WIDTH, WIDTH)
            val m = FloatArray(length).also { it.fill(1f, 0, rows.size) }
            emb.writeFloat(e)
            mask.writeFloat(m)
            textEncoder.run(mapOf("embeddings" to emb, "input_mask" to mask), mapOf("encodings" to out), signature)
            return unit(out.readFloat())
        }

        /** A picture as the rows of its tokens: patches through the vision encoder, then the adapter. */
        fun picture(bytes: ByteArray): List<FloatArray> {
            val (patches, positions) = patchify(bytes)
            val images = visionEncoder.createInputBuffer("images", VISION)
            val pos = visionEncoder.createInputBuffer("positions_xy", VISION)
            val features = visionEncoder.createOutputBuffer("features", VISION)
            val mask = visionEncoder.createOutputBuffer("mask", VISION)
            val soft = visionAdapter.createInputBuffer("soft_tokens", ADAPTER)
            val mm = visionAdapter.createOutputBuffer("mm_embedding", ADAPTER)
            try {
                images.writeFloat(patches)
                pos.writeInt(positions)
                visionEncoder.run(mapOf("images" to images, "positions_xy" to pos),
                    mapOf("features" to features, "mask" to mask), VISION)
                val valid = mask.readBoolean().count { it }
                soft.writeFloat(features.readFloat())
                visionAdapter.run(mapOf("soft_tokens" to soft), mapOf("mm_embedding" to mm), ADAPTER)
                val all = mm.readFloat()
                return List(valid) { all.copyOfRange(it * WIDTH, (it + 1) * WIDTH) }
            } finally {
                listOf(images, pos, features, mask, soft, mm).forEach { it.close() }
            }
        }

        override fun close() {
            encoderBuffers.values.forEach { (a, b, c) -> a.close(); b.close(); c.close() }
            if (opened.isNotEmpty()) {
                // Lazily made buffers belong to the embedder: closed before it.
                runCatching { tokenIn.close(); tokenOut.close() }
            }
            opened.forEach { runCatching { it.close() } }
            opened.clear()
        }
    }

    companion object {
        const val SIZE = 256
        private const val WIDTH = 512
        private const val BOS = 2
        private const val EOS = 1
        private val TEXT_LENGTHS = intArrayOf(128, 256, 512, 1024, 2048, 8192)
        private const val VISION = "vision_140"
        private const val ADAPTER = "vision_adapter_140"
        private const val IDLE_MS = 60_000L

        // The picture preprocessing EmbeddingGemma 2's metadata asks for: 16 px patches, at most 1260 of them, sides
        // multiples of 3 patches (its 3x3 pooling).
        private const val PATCH = 16
        private const val POOL = 3
        private const val MAX_PATCHES = 1260

        /** The first [SIZE] components, normalized. */
        internal fun unit(v: FloatArray): FloatArray {
            val out = v.copyOf(SIZE)
            val norm = sqrt(out.fold(0.0) { s, x -> s + x * x }).toFloat()
            if (norm > 0) for (i in out.indices) out[i] /= norm
            return out
        }

        /** The size a [w] x [h] picture is resized to (LiteRT-LM's GetAspectRatioPreservingSize). */
        internal fun targetSize(w: Int, h: Int): Pair<Int, Int> {
            val factor = sqrt(MAX_PATCHES.toDouble() * PATCH * PATCH / (w.toDouble() * h))
            val side = POOL * PATCH
            var th = floor(factor * h / side).toInt() * side
            var tw = floor(factor * w / side).toInt() * side
            val most = (MAX_PATCHES / (POOL * POOL)) * side
            if (th == 0) {
                th = side
                tw = min(floor(w.toDouble() / h).toInt() * side, most)
            } else if (tw == 0) {
                tw = side
                th = min(floor(h.toDouble() / w).toInt() * side, most)
            }
            return tw to th
        }

        /** [bytes] decoded upright, resized, in 16 px patches (padded to [MAX_PATCHES]) with their x, y (-1 padding). */
        private fun patchify(bytes: ByteArray): Pair<FloatArray, IntArray> {
            val bitmap = decode(bytes) ?: throw IllegalArgumentException("not a picture Android can read")
            val (tw, th) = targetSize(bitmap.width, bitmap.height)
            val src = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(src, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            val pixels = resize(src, bitmap.width, bitmap.height, tw, th)
            bitmap.recycle()
            val gw = tw / PATCH
            val gh = th / PATCH
            val dim = PATCH * PATCH * 3
            val patches = FloatArray(MAX_PATCHES * dim)
            val positions = IntArray(MAX_PATCHES * 2) { -1 }
            var k = 0
            for (y in 0 until gh) for (x in 0 until gw) {
                var o = k * dim
                for (py in 0 until PATCH) for (px in 0 until PATCH) {
                    val p = ((y * PATCH + py) * tw + x * PATCH + px) * 3
                    patches[o++] = pixels[p] / 255f
                    patches[o++] = pixels[p + 1] / 255f
                    patches[o++] = pixels[p + 2] / 255f
                }
                positions[k * 2] = x
                positions[k * 2 + 1] = y
                k++
            }
            return patches to positions
        }

        /** [bytes] decoded and turned upright (EXIF); shrunk on decode only while it stays well above what is kept. */
        private fun decode(bytes: ByteArray): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val (tw, th) = targetSize(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 4 * tw && bounds.outHeight / (sample * 2) >= 4 * th) sample *= 2
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }) ?: return null
            val turn = try {
                when (ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } catch (_: Exception) {
                0f
            }
            if (turn == 0f) return bitmap
            val upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(turn) }, true)
            if (upright !== bitmap) bitmap.recycle()
            return upright
        }

        private val toLinear = FloatArray(256) { i ->
            val c = i / 255.0
            (if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)).toFloat()
        }

        private fun toSrgb(c: Float): Int {
            val l = c.coerceIn(0f, 1f).toDouble()
            val s = if (l <= 0.0031308) l * 12.92 else 1.055 * l.pow(1 / 2.4) - 0.055
            return floor(s * 255 + 0.5).toInt().coerceIn(0, 255)
        }

        private fun catmullRom(x: Double): Double {
            val a = kotlin.math.abs(x)
            return when {
                a < 1 -> 1.5 * a * a * a - 2.5 * a * a + 1
                a < 2 -> -0.5 * a * a * a + 2.5 * a * a - 4 * a + 2
                else -> 0.0
            }
        }

        /** For each of [nOut] samples along an axis of [nIn]: the first source index and the weights (edges clamped). */
        private fun kernel(nIn: Int, nOut: Int): List<Pair<IntArray, FloatArray>> {
            val scale = nOut.toDouble() / nIn
            val support = 2.0 / min(scale, 1.0)
            return List(nOut) { o ->
                val center = (o + 0.5) / scale
                val lo = floor(center - support).toInt()
                val hi = ceil(center + support).toInt()
                val idx = IntArray(hi - lo + 1) { (lo + it).coerceIn(0, nIn - 1) }
                val w = DoubleArray(hi - lo + 1) { catmullRom((lo + it + 0.5 - center) * min(scale, 1.0)) }
                val sum = w.sum()
                idx to FloatArray(w.size) { (w[it] / sum).toFloat() }
            }
        }

        /**
         * [src] (ARGB, [w] x [h]) resized to [tw] x [th], as RGB bytes 0..255: in linear light, Catmull-Rom, edges
         * clamped (what stb_image_resize does for LiteRT-LM with an sRGB picture).
         */
        internal fun resize(src: IntArray, w: Int, h: Int, tw: Int, th: Int): IntArray {
            val kx = kernel(w, tw)
            val ky = kernel(h, th)
            // Across: rows of the source to rows of the target width (linear light).
            val across = FloatArray(h * tw * 3)
            val line = FloatArray(w * 3)
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val p = src[y * w + x]
                    line[x * 3] = toLinear[(p shr 16) and 0xff]
                    line[x * 3 + 1] = toLinear[(p shr 8) and 0xff]
                    line[x * 3 + 2] = toLinear[p and 0xff]
                }
                for (x in 0 until tw) {
                    val (idx, wt) = kx[x]
                    var r = 0f
                    var g = 0f
                    var b = 0f
                    for (t in idx.indices) {
                        val s = idx[t] * 3
                        r += line[s] * wt[t]
                        g += line[s + 1] * wt[t]
                        b += line[s + 2] * wt[t]
                    }
                    val o = (y * tw + x) * 3
                    across[o] = r
                    across[o + 1] = g
                    across[o + 2] = b
                }
            }
            // Down: to the target height, then back to sRGB.
            val out = IntArray(th * tw * 3)
            for (y in 0 until th) {
                val (idx, wt) = ky[y]
                for (x in 0 until tw) {
                    var r = 0f
                    var g = 0f
                    var b = 0f
                    for (t in idx.indices) {
                        val s = (idx[t] * tw + x) * 3
                        r += across[s] * wt[t]
                        g += across[s + 1] * wt[t]
                        b += across[s + 2] * wt[t]
                    }
                    val o = (y * tw + x) * 3
                    out[o] = toSrgb(r)
                    out[o + 1] = toSrgb(g)
                    out[o + 2] = toSrgb(b)
                }
            }
            return out
        }
    }
}
