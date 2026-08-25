package com.vitorhugo.sonicrelay.sonic_relay.background

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
import android.util.Log
import androidx.core.app.NotificationCompat
import com.vitorhugo.sonicrelay.sonic_relay.MainActivity
import com.vitorhugo.sonicrelay.sonic_relay.R

/**
 * A `mediaPlayback` foreground service that keeps the viewer process (WebRTC
 * receiver, signaling, audio playback) alive while the app is backgrounded
 * during an active stream. It shows a persistent notification with Open, Stop,
 * and (optionally) Reconnect actions, forwarding taps to Dart via
 * [ForegroundBridge]. No token or session data is ever placed in intents/extras.
 */
class SonicRelayForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    /**
     * The content last published, so the notification can be rebuilt verbatim when it has to be
     * re-asserted (see [ACTION_NOTIF_REASSERT]) without waiting for Dart to push the next update.
     */
    @Volatile
    private var lastContent: NotificationContent? = null

    private data class NotificationContent(
        val title: String,
        val body: String,
        val showReconnect: Boolean,
    )

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                val content = NotificationContent(
                    title = intent.getStringExtra(EXTRA_TITLE) ?: DEFAULT_TITLE,
                    body = intent.getStringExtra(EXTRA_BODY).orEmpty(),
                    showReconnect = intent.getBooleanExtra(EXTRA_RECONNECT, false),
                )
                lastContent = content
                startForegroundCompat(buildNotification(content))
                acquireWakeLock()
            }
            ACTION_NOTIF_STOP -> ForegroundBridge.emit("stop")
            ACTION_NOTIF_RECONNECT -> ForegroundBridge.emit("reconnect")
            ACTION_NOTIF_REASSERT -> reassertNotification()
            ACTION_STOP -> {
                val endedNotice = intent.getStringExtra(EXTRA_ENDED_NOTICE)
                lastContent = null
                releaseWakeLock()
                stopForegroundCompat()
                if (!endedNotice.isNullOrBlank()) postEndedNotice(endedNotice)
                stopSelf()
            }
        }
        // Do not auto-restart if the system kills us. The active stream state
        // (peer connection, signaling socket, audio) lives in the Dart isolate
        // hosted by the process-lifetime FlutterEngine (see
        // SonicRelayApplication), not in this service, so a bare restart here
        // could not resurrect it anyway — the user starts streams intentionally
        // and Dart re-drives the service on the next one.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Intentionally a no-op: this service (and the process/engine it keeps
        // alive) must keep running when the user swipes SonicRelay away from
        // recent apps while a stream is active — that's the whole point of
        // promoting to a foreground service. The default Service behavior
        // already doesn't stop the service on task removal, and the manifest
        // sets android:stopWithTask="false" explicitly; this override exists so
        // the intent is documented and a future edit doesn't accidentally add a
        // stopSelf() here. See issue #22.
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    /**
     * Re-posts the ongoing notification after the user swiped it away.
     *
     * Since Android 14 an ongoing foreground-service notification can be dismissed from the
     * shade even while the service keeps running, which left the stream playing with no visible
     * control surface and no way back to Stop/Reconnect. Re-posting from the notification's
     * delete intent restores it immediately, and only ever fires on an actual dismissal — there
     * is no polling and nothing to unwind, because the service stops this notification the
     * normal way via ACTION_STOP.
     */
    private fun reassertNotification() {
        val content = lastContent ?: return
        Log.i(TAG, "ongoing notification dismissed; re-posting")
        startForegroundCompat(buildNotification(content))
    }

    /**
     * A partial wake lock for the life of the active stream. The mediaPlayback
     * foreground service keeps the *process* alive, but with the screen locked
     * Doze can still throttle the CPU/network enough to starve WebRTC audio or
     * stall the Dart reconnect loop; the wake lock keeps both running. It is
     * released the moment the stream stops, so it never outlives the
     * user-visible notification.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "SonicRelay:StreamPlayback",
        ).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun buildNotification(content: NotificationContent): Notification {
        ensureChannel()
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(content.title)
            .setContentText(content.body)
            // Ranked as high as an app may ask for, so the live stream sits at the top of the
            // shade instead of collapsing into the silent section with the rest of the
            // background noise. PRIORITY_MAX covers pre-O, the channel importance covers O+.
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(false)
            // Prominent, but never noisy: this is posted and updated repeatedly through a long
            // listening session and must not buzz or ping on every state change.
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            // Show immediately instead of after the system's ~10s grace period, so a stream
            // that starts and is backgrounded straight away is never briefly uncontrollable.
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            // Tapping the body, and the Open action, go straight to the activity. They used to
            // route through this service, which then called startActivity() from the
            // background — the exact thing Android 10+ blocks.
            .setContentIntent(openIntent())
            .setDeleteIntent(serviceActionIntent(ACTION_NOTIF_REASSERT))
            .addAction(0, "Open", openIntent())
            .addAction(0, "Stop", serviceActionIntent(ACTION_NOTIF_STOP))
        if (content.showReconnect) {
            builder.addAction(0, "Reconnect", serviceActionIntent(ACTION_NOTIF_RECONNECT))
        }
        return builder.build()
    }

    private fun postEndedNotice(text: String) {
        ensureChannel()
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(DEFAULT_TITLE)
            .setContentText(text)
            .setAutoCancel(true)
            .setSilent(true)
            .setContentIntent(openIntent())
            .build()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(ENDED_NOTICE_ID, notification)
    }

    private fun serviceActionIntent(action: String): PendingIntent {
        val intent = Intent(this, SonicRelayForegroundService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(this, action.hashCode(), intent, pendingIntentFlags())
    }

    private fun openIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(this, OPEN_REQUEST_CODE, intent, pendingIntentFlags())
    }

    private fun pendingIntentFlags(): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // A channel's importance can only ever be lowered after creation, so raising it required
        // a new channel id; drop the old low-importance one so it doesn't linger in settings.
        manager.deleteNotificationChannel(LEGACY_CHANNEL_ID)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background streaming",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Shown while SonicRelay keeps playing audio in the background."
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_START = "com.vitorhugo.sonicrelay.action.START"
        const val ACTION_UPDATE = "com.vitorhugo.sonicrelay.action.UPDATE"
        const val ACTION_STOP = "com.vitorhugo.sonicrelay.action.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_RECONNECT = "showReconnect"
        const val EXTRA_ENDED_NOTICE = "endedNotice"

        private const val TAG = "SonicRelayService"

        private const val ACTION_NOTIF_STOP = "com.vitorhugo.sonicrelay.action.NOTIF_STOP"
        private const val ACTION_NOTIF_RECONNECT =
            "com.vitorhugo.sonicrelay.action.NOTIF_RECONNECT"
        private const val ACTION_NOTIF_REASSERT =
            "com.vitorhugo.sonicrelay.action.NOTIF_REASSERT"

        // Safety valve so a leaked lock can never drain the battery for more
        // than one long listening session; ACTION_UPDATE re-acquires (refreshes)
        // it while the stream is actually alive.
        private const val WAKE_LOCK_TIMEOUT_MS = 4L * 60 * 60 * 1000

        private const val LEGACY_CHANNEL_ID = "sonicrelay_background_stream"
        private const val CHANNEL_ID = "sonicrelay_background_stream_v2"
        private const val NOTIFICATION_ID = 4201
        private const val ENDED_NOTICE_ID = 4202
        private const val OPEN_REQUEST_CODE = 4203
        private const val DEFAULT_TITLE = "SonicRelay"
    }
}
