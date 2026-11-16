package app.notesapp.notes_app

import com.github.luben.zstd.ZstdOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

class OfflineModelsTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** A ustar archive of [files] (name -> bytes), zstd-compressed, as Phonon's archives are made. */
    private fun tarZst(files: List<Pair<String, ByteArray>>): ByteArray {
        val tar = ByteArrayOutputStream()
        for ((name, data) in files) {
            val h = ByteArray(512)
            name.toByteArray().copyInto(h, 0)
            "0000644".toByteArray().copyInto(h, 100)
            String.format("%011o", data.size).toByteArray().copyInto(h, 124)
            h[156] = '0'.code.toByte()
            "ustar".toByteArray().copyInto(h, 257)
            // Checksum: the header's bytes, its own field as spaces.
            for (i in 148 until 156) h[i] = ' '.code.toByte()
            String.format("%06o\u0000 ", h.sumOf { it.toInt() and 0xff }).toByteArray().copyInto(h, 148)
            tar.write(h)
            tar.write(data)
            tar.write(ByteArray((512 - data.size % 512) % 512))
        }
        tar.write(ByteArray(1024))
        val out = ByteArrayOutputStream()
        ZstdOutputStream(out).use { it.write(tar.toByteArray()) }
        return out.toByteArray()
    }

    private val model = ByteArray(70_000) { (it * 31 % 251).toByte() }
    private val config = """{"layers": 12}""".toByteArray()
    private val archive = tarZst(listOf("bps_manifest.json" to "{}".toByteArray(), "config.json" to config, "./model.fermion" to model))
    private val specs = listOf(
        OfflineModels.Spec("model.fermion", model.size.toLong(), sha(model), emptyList()),
        OfflineModels.Spec("config.json", config.size.toLong(), sha(config), emptyList()),
    )

    @Test
    fun `an archive is unpacked into the files asked for, each checked, the rest left out`() {
        val dir = tmp.newFolder()
        var last = 0L
        OfflineModels.unpack(ByteArrayInputStream(archive), dir, OfflineModels.Archive("a.tar.zst", archive.size.toLong(), sha(archive)),
            specs, "test") { last = it }
        assertArrayEquals(model, dir.resolve("model.fermion").readBytes())
        assertArrayEquals(config, dir.resolve("config.json").readBytes())
        assertFalse(dir.resolve("bps_manifest.json").exists())
        assertEquals(archive.size.toLong(), last)
        assertEquals(setOf("model.fermion", "config.json"), dir.list()!!.toSet())
    }

    @Test
    fun `nothing is kept when the archive or a file inside it is not the pinned one`() {
        fun refused(bytes: ByteArray, archiveSha: String, files: List<OfflineModels.Spec>) {
            val dir = tmp.newFolder()
            try {
                OfflineModels.unpack(ByteArrayInputStream(bytes), dir, OfflineModels.Archive("a.tar.zst", bytes.size.toLong(), archiveSha),
                    files, "test") {}
                fail("kept a wrong archive")
            } catch (e: IllegalStateException) {
                assertTrue(e.message!!, e.message!!.contains("did not come down whole"))
            }
            assertEquals("nothing left behind", 0, dir.list()!!.size)
        }
        // The archive's own checksum differs.
        refused(archive, "0".repeat(64), specs)
        // A file's checksum differs (another model.fermion than the pinned one).
        refused(archive, sha(archive), listOf(specs[0].copy(sha256 = "0".repeat(64)), specs[1]))
        // A file asked for is not in it.
        refused(archive, sha(archive), specs + OfflineModels.Spec("packed_manifest.json", 10, "", emptyList()))
    }
}
