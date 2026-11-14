package app.notesapp.notes_app

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/**
 * Whether a file is a Phonon voice (what Gradium's clone-voice.py makes, and the stock voices are): a
 * safetensors file holding one float32 tensor `speaker_wavs` shaped [1, 512, frames], its bytes exactly
 * where the header says and nothing else in the file. Anything else is refused before it reaches the
 * voice engine; the engine then loads it as well before it is kept (ReadAloud.addVoice).
 */
object VoiceFile {
    private const val CHANNELS = 512

    /** null when [file] is a Phonon voice, else what is wrong with it, for the user. */
    fun problem(file: File): String? {
        val size = file.length()
        if (size < 16 || size > 64L shl 20) return "This is not a Phonon voice file (wrong size)."
        return try {
            RandomAccessFile(file, "r").use { f ->
                val head = ByteArray(8)
                f.readFully(head)
                var n = 0L
                for (i in 7 downTo 0) n = (n shl 8) or (head[i].toLong() and 0xff)
                if (n <= 0 || n > 1 shl 20 || 8 + n > size) return "This is not a Phonon voice file (no safetensors header)."
                val json = ByteArray(n.toInt())
                f.readFully(json)
                val header = JSONObject(String(json, Charsets.UTF_8))
                val tensor = header.optJSONObject("speaker_wavs")
                    ?: return "This is not a Phonon voice file (no speaker_wavs in it)."
                val tensors = header.keys().asSequence().filter { it != "__metadata__" }.toList()
                if (tensors.size != 1) return "This is not a Phonon voice file (it holds ${tensors.size} tensors)."
                if (tensor.optString("dtype") != "F32") return "This is not a Phonon voice file (not float32)."
                val shape = tensor.getJSONArray("shape")
                if (shape.length() != 3 || shape.getLong(0) != 1L || shape.getLong(1) != CHANNELS.toLong()) {
                    return "This is not a Phonon voice file (shape $shape, not [1, $CHANNELS, n])."
                }
                val frames = shape.getLong(2)
                if (frames !in 1..4000) return "This is not a Phonon voice file ($frames frames)."
                val offsets = tensor.getJSONArray("data_offsets")
                val bytes = 4L * CHANNELS * frames
                if (offsets.getLong(0) != 0L || offsets.getLong(1) != bytes || 8 + n + bytes != size) {
                    return "This is not a Phonon voice file (its size does not match its header)."
                }
                null
            }
        } catch (e: Exception) {
            "This is not a Phonon voice file (${e.message ?: "unreadable"})."
        }
    }

    /** A voice's name as typed, made safe for a file name: letters, digits, spaces, '-' and '_'. */
    fun cleanName(name: String): String =
        name.trim().replace(Regex("[^\\p{L}\\p{N} _-]"), "").replace(Regex("\\s+"), " ").take(40).trim()
}
