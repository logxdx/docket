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

    /** How many bytes [id] takes, all its files together. */
    fun sizeOf(id: String): Long = filesOf(id)?.sumOf { it.second } ?: 0L

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
        val files = model.getJSONArray("files")
        val specs = (0 until files.length()).map {
            val f = files.getJSONObject(it)
            // A JSON null (no checksum pinned) is no checksum, not the text "null".
            Triple(f.getString("path"), f.getLong("size"), if (f.isNull("sha256")) "" else f.optString("sha256"))
        }
        val total = specs.sumOf { it.second }
        val dir = File(root, id)
        var done = 0L
        cancelled -= id
        for ((path, size, sha256) in specs) {
            val target = File(dir, path)
            if (target.length() == size) {
                done += size
                progress(done, total)
                continue
            }
            target.parentFile?.mkdirs()
            val part = File(target.path + ".part")
            val digest = MessageDigest.getInstance("SHA-256")
            var got = 0L
            val connection = URL("https://huggingface.co/$repo/resolve/$revision/$path").openConnection() as HttpURLConnection
            connection.connectTimeout = 20_000
            connection.readTimeout = 60_000
            connection.instanceFollowRedirects = true
            try {
                if (connection.responseCode !in 200..299) {
                    throw IllegalStateException("Hugging Face answered ${connection.responseCode} for $id/$path.")
                }
                connection.inputStream.use { input ->
                    part.outputStream().use { out ->
                        val buf = ByteArray(1 shl 20)
                        while (true) {
                            if (id in cancelled) throw InterruptedException("Download stopped.")
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            digest.update(buf, 0, n)
                            got += n
                            progress(done + got, total)
                            if (got > size) break
                        }
                    }
                }
            } catch (e: Exception) {
                part.delete()
                throw e
            } finally {
                connection.disconnect()
            }
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            if (got != size || (sha256.isNotEmpty() && sha != sha256)) {
                part.delete()
                throw IllegalStateException("$id/$path did not come down whole (size or checksum differs). Try again.")
            }
            if (!part.renameTo(target)) throw IllegalStateException("could not place $id/$path")
            done += size
        }
        File(dir, ".dal-meta").deleteRecursively()
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
        // Models dropped from this build: their folders go (not those downloaded, which the APK no longer carries).
        val downloads = manifest.optJSONObject("downloads")
        root.listFiles()
            ?.filter { it.isDirectory && !models.has(it.name) && downloads?.has(it.name) != true }
            ?.forEach { it.deleteRecursively() }
        stamp.writeText(text)
    }

    private fun filesPresent(id: String): Boolean {
        val dir = File(root, id)
        return filesOf(id)?.all { (path, size) -> File(dir, path).length() == size } ?: false
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
