package app.notesapp.notes_app

import org.junit.Assert.assertEquals
import org.junit.Test

class MirageTaggerTest {
    @Test
    fun `tags are read even where the engine wrote a score as -nan`() {
        // The shape of a real answer (handwritten list, 2026-11-16): one object's score came out as -nan.
        val answer = """{"scene":{"background":"dark","style":"photograph"},"objects":[{"id":1,"name":"pen","score":-nan},""" +
            """{"id":2,"name":"hand","score":0.71},{"id":3,"name":"text","score":0.6},{"id":4,"name":"cup","score":0.12},""" +
            """{"id":5,"name":"hand","score":0.5}],"text":[{"string":"Salami","score":0.44},{"string":"x","score":0.9},""" +
            """{"string":"Kase","score":0.2}],"reasoning":"lang: en | hand holding paper with handwriting | pens write"}"""
        val tags = MirageTagger.read(answer)
        // A -nan score counts as no score (kept); low scores, "text" itself, one-letter reads and repeats are left out.
        assertEquals(listOf("pen", "hand"), tags["objects"])
        assertEquals(listOf("Salami"), tags["text"])
        assertEquals("hand holding paper with handwriting", tags["summary"])
        assertEquals(listOf("dark", "photograph"), tags["scene"])
    }
}
