package app.notesapp.notes_app

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * The on-device models. Two kinds, as the APK's manifest lists them:
 *  - "models": carried by the APK as assets (assets/models/<id>/..., Phonon's: put there by
 *    tool/stage_models.py), copied to the app's own folder on the first launch after an install or
 *    update, because the runtimes open real files;
 *  - "downloads": the Desert Ant models, left out to keep the APK small, fetched from Hugging Face
 *    when the user asks (Settings › On-device models): each file from its pinned revision, kept only
 *    when its size and sha256 are the pinned ones.
 * A build without models (NOTES_BUNDLE_MODELS=0) takes the folder pushed over USB instead
 * (tool/push_models.sh), described by the manifest.json pushed with it.
 * A model's folder is handed to its SDK as `directory`; a folder the SDK finds already filled (and
 * without its own download bookkeeping) is used as-is. A model not in place is reported missing and
 * never constructed, so no SDK ever downloads on its own.
 * A file the manifest gives a "split" (EmbeddingGemma 2's container) is kept as its parts only, each where the
 * manifest says: written as it downloads, the whole stream checked against the file's sha256. A model the manifest
 * gives an "archive" (Phonon's recognizers: a .tar.zst) is downloaded as that archive and kept as the files it lists,
 * unpacked as it streams in; the archive's sha256 and each file's are checked.
 */
class OfflineModels(private val context: Context) {
    private val root = File(context.filesDir, "models")
    private val stamp = File(root, ".installed.json")

    /** What the APK carries: id -> list of (repo-relative path, size). Null when no models were bundled. */
    private val inApk: JSONObject? by lazy {
        try {
            context.assets.open("models/manifest.json").bufferedReader().use { JSONObject(it.readText()) }
        } catch (_: Exception) {
            null
        }
    }

    /** The models: those the APK carries, else those pushed into the app's folder (read each time: a push may come later). */
    private val bundled: JSONObject?
        get() = inApk ?: try {
            JSONObject(File(root, "manifest.json").readText())
        } catch (_: Exception) {
            null
        }

    /** The models the APK carries. */
    fun bundledIds(): List<String> {
        val models = bundled?.optJSONObject("models") ?: return emptyList()
        return models.keys().asSequence().toList()
    }

    /** The models the APK leaves out, to download (the Desert Ant ones), with their files pinned. */
    fun downloadIds(): List<String> {
        val models = bundled?.optJSONObject("downloads") ?: return emptyList()
        return models.keys().asSequence().toList()
    }

    /** How many bytes [id] takes to download: its archive, or all its files together. */
    fun sizeOf(id: String): Long = archiveOf(id)?.size ?: specsOf(id)?.sumOf { it.size } ?: 0L

    /** A model's archive (Phonon's recognizers): downloaded whole, unpacked into the files the manifest lists. */
    internal data class Archive(val path: String, val size: Long, val sha256: String)

    private fun archiveOf(id: String): Archive? {
        val model = bundled?.optJSONObject("downloads")?.optJSONObject(id) ?: return null
        val a = model.optJSONObject("archive") ?: return null
        return Archive(a.getString("path"), a.getLong("size"), a.optString("sha256"))
    }

    /** A part of a file kept cut up: [path] in the model's folder, bytes [begin] to [end] of the file. */
    internal data class Part(val path: String, val begin: Long, val end: Long)

    /**
     * A file as the manifest pins it, and its parts when it is kept cut up; where it comes from when that is not its
     * model's repo and revision ([repo], [revision], its own path there [remote]).
     */
    internal data class Spec(
        val path: String,
        val size: Long,
        val sha256: String,
        val split: List<Part>,
        val repo: String? = null,
        val revision: String? = null,
        val remote: String? = null,
    )

    private fun specsOf(id: String): List<Spec>? {
        val model = bundled?.optJSONObject("models")?.optJSONObject(id)
            ?: bundled?.optJSONObject("downloads")?.optJSONObject(id) ?: return null
        val files = model.getJSONArray("files")
        return (0 until files.length()).map {
            val f = files.getJSONObject(it)
            val split = f.optJSONArray("split")?.let { a ->
                (0 until a.length()).map { i ->
                    val p = a.getJSONObject(i)
                    Part(p.getString("path"), p.getLong("begin"), p.getLong("end"))
                }.sortedBy { p -> p.begin }
            } ?: emptyList()
            // A JSON null (no checksum pinned) is no checksum, not the text "null".
            Spec(
                f.getString("path"), f.getLong("size"), if (f.isNull("sha256")) "" else f.optString("sha256"), split,
                f.optString("repo").ifEmpty { null }, f.optString("revision").ifEmpty { null }, f.optString("remote").ifEmpty { null },
            )
        }
    }

    /** Whether [spec]'s file is in [dir] as kept: whole, or as all its parts. */
    private fun present(dir: File, spec: Spec): Boolean =
        if (spec.split.isEmpty()) File(dir, spec.path).length() == spec.size
        else spec.split.all { File(dir, it.path).length() == it.end - it.begin }

    /** Cancelled downloads, by id: the download stops at its next block. */
    private val cancelled = java.util.Collections.synchronizedSet(HashSet<String>())

    fun cancel(id: String) {
        cancelled += id
    }

    /**
     * Download [id] (one of [downloadIds]) from Hugging Face: each file from the revision the manifest pins
     * (https://huggingface.co/<repo>/resolve/<revision>/<path>), kept only when its size and sha256 are the pinned
     * ones. Files already in place are kept, so a download stopped halfway goes on where it was. [progress] gets
     * bytes done and the total. Throws with what went wrong; the model is then not ready (its finished files stay).
     */
    fun download(id: String, progress: (Long, Long) -> Unit) {
        val model = bundled?.optJSONObject("downloads")?.optJSONObject(id)
            ?: throw IllegalArgumentException("$id is not a model to download")
        val repo = model.getString("repo")
        val revision = model.getString("revision")
        val specs = specsOf(id)!!
        val dir = File(root, id)
        cancelled -= id
        archiveOf(id)?.let { archive ->
            if (specs.all { present(dir, it) }) return
            fetch(id, "https://huggingface.co/$repo/resolve/$revision/${archive.path}") { input ->
                unpack(input, dir, archive, specs, "$id/${archive.path}") { got ->
                    if (id in cancelled) throw InterruptedException("Download stopped.")
                    progress(got, archive.size)
                }
            }
            File(dir, ".dal-meta").deleteRecursively()
            return
        }
        val total = specs.sumOf { it.size }
        var done = 0L
        for (spec in specs) {
            if (present(dir, spec)) {
                done += spec.size
                progress(done, total)
                continue
            }
            val base = done
            val url = "https://huggingface.co/${spec.repo ?: repo}/resolve/${spec.revision ?: revision}/${spec.remote ?: spec.path}"
            fetch(id, url) { input ->
                place(input, dir, spec, "$id/${spec.path}") { got ->
                    if (id in cancelled) throw InterruptedException("Download stopped.")
                    progress(base + got, total)
                }
            }
            done += spec.size
        }
        File(dir, ".dal-meta").deleteRecursively()
    }

    /** [url]'s body handed to [read], with what went wrong said plainly. */
    private fun fetch(id: String, url: String, read: (java.io.InputStream) -> Unit) {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 20_000
        connection.readTimeout = 60_000
        connection.instanceFollowRedirects = true
        try {
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("Hugging Face answered ${connection.responseCode} for $id (${url.substringAfterLast('/')}).")
            }
            connection.inputStream.use(read)
        } catch (e: java.net.UnknownHostException) {
            throw IllegalStateException("No internet connection: the models come from Hugging Face. Try again when online.")
        } catch (e: InterruptedException) {
            throw IllegalStateException("Download stopped.")
        } catch (e: java.io.IOException) {
            // A dropped connection keeps the files done so far: the next try goes on from there.
            throw IllegalStateException("The download was cut off (${e.message}). Try again: it goes on where it stopped.")
        } finally {
            connection.disconnect()
        }
    }

    companion object {
    /**
     * [input] ([archive]: a tar compressed with zstd) unpacked into [dir] as it streams: of its files, those in
     * [files] are kept (by name), each checked against its size and sha256, and the archive's own bytes against its
     * sha256; nothing is placed unless all of it is right. [onBytes] gets the archive's bytes read so far.
     */
    internal fun unpack(input: java.io.InputStream, dir: File, archive: Archive, files: List<Spec>, what: String,
                        onBytes: (Long) -> Unit) {
        val wanted = files.associateBy { it.path }
        val digest = MessageDigest.getInstance("SHA-256")
        var read = 0L
        val counted = object : java.io.FilterInputStream(input) {
            override fun read(): Int = super.read().also { if (it >= 0) { digest.update(it.toByte()); read++; onBytes(read) } }
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { n ->
                if (n > 0) {
                    digest.update(b, off, n)
                    read += n
                    onBytes(read)
                }
            }
        }
        dir.mkdirs()
        val temps = HashMap<String, File>()
        val sums = HashMap<String, String>()
        val zstd = com.github.luben.zstd.ZstdInputStream(counted)
        try {
            untar(zstd, wanted.keys, dir, temps, sums)
            // The rest of the archive (zstd may stop before its last bytes), for its checksum.
            val buf = ByteArray(1 shl 16)
            while (counted.read(buf) >= 0) Unit
        } catch (e: Exception) {
            temps.values.forEach { it.delete() }
            throw e
        } finally {
            zstd.close()
        }
        val sha = digest.digest().joinToString("") { "%02x".format(it) }
        val bad = when {
            read != archive.size || (archive.sha256.isNotEmpty() && sha != archive.sha256) -> "the archive"
            else -> files.firstOrNull { f ->
                val t = temps[f.path]
                t == null || t.length() != f.size || (f.sha256.isNotEmpty() && sums[f.path] != f.sha256)
            }?.path
        }
        if (bad != null) {
            temps.values.forEach { it.delete() }
            throw IllegalStateException("$what did not come down whole ($bad differs). Try again.")
        }
        for ((path, t) in temps) {
            if (!t.renameTo(File(dir, path))) throw IllegalStateException("could not place $path")
        }
    }

    /** A tar's regular files named in [wanted] (by name, any folder) written beside their places as .part, with their sha256. */
    private fun untar(tar: java.io.InputStream, wanted: Set<String>, dir: File, temps: MutableMap<String, File>,
                      sums: MutableMap<String, String>) {
        val header = ByteArray(512)
        val buf = ByteArray(1 shl 16)
        fun readFully(b: ByteArray, n: Int): Boolean {
            var got = 0
            while (got < n) {
                val r = tar.read(b, got, n - got)
                if (r < 0) return false
                got += r
            }
            return true
        }
        while (readFully(header, 512)) {
            if (header.all { it.toInt() == 0 }) break // the end: zero blocks
            fun text(from: Int, len: Int) = String(header, from, len, Charsets.UTF_8).substringBefore(' ').trim()
            val name = (text(345, 155).let { if (it.isEmpty()) "" else "$it/" } + text(0, 100)).substringAfterLast('/')
            val size = text(124, 12).ifEmpty { "0" }.toLong(8)
            val type = header[156].toInt().toChar()
            val keep = (type == '0' || type == ' ') && name in wanted
            val out = if (keep) File(dir, "$name.part").also { temps[name] = it }.outputStream() else null
            val md = if (keep) MessageDigest.getInstance("SHA-256") else null
            var left = size
            try {
                while (left > 0) {
                    val n = tar.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                    if (n < 0) throw java.io.IOException("the archive ends inside $name")
                    out?.write(buf, 0, n)
                    md?.update(buf, 0, n)
                    left -= n
                }
            } finally {
                out?.close()
            }
            if (md != null) sums[name] = md.digest().joinToString("") { "%02x".format(it) }
            // Each entry is padded to 512 bytes.
            var pad = ((512 - size % 512) % 512).toInt()
            while (pad > 0) {
                val n = tar.read(buf, 0, pad)
                if (n < 0) break
                pad -= n
            }
        }
    }
    }

    /**
     * [input] (the whole of [spec]'s file) put in [dir]: as one file, or cut into its parts as it streams by. Kept
     * only when its size and sha256 are the pinned ones; nothing half-written is left behind. [onBytes] gets the
     * bytes read so far.
     */
    private fun place(input: java.io.InputStream, dir: File, spec: Spec, what: String, onBytes: (Long) -> Unit) {
        val parts = spec.split.ifEmpty { listOf(Part(spec.path, 0, spec.size)) }
        val temps = parts.map { File(dir, it.path + ".part").also { f -> f.parentFile?.mkdirs() } }
        val digest = MessageDigest.getInstance("SHA-256")
        var at = 0L
        var i = 0
        var out: java.io.OutputStream? = null
        try {
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
                // Each byte goes to the part whose range holds it, if any (the container's own headers go nowhere).
                var off = 0
                while (off < n) {
                    while (i < parts.size && at + off >= parts[i].end) {
                        out?.close()
                        out = null
                        i++
                    }
                    if (i >= parts.size) break
                    val p = parts[i]
                    val pos = at + off
                    if (pos < p.begin) {
                        off += minOf((p.begin - pos), (n - off).toLong()).toInt()
                        continue
                    }
                    val take = minOf(p.end - pos, (n - off).toLong()).toInt()
                    if (out == null) out = temps[i].outputStream()
                    out!!.write(buf, off, take)
                    off += take
                }
                at += n
                onBytes(at)
                if (at > spec.size) break
            }
        } catch (e: Exception) {
            out?.close()
            temps.forEach { it.delete() }
            throw e
        } finally {
            out?.close()
        }
        val sha = digest.digest().joinToString("") { "%02x".format(it) }
        if (at != spec.size || (spec.sha256.isNotEmpty() && sha != spec.sha256)) {
            temps.forEach { it.delete() }
            throw IllegalStateException("$what did not come down whole (size or checksum differs). Try again.")
        }
        for ((p, t) in parts.zip(temps)) {
            if (!t.renameTo(File(dir, p.path))) throw IllegalStateException("could not place ${p.path}")
        }
    }

    /**
     * A file kept cut up that is here whole (downloaded or pushed before it was kept in parts): cut up here, from its
     * own bytes (its checksum checked again), and the whole copy let go.
     */
    private fun splitWhole(id: String) {
        val dir = File(root, id)
        for (spec in specsOf(id) ?: return) {
            if (spec.split.isEmpty()) continue
            val whole = File(dir, spec.path)
            if (present(dir, spec)) {
                whole.delete()
                continue
            }
            if (whole.length() != spec.size) continue
            try {
                whole.inputStream().buffered(1 shl 20).use { place(it, dir, spec, "$id/${spec.path}") {} }
                whole.delete()
            } catch (e: Exception) {
                android.util.Log.w("OfflineModels", "$id/${spec.path} not cut up: ${e.message}")
            }
        }
    }

    /** Take [id] (a downloaded model) off the phone. */
    @Synchronized
    fun remove(id: String) {
        if (id in downloadIds()) File(root, id).deleteRecursively()
    }

    /** Whether [id]'s files are in place in the app's folder (copied from the APK, downloaded, or pushed). */
    @Synchronized
    fun isReady(id: String): Boolean {
        val downloaded = id in downloadIds()
        if (inApk != null && !stamp.exists() && !downloaded) return false // still being copied out of the APK
        return filesPresent(id) && !File(root, "$id/.dal-meta").exists()
    }

    /** [id]'s folder, for the SDK's `directory`; null when it is not ready. */
    fun directory(id: String): String? = if (isReady(id)) File(root, id).absolutePath else null

    /**
     * Copy the bundled models into place when this APK's set differs from what was copied
     * last (first launch, an update). [progress] gets the bytes copied and the total.
     */
    @Synchronized
    fun install(progress: (Long, Long) -> Unit) {
        val manifest = inApk ?: return // nothing in the APK: pushed models are used where they are
        val text = manifest.toString()
        if (stamp.exists() && stamp.readText() == text && bundledIds().all(::filesPresent)) return
        val models = manifest.getJSONObject("models")
        val total = bundledIds().sumOf { id -> filesOf(id)!!.sumOf { it.second } }
        var done = 0L
        // A fresh install whose APK carries no model has no models folder yet: the stamp below needs one.
        root.mkdirs()
        stamp.delete()
        for (id in bundledIds()) {
            val dir = File(root, id)
            for ((path, size) in filesOf(id)!!) {
                val target = File(dir, path)
                if (target.length() == size) {
                    done += size
                    progress(done, total)
                    continue
                }
                target.parentFile?.mkdirs()
                val part = File(target.path + ".part")
                context.assets.open("models/$id/$path").use { input ->
                    part.outputStream().use { output ->
                        val buffer = ByteArray(1 shl 20)
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            output.write(buffer, 0, n)
                            done += n
                            progress(done, total)
                        }
                    }
                }
                if (!part.renameTo(target)) throw IllegalStateException("could not place $id/$path")
            }
            // Never leave the SDK's own download bookkeeping here: its presence would make the
            // SDK treat the folder as download-managed rather than as files we placed.
            File(dir, ".dal-meta").deleteRecursively()
        }
        // Downloaded files now kept cut up: cut up here once, rather than downloaded again.
        downloadIds().forEach(::splitWhole)
        // Models dropped from this build: their folders go (not those downloaded, which the APK no longer carries).
        val downloads = manifest.optJSONObject("downloads")
        root.listFiles()
            ?.filter { it.isDirectory && !models.has(it.name) && downloads?.has(it.name) != true }
            ?.forEach { it.deleteRecursively() }
        stamp.writeText(text)
    }

    private fun filesPresent(id: String): Boolean {
        val dir = File(root, id)
        return specsOf(id)?.all { present(dir, it) } ?: false
    }

    private fun filesOf(id: String): List<Pair<String, Long>>? {
        val model = bundled?.optJSONObject("models")?.optJSONObject(id)
            ?: bundled?.optJSONObject("downloads")?.optJSONObject(id) ?: return null
        val files = model.getJSONArray("files")
        return (0 until files.length()).map {
            val f = files.getJSONObject(it)
            f.getString("path") to f.getLong("size")
        }
    }
}
