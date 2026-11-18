package app.notesapp.notes_app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Installing Docket's own updates (lib/app/updates.dart): the downloaded APK, already checked against its release's
 * SHA256SUMS, written into a PackageInstaller session; Android's installer then asks the user, as it always does.
 * Android only installs it over Docket when it is signed as the installed app is (tool/sign_apk.sh).
 */
class UpdateInstaller(private val activity: Activity) {
    private var waiting: MethodChannel.Result? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                // The user's say: Android's confirmation, on top of Docket.
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val confirm = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }
                    confirm?.let { activity.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                }
                PackageInstaller.STATUS_SUCCESS -> finish(null)
                PackageInstaller.STATUS_FAILURE_ABORTED -> finish("The update was not installed.")
                else -> finish(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "The update was not installed.")
            }
        }
    }

    init {
        val filter = IntentFilter(ACTION)
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag") activity.registerReceiver(receiver, filter)
        }
    }

    fun close() = activity.unregisterReceiver(receiver)

    private fun finish(problem: String?) {
        val result = waiting ?: return
        waiting = null
        if (problem == null) result.success(true) else result.error("install", problem, null)
    }

    /** Whether Android lets Docket install apps (asked once, in its settings). */
    fun canInstall(): Boolean = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()

    /** Android's setting for it: "Allow from this source". */
    fun allowInstalls() {
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
        )
    }

    fun install(path: String, result: MethodChannel.Result) {
        waiting?.error("install", "Another install started.", null)
        waiting = result
        Thread {
            try {
                val file = File(path)
                val installer = activity.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(activity.packageName)
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    session.openWrite("update.apk", 0, file.length()).use { out ->
                        file.inputStream().use { it.copyTo(out) }
                        session.fsync(out)
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val done = PendingIntent.getBroadcast(activity, id, Intent(ACTION).setPackage(activity.packageName), flags)
                    session.commit(done.intentSender)
                }
            } catch (e: Exception) {
                activity.runOnUiThread { finish(e.message ?: "The update was not installed.") }
            }
        }.start()
    }

    /** [path]'s sha256, lowercase hex. */
    fun sha256(path: String, result: MethodChannel.Result) = Thread {
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            File(path).inputStream().use { input ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            val hex = digest.digest().joinToString("") { "%02x".format(it) }
            activity.runOnUiThread { result.success(hex) }
        } catch (e: Exception) {
            activity.runOnUiThread { result.error("sha256", e.message, null) }
        }
    }.start()

    private companion object {
        const val ACTION = "app.notesapp.notes_app.UPDATE_INSTALLED"
    }
}
