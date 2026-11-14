package app.notesapp.notes_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var askingMic: MethodChannel.Result? = null
    private var pickingFile: MethodChannel.Result? = null
    private var pickingMany: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // A recording's audio in its note (lib/features/notes/audio_player.dart).
        AudioPlayer(applicationContext, flutterEngine)
        // Recording, and Desert Ant's on-device models (lib/app/desert_ant.dart).
        DesertAntBridge(applicationContext, flutterEngine)
        // The microphone permission, asked when recording starts; and opening a link.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notes/permissions").setMethodCallHandler { call, result ->
            when (call.method) {
                "microphone" -> {
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        askingMic?.success(false)
                        askingMic = result
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC)
                    }
                }
                // A file the user picks (a voice of their own): copied into the cache; its path and name, or null.
                "pickFile" -> {
                    pickingFile?.success(null)
                    pickingFile = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                    try {
                        startActivityForResult(intent, PICK)
                    } catch (e: Exception) {
                        pickingFile = null
                        result.error("pick", "No file picker on this phone", null)
                    }
                }
                // Files the user picks (a model to import: its files, or a .zip of them): references only, not copies.
                "pickFiles" -> {
                    pickingMany?.success(null)
                    pickingMany = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                        .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    try {
                        startActivityForResult(intent, PICK_MANY)
                    } catch (e: Exception) {
                        pickingMany = null
                        result.error("pick", "No file picker on this phone", null)
                    }
                }
                // A web link the user tapped (Settings: the Desert Ant Labs credit).
                "open" -> {
                    val ok = try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                        true
                    } catch (_: Exception) {
                        false
                    }
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Activity result API; FlutterActivity has no AndroidX registry")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_MANY) {
            val many = pickingMany ?: return
            pickingMany = null
            if (resultCode != RESULT_OK || data == null) {
                many.success(null)
                return
            }
            val uris = buildList {
                data.clipData?.let { clip -> for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri) }
                if (isEmpty()) data.data?.let { add(it) }
            }
            many.success(uris.map { it.toString() })
            return
        }
        if (requestCode != PICK) return
        val result = pickingFile ?: return
        pickingFile = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        Thread {
            try {
                var name = "voice"
                contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val copy = java.io.File.createTempFile("picked", ".bin", cacheDir)
                // A voice file is 256 KB; anything far bigger is not one, and is not copied whole.
                contentResolver.openInputStream(uri)!!.use { input ->
                    copy.outputStream().use { out ->
                        val buf = ByteArray(1 shl 16)
                        var total = 0L
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            total += n
                            if (total > 64L shl 20) break
                            out.write(buf, 0, n)
                        }
                    }
                }
                runOnUiThread { result.success(mapOf("path" to copy.path, "name" to name)) }
            } catch (e: Exception) {
                runOnUiThread { result.error("pick", e.message ?: "The file could not be read", null) }
            }
        }.start()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC) {
            askingMic?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            askingMic = null
        }
    }

    private companion object {
        const val MIC = 7301
        const val PICK = 7302
        const val PICK_MANY = 7303
    }
}
