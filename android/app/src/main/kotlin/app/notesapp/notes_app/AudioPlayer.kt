package app.notesapp.notes_app

import android.content.Context
import android.media.MediaPlayer
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Plays a recording's audio in its note (lib/features/notes/audio_player.dart): a file path or a content:// URI (a
 * picked notes folder). One at a time; the Dart side asks for the position while it plays.
 */
class AudioPlayer(private val context: Context, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "notes/player")
    private var player: MediaPlayer? = null
    private var source: String? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "play" -> {
                        val uri = call.argument<String>("uri")!!
                        val at = call.argument<Int>("at") ?: -1
                        val p = player?.takeIf { source == uri } ?: open(uri)
                        if (at >= 0) p.seekTo(at)
                        p.start()
                        result.success(state())
                    }
                    "pause" -> {
                        player?.takeIf { it.isPlaying }?.pause()
                        result.success(state())
                    }
                    "seek" -> {
                        player?.seekTo(call.argument<Int>("at") ?: 0)
                        result.success(state())
                    }
                    "state" -> result.success(state())
                    "stop" -> {
                        release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                release()
                result.error("player", e.message ?: "the audio could not be played", null)
            }
        }
    }

    private fun open(uri: String): MediaPlayer {
        release()
        val p = MediaPlayer()
        if (uri.startsWith("content://")) p.setDataSource(context, Uri.parse(uri)) else p.setDataSource(uri)
        p.prepare()
        p.setOnCompletionListener { channel.invokeMethod("ended", source) }
        player = p
        source = uri
        return p
    }

    private fun state(): Map<String, Any?> {
        val p = player
        return mapOf(
            "uri" to source,
            "playing" to (p?.isPlaying ?: false),
            "position" to (p?.currentPosition ?: 0),
            "duration" to (p?.duration ?: 0),
        )
    }

    private fun release() {
        player?.release()
        player = null
        source = null
    }
}
