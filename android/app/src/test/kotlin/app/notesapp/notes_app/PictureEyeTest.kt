package app.notesapp.notes_app

import ai.desertant.eye.Analysis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PictureEyeTest {
    private fun analysis(kind: String, tags: String, rotation: String = "null") = Analysis.fromJson(
        """{"model":"eye@v1.0.0","width":1024,"height":768,"kind":"$kind","rotation":$rotation,"tags":{$tags}}""",
    )

    @Test
    fun `a receipt is its kind, what else is seen is kept most sure first, judgements and flags left out`() {
        val look = PictureEye.read(analysis(
            "receipt",
            """"receipt":0.97,"document":0.02,"paper":0.81,"text":0.93,"blurry":0.62,"forgettable":0.9,""" +
                """"weapon":0.7,"dog":0.3""",
            rotation = "90",
        ))
        assertEquals("receipt", look["kind"])
        // Photo types are never tags, below the cutoff is nothing, keep-or-delete and sensitive tags stay out.
        assertEquals(listOf("text", "paper", "blurry"), look["tags"])
        assertEquals(90, look["rotation"])
    }

    @Test
    fun `a plain photo, or a kind Eye is unsure of, gives no kind`() {
        assertNull(PictureEye.read(analysis("photo", """"photo":0.95,"beach":0.88"""))["kind"])
        assertEquals(listOf("beach"), PictureEye.read(analysis("photo", """"photo":0.95,"beach":0.88"""))["tags"])
        assertNull(PictureEye.read(analysis("whiteboard", """"whiteboard":0.41,"document":0.39"""))["kind"])
    }
}
