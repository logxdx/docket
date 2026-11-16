package app.notesapp.notes_app

import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PhononArchiveTest {
    @get:Rule val tmp = TemporaryFolder()

    /**
     * The real English Phonon archive (its path in PHONON_ARCHIVE; skipped without it) unpacked as the app does it,
     * against the pins in .models-bundle's manifest (tool/stage_models.py): every file it keeps, size and sha256.
     */
    @Test
    fun `the real speech recognizer archive unpacks to the pinned files`() {
        val path = System.getenv("PHONON_ARCHIVE")
        val manifest = File("../../.models-bundle/models/manifest.json")
        assumeTrue("PHONON_ARCHIVE not set", path != null && File(path).isFile && manifest.isFile)
        val model = JSONObject(manifest.readText()).getJSONObject("downloads").getJSONObject("phonon-en")
        val a = model.getJSONObject("archive")
        val files = model.getJSONArray("files").let { arr ->
            (0 until arr.length()).map { i ->
                val f = arr.getJSONObject(i)
                OfflineModels.Spec(f.getString("path"), f.getLong("size"), f.getString("sha256"), emptyList())
            }
        }
        val dir = tmp.newFolder()
        File(path!!).inputStream().buffered(1 shl 20).use {
            OfflineModels.unpack(it, dir, OfflineModels.Archive(a.getString("path"), a.getLong("size"), a.getString("sha256")),
                files, "phonon-en") {}
        }
        for (f in files) check(File(dir, f.path).length() == f.size) { "${f.path} not in place" }
    }
}
