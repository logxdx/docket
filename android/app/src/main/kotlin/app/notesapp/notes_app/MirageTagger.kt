package app.notesapp.notes_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream

/**
 * Mirage (Cactus Compute), the picture tagger: what is in a picture and the text it can read, kept by the app as
 * hidden search terms (never written into a note). Runs on the phone, in libmirage_jni.so (Cactus's engine linked in;
 * tool/build_mirage_jni.sh), with the downloaded mirage.cact. One picture at a time: the engine holds one session.
 */
object MirageTagger {
    @JvmStatic private external fun nativeLoad(path: String): String?
    @JvmStatic private external fun nativeThreads(threads: Int)
    @JvmStatic private external fun nativeDescribe(rgb: ByteArray, width: Int, height: Int, options: String): String?
    @JvmStatic private external fun nativeError(): String

    /** Only what tagging needs; one mask per object (they cannot be turned off) keeps the answer small. */
    private const val OPTIONS = """{"sections":["scene","objects","text","reasoning"],"mask_format":"largest"}"""

    /** The longest side a picture is shrunk to: Mirage reads at 512 px, text needs a little more. */
    private const val SIDE = 1024

    /** Confidence below which an object or a line read is left out. */
    private const val MIN_SCORE = 0.3

    private var loadedFrom: String? = null

    /**
     * Tag the picture in [bytes] (any format Android decodes) with the model in [directory]: the things in it, the
     * text read from it, and a one-line description. Throws with what went wrong.
     */
    @Synchronized
    fun tag(directory: String, bytes: ByteArray): Map<String, Any> {
        val model = "$directory/mirage.cact"
        if (loadedFrom == null) {
            System.loadLibrary("mirage_jni")
            nativeLoad(model)?.let { throw IllegalStateException("Mirage did not load: $it") }
            nativeThreads(4)
            loadedFrom = model
        }
        val bitmap = decode(bytes) ?: throw IllegalArgumentException("not a picture Android can read")
        val rgb = ByteArray(bitmap.width * bitmap.height * 3)
        val row = IntArray(bitmap.width)
        for (y in 0 until bitmap.height) {
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            var o = y * bitmap.width * 3
            for (p in row) {
                rgb[o++] = (p shr 16).toByte()
                rgb[o++] = (p shr 8).toByte()
                rgb[o++] = p.toByte()
            }
        }
        val out = nativeDescribe(rgb, bitmap.width, bitmap.height, OPTIONS)
            ?: throw IllegalStateException("Mirage failed: ${nativeError()}")
        bitmap.recycle()
        return read(out)
    }

    /** The engine's answer as tags. It sometimes writes a score as -nan, which is not JSON: read as no score. */
    internal fun read(answer: String): Map<String, Any> {
        val json = JSONObject(answer.replace(Regex("""(?<=[:\[,])\s*-?nan\b"""), "null"))
        fun scored(o: JSONObject) = o.isNull("score") || o.optDouble("score", 1.0) >= MIN_SCORE
        val objects = linkedSetOf<String>()
        json.optJSONArray("objects")?.forEachObject { o ->
            val name = o.optString("name").trim()
            if (name.isNotEmpty() && name != "text" && scored(o)) objects += name
        }
        val text = mutableListOf<String>()
        json.optJSONArray("text")?.forEachObject { o ->
            val s = o.optString("string").trim()
            if (s.length >= 2 && scored(o) && s !in text) text += s
        }
        // "lang: en | <what is seen> | <general facts> | cannot ...": the second part says what is in the picture.
        val summary = json.optString("reasoning").split("|").map { it.trim() }
            .firstOrNull { it.isNotEmpty() && !it.startsWith("lang:") } ?: ""
        val scene = json.optJSONObject("scene")?.let { s -> s.keys().asSequence().map { s.optString(it) }.filter { it.isNotBlank() }.toList() }
            ?: emptyList()
        return mapOf("objects" to objects.toList(), "text" to text, "summary" to summary, "scene" to scene)
    }

    private inline fun JSONArray.forEachObject(action: (JSONObject) -> Unit) {
        for (i in 0 until length()) optJSONObject(i)?.let(action)
    }

    /** [bytes] decoded, upright (EXIF) and no larger than [SIDE] on its longest side. */
    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= SIDE) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
        val scale = SIDE.toFloat() / maxOf(bitmap.width, bitmap.height)
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
        if (scale < 1f || turn != 0f) {
            val m = Matrix().apply {
                if (scale < 1f) postScale(scale, scale)
                if (turn != 0f) postRotate(turn)
            }
            val upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
            if (upright !== bitmap) bitmap.recycle()
            bitmap = upright
        }
        return bitmap
    }
}
