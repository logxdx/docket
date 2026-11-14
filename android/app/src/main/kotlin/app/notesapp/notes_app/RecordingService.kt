package app.notesapp.notes_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps a recording going, and its processing at full speed, with nothing of the app on
 * screen:
 *
 *  - while the microphone records: a foreground service of type `microphone`, or Android hands
 *    a backgrounded app silence, and a meeting recorded with the screen locked would come out
 *    blank after the first minute;
 *  - while the models clean and transcribe: type `dataSync`, or Android moves a backgrounded
 *    app onto its slow cores (and may stop it) halfway through Voz;
 *
 * each with a partial wake lock, so the CPU keeps working with the screen off. The notification
 * says which ("Recording", "Transcribing on this phone") and opens the app. It goes when both end.
 */
class RecordingService : Service() {
    companion object {
        private const val CHANNEL = "recording"
        private const val ID = 71

        @Volatile private var recording = false
        @Volatile private var working: String? = null

        /** The microphone is recording, or stopped. Call from the foreground (Android allows only that). */
        fun recording(context: Context, on: Boolean) {
            recording = on
            refresh(context)
        }

        /** The models are working on [what] ("Transcribing on this phone"), or done (null). */
        fun working(context: Context, what: String?) {
            working = what
            refresh(context)
        }

        private fun refresh(context: Context) {
            if (!recording && working == null) {
                context.stopService(Intent(context, RecordingService::class.java))
                return
            }
            try {
                context.startForegroundService(Intent(context, RecordingService::class.java))
            } catch (e: Exception) {
                // Not allowed from the background (Android 12+): the work goes on, slower, while the app lives.
            }
        }

        private fun build(context: Context): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL) == null) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notify)
                .setContentTitle(if (recording) "Recording" else (working ?: "Docket"))
                .setContentText(if (recording) "Tap to return to Docket" else "On this phone, nothing sent anywhere")
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .build()
        }
    }

    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!recording && working == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        var type = 0
        if (recording) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (working != null) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(ID, build(this), type) else startForeground(ID, build(this))
        } catch (e: Exception) {
            // Refused (no microphone permission, or started from the background): the app goes on without it.
            stopSelf()
            return START_NOT_STICKY
        }
        if (wake == null) {
            wake = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "notes:recording")
                // A recording is at most 30 minutes, and its processing a few more; never held forever.
                .apply { acquire(90 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    // Android 15 limits dataSync time: its time is up, so it must stop now.
    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()

    @Deprecated("Android 14; the two-argument one after")
    override fun onTimeout(startId: Int) = stopSelf()

    override fun onDestroy() {
        wake?.takeIf { it.isHeld }?.release()
        wake = null
        super.onDestroy()
    }
}
