package app.notesapp.notes_app

import java.io.File
import java.util.PriorityQueue

/**
 * SentencePiece's BPE encoder, for EmbeddingGemma 2's tokenizer (tokenizer.spm, a SentencePiece ModelProto): the same
 * ids as SentencePiece itself (sentencepiece's bpe_model.cc), for this model's settings: no normalization, spaces as
 * "▁", no dummy prefix, user-defined pieces matched whole, byte fallback. Checked against SentencePiece in
 * SentencePieceTest.
 */
class SentencePiece(bytes: ByteArray) {
    private val ids = HashMap<String, Int>(1 shl 19)
    private val scores: FloatArray
    private val userDefined = HashSet<String>()
    private var longestUserDefined = 0
    private val byteIds = IntArray(256) { -1 }
    private var unk = 0

    init {
        val pieces = ArrayList<Triple<String, Float, Int>>(270_000)
        // ModelProto: field 1 = repeated SentencePiece { 1: piece, 2: score (float), 3: type (enum) }.
        Proto(bytes).forEach { field, value ->
            if (field == 1 && value is ByteArray) {
                var piece = ""
                var score = 0f
                var type = 1
                Proto(value).forEach { f, v ->
                    when (f) {
                        1 -> piece = String(v as ByteArray, Charsets.UTF_8)
                        2 -> score = Float.fromBits((v as Long).toInt())
                        3 -> type = (v as Long).toInt()
                    }
                }
                pieces += Triple(piece, score, type)
            }
        }
        scores = FloatArray(pieces.size)
        for ((i, p) in pieces.withIndex()) {
            val (piece, score, type) = p
            scores[i] = score
            when (type) {
                NORMAL -> ids[piece] = i
                USER_DEFINED -> {
                    ids[piece] = i
                    userDefined += piece
                    longestUserDefined = maxOf(longestUserDefined, piece.length)
                }
                UNKNOWN -> unk = i
                BYTE -> Regex("<0x([0-9A-Fa-f]{2})>").matchEntire(piece)?.let { byteIds[it.groupValues[1].toInt(16)] = i }
            }
        }
    }

    /** The token id of [piece], or null. */
    fun idOf(piece: String): Int? = ids[piece]

    /** [text] as token ids (without BOS or EOS). */
    fun encode(text: String): IntArray {
        val s = text.replace(' ', '▁')
        // Symbols: each character, a user-defined piece as one.
        val symbols = ArrayList<String>()
        var i = 0
        while (i < s.length) {
            var matched: String? = null
            if (longestUserDefined > 0) {
                var len = minOf(longestUserDefined, s.length - i)
                while (len > 1) {
                    val cand = s.substring(i, i + len)
                    if (cand in userDefined) {
                        matched = cand
                        break
                    }
                    len--
                }
            }
            val step = matched?.length ?: Character.charCount(s.codePointAt(i))
            symbols += matched ?: s.substring(i, i + step)
            i += step
        }
        val n = symbols.size
        val piece = arrayOfNulls<String>(n).also { for (k in 0 until n) it[k] = symbols[k] }
        val prev = IntArray(n) { it - 1 }
        val next = IntArray(n) { if (it + 1 < n) it + 1 else -1 }

        // Candidate merges, best score first, leftmost on a tie.
        class Pair(val left: Int, val right: Int, val score: Float, val size: Int)
        val agenda = PriorityQueue<Pair>(compareByDescending<Pair> { it.score }.thenBy { it.left })
        fun consider(left: Int, right: Int) {
            if (left < 0 || right < 0) return
            val merged = piece[left]!! + piece[right]!!
            val id = ids[merged] ?: return
            agenda += Pair(left, right, scores[id], merged.length)
        }
        for (k in 1 until n) consider(k - 1, k)
        while (agenda.isNotEmpty()) {
            val top = agenda.poll()!!
            val l = piece[top.left]
            val r = piece[top.right]
            // Stale: one side was merged into something else since.
            if (l == null || r == null || next[top.left] != top.right || l.length + r.length != top.size) continue
            piece[top.left] = l + r
            piece[top.right] = null
            next[top.left] = next[top.right]
            if (next[top.right] >= 0) prev[next[top.right]] = top.left
            consider(prev[top.left], top.left)
            consider(top.left, next[top.left])
        }

        val out = ArrayList<Int>(n)
        var k = 0
        while (k >= 0 && k < n) {
            val p = piece[k]
            if (p != null) {
                val id = ids[p]
                if (id != null) {
                    out += id
                } else {
                    // Byte fallback: the piece's UTF-8 bytes, each its own token.
                    for (b in p.toByteArray(Charsets.UTF_8)) out += byteIds[b.toInt() and 0xff].takeIf { it >= 0 } ?: unk
                }
            }
            k = next[k]
        }
        return out.toIntArray()
    }

    /** Protocol Buffers' wire format, read field by field: varints as Long, length-delimited as ByteArray. */
    private class Proto(private val b: ByteArray) {
        fun forEach(action: (Int, Any) -> Unit) {
            var i = 0
            fun varint(): Long {
                var r = 0L
                var shift = 0
                while (true) {
                    val x = b[i++].toInt() and 0xff
                    r = r or ((x and 0x7f).toLong() shl shift)
                    if (x < 0x80) return r
                    shift += 7
                }
            }
            while (i < b.size) {
                val key = varint()
                val field = (key ushr 3).toInt()
                when ((key and 7).toInt()) {
                    0 -> action(field, varint())
                    1 -> { action(field, readLong(i, 8)); i += 8 }
                    2 -> {
                        val len = varint().toInt()
                        action(field, b.copyOfRange(i, i + len))
                        i += len
                    }
                    5 -> { action(field, readLong(i, 4)); i += 4 }
                    else -> return
                }
            }
        }

        private fun readLong(at: Int, n: Int): Long {
            var r = 0L
            for (k in n - 1 downTo 0) r = (r shl 8) or (b[at + k].toLong() and 0xff)
            return r
        }
    }

    companion object {
        private const val NORMAL = 1
        private const val UNKNOWN = 2
        private const val USER_DEFINED = 4
        private const val BYTE = 6

        fun load(file: File) = SentencePiece(file.readBytes())
    }
}
