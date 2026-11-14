package app.notesapp.notes_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Only real Phonon voice files get in: the user's cloned voices pass; impostors and damaged ones do not. */
class VoiceFileTest {
    private val tmp = File(System.getProperty("java.io.tmpdir"), "voicefile-test").apply { mkdirs() }

    /** A safetensors file with [header] JSON and [dataBytes] of data. */
    private fun safetensors(name: String, header: String, dataBytes: Int): File {
        val json = header.toByteArray()
        val head = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(json.size.toLong()).array()
        return File(tmp, name).apply { writeBytes(head + json + ByteArray(dataBytes)) }
    }

    private fun voiceHeader(dtype: String = "F32", shape: String = "[1,512,125]", end: Long = 256000) =
        """{"speaker_wavs":{"dtype":"$dtype","shape":$shape,"data_offsets":[0,$end]}}"""

    @Test
    fun theUsersOwnClonedVoicesAreValid() {
        val dir = File(System.getenv("PHONON_VOICES") ?: "voices")
        val files = dir.listFiles { f -> f.name.endsWith(".safetensors") }.orEmpty()
        if (files.isEmpty()) return // not on this machine
        assertEquals(11, files.size)
        for (f in files) assertNull("${f.name}: ${VoiceFile.problem(f)}", VoiceFile.problem(f))
    }

    @Test
    fun aWellFormedVoiceIsValid() {
        assertNull(VoiceFile.problem(safetensors("ok.safetensors", voiceHeader(), 256000)))
        // Another length of reference audio is still a voice.
        assertNull(VoiceFile.problem(safetensors("ok2.safetensors", voiceHeader(shape = "[1,512,90]", end = 184320), 184320)))
    }

    @Test
    fun impostorsAndDamagedFilesAreRefused() {
        val bad = mapOf(
            "empty" to File(tmp, "empty").apply { writeBytes(ByteArray(0)) },
            "random bytes" to File(tmp, "random").apply { writeBytes(ByteArray(256136) { (it * 31).toByte() }) },
            "a tflite model" to File(tmp, "model.tflite").apply { writeBytes("TFL3".toByteArray() + ByteArray(5000)) },
            "truncated" to safetensors("short.safetensors", voiceHeader(), 1000),
            "two tensors" to safetensors(
                "two.safetensors",
                """{"speaker_wavs":{"dtype":"F32","shape":[1,512,125],"data_offsets":[0,256000]},"x":{"dtype":"F32","shape":[1],"data_offsets":[256000,256004]}}""",
                256004,
            ),
            "wrong dtype" to safetensors("f16.safetensors", voiceHeader(dtype = "F16", end = 128000), 128000),
            "wrong shape" to safetensors("shape.safetensors", voiceHeader(shape = "[1,256,250]"), 256000),
            "trailing bytes" to safetensors("tail.safetensors", voiceHeader(), 256100),
            "json, not a voice" to File(tmp, "notes.json").apply { writeText("""{"hello": "world"}""") },
        )
        for ((what, file) in bad) assertNotNull("$what should be refused", VoiceFile.problem(file))
    }

    @Test
    fun namesAreMadeSafeForFiles() {
        assertEquals("Arden", VoiceFile.cleanName("  Arden "))
        assertEquals("Mums voice2", VoiceFile.cleanName("Mum's voice/2"))
        assertEquals("", VoiceFile.cleanName("../.."))
        assertEquals("Zoë", VoiceFile.cleanName("Zoë"))
    }
}
