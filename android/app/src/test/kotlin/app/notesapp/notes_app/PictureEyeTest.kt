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
    fun `a photo is no kind, and what it shows is kept most sure first, judgements and flags left out`() {
        val look = PictureEye.read(analysis(
            "photo",
            """"photo":0.95,"selfie":0.03,"dog":0.81,"beach":0.93,"group_shot":0.62,"blurry":0.55,"forgettable":0.9,""" +
                """"weapon":0.7,"cat":0.3""",
            rotation = "90",
        ))
        assertNull(look["kind"])
        // Photo types are never tags, below the cutoff is nothing, keep-or-delete and sensitive tags stay out.
        assertEquals(listOf("beach", "dog", "group_shot", "blurry"), look["tags"])
        assertEquals(90, look["rotation"])
    }

    @Test
    fun `a receipt is its kind and nothing more, Eye's scenes being guesses off photos`() {
        // As Eye read a receipt on the phone: sure of the kind, and of "skiing".
        val look = PictureEye.read(analysis("receipt", """"receipt":0.96,"sharp":0.96,"skiing":0.57,"menu":0.58"""))
        assertEquals("receipt", look["kind"])
        assertEquals(emptyList<String>(), look["tags"])
    }

    @Test
    fun `a kind Eye is unsure of is no kind`() {
        assertNull(PictureEye.read(analysis("whiteboard", """"whiteboard":0.41,"document":0.39"""))["kind"])
    }
}
