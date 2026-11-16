package app.notesapp.notes_app

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class EmbedderTest {
    @Test
    fun `pictures are resized to the sizes LiteRT-LM picks`() {
        // From LiteRT-LM's own log on the test pictures (stb_image_preprocessor.cc).
        assertEquals(672 to 432, Embedder.targetSize(1280, 842))
        assertEquals(624 to 480, Embedder.targetSize(1280, 1024))
        assertEquals(960 to 288, Embedder.targetSize(1280, 447))
        assertEquals(480 to 624, Embedder.targetSize(1280, 1707))
        // Every side a multiple of 48 px (16 px patches, 3x3 pooling), never over 1260 patches.
        for ((w, h) in listOf(4000 to 3000, 50 to 4000, 4000 to 50, 1 to 1, 640 to 480)) {
            val (tw, th) = Embedder.targetSize(w, h)
            assertTrue("$w x $h -> $tw x $th", tw % 48 == 0 && th % 48 == 0 && (tw / 16) * (th / 16) <= 1260)
        }
    }

    @Test
    fun `the resampler gives the reference's pixels, shrinking and enlarging`() {
        val cases = JSONArray(javaClass.getResource("/resize_cases.json")!!.readText())
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val src = c.getJSONArray("argb").let { a -> IntArray(a.length()) { a.getLong(it).toInt() } }
            val want = c.getJSONArray("rgb").let { a -> IntArray(a.length()) { a.getInt(it) } }
            val got = Embedder.resize(src, c.getInt("w"), c.getInt("h"), c.getInt("tw"), c.getInt("th"))
            assertEquals(want.size, got.size)
            // Float32 here, float64 there: at most one level apart.
            val worst = want.indices.maxOf { abs(want[it] - got[it]) }
            assertTrue("case $i: a pixel differs by $worst", worst <= 1)
        }
    }

    @Test
    fun `vectors are cut to 256 and normalized`() {
        val v = Embedder.unit(FloatArray(768) { if (it < 256) 2f else 100f })
        assertEquals(256, v.size)
        assertEquals(1.0, v.fold(0.0) { s, x -> s + x * x }, 1e-5)
    }
}
