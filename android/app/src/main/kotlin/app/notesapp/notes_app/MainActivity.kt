package app.notesapp.notes_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var askingMic: MethodChannel.Result? = null
    private var pickingFile: MethodChannel.Result? = null
    private var pickLimit: Long? = null

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
                // Whether the microphone is allowed already, without asking (the primer comes before the asking).
                "micGranted" -> result.success(
                    checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
                )
                // The connection: online at all, and metered (mobile data) or not; downloads wait for Wi-Fi.
                "network" -> {
                    val cm = getSystemService(ConnectivityManager::class.java)
                    val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
                    val online = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                    result.success(mapOf("online" to online, "metered" to (online && cm?.isActiveNetworkMetered == true)))
                }
                // A file the user picks (a picture or a sound for a note, a voice of their own): copied into the
                // cache; its path and name, or null. A file over maxBytes (when given) is refused, not cut short.
                "pickFile" -> {
                    pickingFile?.success(null)
                    pickingFile = result
                    pickLimit = call.argument<Number>("maxBytes")?.toLong()
                    // A kind of file when asked for ("image/*" for a picture to add to a note), else any.
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(call.argument<String>("mime") ?: "*/*")
                    try {
                        startActivityForResult(intent, PICK)
                    } catch (e: Exception) {
                        pickingFile = null
                        result.error("pick", "No file picker on this phone", null)
                    }
                }
                // How long a sound file plays, in ms; null when it is not one Android can read.
                "audioLength" -> Thread {
                    val ms = try {
                        android.media.MediaMetadataRetriever().run {
                            try {
                                setDataSource(call.argument<String>("path"))
                                extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                            } finally {
                                release()
                            }
                        }
                    } catch (_: Exception) {
                        null
                    }
                    runOnUiThread { result.success(ms) }
                }.start()
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
        if (requestCode != PICK) return
        val result = pickingFile ?: return
        pickingFile = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        val limit = pickLimit
        Thread {
            try {
                var name = "file"
                contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val copy = java.io.File.createTempFile("picked", ".bin", cacheDir)
                var tooBig = false
                contentResolver.openInputStream(uri)!!.use { input ->
                    copy.outputStream().use { out ->
                        val buf = ByteArray(1 shl 16)
                        var total = 0L
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            total += n
                            if (limit != null && total > limit) {
                                tooBig = true
                                break
                            }
                            out.write(buf, 0, n)
                        }
                    }
                }
                if (tooBig) {
                    copy.delete()
                    runOnUiThread { result.error("pick", "That file is too large", null) }
                } else {
                    runOnUiThread { result.success(mapOf("path" to copy.path, "name" to name)) }
                }
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
    }
}
