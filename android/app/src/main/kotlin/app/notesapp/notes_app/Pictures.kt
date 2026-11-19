package app.notesapp.notes_app

import ai.desertant.eye.Analysis
import ai.desertant.eye.Tag
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream

/** [bytes] decoded, upright (EXIF) and no larger than [side] on its longest side; null when Android cannot read it. */
internal fun uprightPicture(bytes: ByteArray, side: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= side) sample *= 2
    val opts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
    var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
    val scale = side.toFloat() / maxOf(bitmap.width, bitmap.height)
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

/**
 * What Eye (Desert Ant) says about a picture, as the notes keep it:
 *  - "kind": what the picture is (`receipt`, `screenshot`, `whiteboard`, ...) when Eye is sure of it (at its
 *    recommended cutoff), else null; a plain photo or "other" is no kind worth a tag;
 *  - "tags": what else it sees, at that cutoff, most sure first: the things in it (Open Images' scenes), its people
 *    (`group_shot`, `smiling`) and how it was taken (`blurry`, `bokeh`), for search;
 *  - "rotation": how far it is turned clockwise from upright when Eye is sure, else null.
 * Keep-or-delete judgements (the model's least reliable) and sensitive-content flags are left out: they are not what
 * someone searches their notes for.
 */
object PictureEye {
    /** The side a picture is shrunk to first: Eye reads a 384 px centre crop and faces from the whole frame. */
    const val SIDE = 1024

    /** Tags never kept: keep-or-delete reasons and sensitive content. */
    private val left = setOf(
        "accidental", "bad_framing", "bad_lighting", "forgettable", "keeper", "low_content", "reference_photo",
        "technical_flaw", "test_or_duplicate_shot", "unusable",
        "accident_disaster", "blood_injury", "funeral", "medical_hospital", "nsfw_explicit", "nsfw_suggestive",
        "violence_protest", "weapon",
    )

    /** Kinds that say nothing a tag would add. */
    private val plain = setOf("photo", "other")

    /** Eye's photo types: a kind is one of these, never also a tag. */
    private val kinds = setOf(
        "chart_or_slide", "document", "id_card", "illustration_or_art", "map", "medical_reference", "meme_or_graphic",
        "other", "photo", "photo_of_screen", "receipt", "reference", "repair_reference", "screenshot", "selfie",
        "shopping_reference", "whiteboard",
    )

    fun read(a: Analysis): Map<String, Any?> {
        val kind = a.kind?.id?.takeIf { it !in plain && a.has(Tag(it)) }
        val tags = a.tags().map { it.id }.filter { it !in left && it !in kinds }
        return mapOf("kind" to kind, "tags" to tags, "rotation" to a.rotation)
    }
}
