package app.notesapp.notes_app

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * The Desert Ant models, on this phone with no network: the APK carries them as assets
 * (assets/models/<id>/..., put there by tool/fetch_models.py), and the first launch after an
 * install or update copies them to the app's own folder, because the SDKs open real files.
 * A build without them (NOTES_BUNDLE_MODELS=0) takes the same folder pushed over USB instead
 * (tool/push_models.sh), described by the manifest.json pushed with it.
 * A model's folder is then handed to its SDK as `directory`; a folder the SDK finds already
 * filled (and without its own download bookkeeping) is used as-is, with no network.
 *
 * A model that is not in the APK is reported missing and never constructed, so no SDK is
 * ever asked to download.
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

    /** Models the APK leaves out but the user can import (Voz), with their files pinned. */
    fun importableIds(): List<String> {
        val models = bundled?.optJSONObject("importable") ?: return emptyList()
        return models.keys().asSequence().toList()
    }

    /**
     * Import [id] (an importable model) from [sources]: each a file name and a way to open it, as the user picked
     * them (the model's files, or a .zip holding them, unpacked by the caller). A file is kept only when its size
     * and sha256 are the pinned ones; the model is ready only when all its files are. [progress] gets bytes done
     * and the total. Throws with what is missing or wrong; then nothing of it is kept.
     */
    @Synchronized
    fun import(id: String, sources: Sequence<Pair<String, () -> InputStream>>, progress: (Long, Long) -> Unit) {
        val model = bundled?.optJSONObject("importable")?.optJSONObject(id)
            ?: throw IllegalArgumentException("$id cannot be imported")
        val files = model.getJSONArray("files")
        val wanted = (0 until files.length()).associate {
            val f = files.getJSONObject(it)
            // A JSON null (no checksum pinned) is no checksum, not the text "null".
            val sha = if (f.isNull("sha256")) "" else f.optString("sha256")
            f.getString("path").substringAfterLast('/') to Triple(f.getString("path"), f.getLong("size"), sha)
        }
        val total = wanted.values.sumOf { it.second }
        val dir = File(root, id)
        val done = HashSet<String>()
        var copied = 0L
        try {
            for ((name, open) in sources) {
                val spec = wanted[name.substringAfterLast('/')] ?: continue
                if (spec.first in done) continue
                val target = File(dir, spec.first)
                target.parentFile?.mkdirs()
                val part = File(target.path + ".part")
                val digest = MessageDigest.getInstance("SHA-256")
                var size = 0L
                open().use { input ->
                    part.outputStream().use { out ->
                        val buf = ByteArray(1 shl 20)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            digest.update(buf, 0, n)
                            size += n
                            copied += n
                            progress(copied, total)
                            if (size > spec.second) break
                        }
                    }
                }
                val sha = digest.digest().joinToString("") { "%02x".format(it) }
                if (size != spec.second || (spec.third.isNotEmpty() && sha != spec.third)) {
                    part.delete()
                    throw IllegalArgumentException("${spec.first} is not the right file (size or checksum differs).")
                }
                if (!part.renameTo(target)) throw IllegalStateException("could not place ${spec.first}")
                done += spec.first
            }
            val missing = wanted.values.map { it.first }.filter { it !in done && File(dir, it).length() != wanted[it.substringAfterLast('/')]!!.second }
            if (missing.isNotEmpty()) throw IllegalArgumentException("Missing: ${missing.joinToString(", ")}.")
        } catch (e: Exception) {
            dir.deleteRecursively()
            throw e
        }
        File(dir, ".dal-meta").deleteRecursively()
    }

    /** Whether [id]'s files are in place in the app's folder (copied from the APK, imported, or pushed). */
    @Synchronized
    fun isReady(id: String): Boolean {
        val imported = id in importableIds()
        if (inApk != null && !stamp.exists() && !imported) return false // still being copied out of the APK
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
        // Models dropped from this build: their folders go (not those the user imported, nor their voices).
        val importable = manifest.optJSONObject("importable")
        root.listFiles()
            ?.filter { it.isDirectory && !models.has(it.name) && importable?.has(it.name) != true }
            ?.forEach { it.deleteRecursively() }
        stamp.writeText(text)
    }

    private fun filesPresent(id: String): Boolean {
        val dir = File(root, id)
        return filesOf(id)?.all { (path, size) -> File(dir, path).length() == size } ?: false
    }

    private fun filesOf(id: String): List<Pair<String, Long>>? {
        val model = bundled?.optJSONObject("models")?.optJSONObject(id)
            ?: bundled?.optJSONObject("importable")?.optJSONObject(id) ?: return null
        val files = model.getJSONArray("files")
        return (0 until files.length()).map {
            val f = files.getJSONObject(it)
            f.getString("path") to f.getLong("size")
        }
    }
}
