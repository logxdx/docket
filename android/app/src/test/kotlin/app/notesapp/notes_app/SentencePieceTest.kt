package app.notesapp.notes_app

import org.json.JSONArray
import org.junit.Assert.assertArrayEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class SentencePieceTest {
    /**
     * EmbeddingGemma 2's tokenizer, read from the model file tool/fetch_models.py keeps in .models (its tokenizer is the
     * container's bytes 32768..4721781, as the manifest's split says); skipped where the models were not fetched.
     */
    private fun tokenizer(): SentencePiece? {
        val container = File("../../.models/models/embeddinggemma/embeddinggemma-2-text-vision-440m.litertlm")
        if (!container.isFile) return null
        val bytes = ByteArray(4721781 - 32768)
        RandomAccessFile(container, "r").use {
            it.seek(32768)
            it.readFully(bytes)
        }
        return SentencePiece(bytes)
    }

    @Test
    fun `the same ids as SentencePiece itself, in every script, with emoji, digits, spaces and byte fallback`() {
        val sp = tokenizer()
        assumeTrue("EmbeddingGemma 2 not fetched (python3 -I tool/fetch_models.py)", sp != null)
        val cases = JSONArray(javaClass.getResource("/sentencepiece_cases.json")!!.readText())
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val want = c.getJSONArray("ids").let { a -> IntArray(a.length()) { a.getInt(it) } }
            assertArrayEquals("tokens of ${c.getString("text")}", want, sp!!.encode(c.getString("text")))
        }
    }
}
