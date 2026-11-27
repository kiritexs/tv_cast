package com.kiritex.tv_cast

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall

/** What the notification shows, in the app's own words. */
data class CastNotice(
    val title: String,
    val text: String,
    val playing: Boolean,
    val channelName: String,
    val playLabel: String,
    val pauseLabel: String,
    val stopLabel: String,
) {
    companion object {
        val EMPTY = CastNotice("", "", true, "", "Play", "Pause", "Stop")

        fun from(call: MethodCall) = CastNotice(
            title = call.argument<String>("title") ?: "",
            text = call.argument<String>("text") ?: "",
            playing = call.argument<Boolean>("playing") ?: true,
            channelName = call.argument<String>("channelName") ?: "",
            playLabel = call.argument<String>("playLabel") ?: "Play",
            pauseLabel = call.argument<String>("pauseLabel") ?: "Pause",
            stopLabel = call.argument<String>("stopLabel") ?: "Stop",
        )
    }
}

/**
 * Keeps the app's process serving and driving a TV while it isn't in front:
 * a foreground service of the mediaPlayback type showing what plays with
 * play, pause and stop, a partial wake lock and a Wi-Fi lock while it runs.
 * It plays nothing itself; Dart's relay serves the TV, in this process.
 */
class CastKeepAliveService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A control pressed on the notification: told to Dart, nothing else.
        when (intent?.action) {
            ACTION_PLAY, ACTION_PAUSE, ACTION_STOP -> {
                report(intent.action!!)
                return START_NOT_STICKY
            }
        }
        // First thing: Android stops an app whose service doesn't in time.
        try {
            ensureChannel(this, current.channelName)
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                build(this, current),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Android 12+ refuses one started while the app isn't in front;
            // reported, never a crash. The TV plays on while the app lives.
            Log.w(TAG, "foreground refused: $e")
            stopSelf()
            report(EVENT_REFUSED)
            return START_NOT_STICKY
        }
        running = true
        holdLocks(this)
        report(EVENT_HELD)
        // Killed, it isn't started again: Dart, which serves the TV, went too.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "TvCast"
        private const val NOTIFICATION_ID = 0x0CA5
        private const val CHANNEL_ID = "tv_cast"
        private const val LOCK_TAG = "tv_cast:casting"

        // Renewed with every update; a video changes or pauses well within
        // it.
        private const val WAKE_LOCK_MS = 4 * 60 * 60 * 1000L

        const val ACTION_PLAY = "play"
        const val ACTION_PAUSE = "pause"
        const val ACTION_STOP = "stop"
        const val EVENT_HELD = "held"
        const val EVENT_REFUSED = "refused"

        /** The plugin, told of each event and control on the main thread. */
        var listener: ((String) -> Unit)? = null

        private var current = CastNotice.EMPTY
        private var running = false
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null

        /** False when Android refused to start it (the app isn't in front). */
        fun start(context: Context, notice: CastNotice): Boolean {
            current = notice
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, CastKeepAliveService::class.java),
                )
                true
            } catch (e: Exception) {
                Log.w(TAG, "not started: $e")
                false
            }
        }

        fun update(context: Context, notice: CastNotice) {
            current = notice
            if (!running) return
            holdLocks(context)
            if (!canNotify(context)) return
            ensureChannel(context, notice.channelName)
            NotificationManagerCompat.from(context)
                .notify(NOTIFICATION_ID, build(context, notice))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CastKeepAliveService::class.java))
        }

        private fun report(event: String) {
            listener?.invoke(event)
        }

        private fun canNotify(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED

        /** Created once; its name follows the app's language. */
        private fun ensureChannel(context: Context, name: String) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                name.ifEmpty { "Casting" },
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }

        private fun build(context: Context, notice: CastNotice): Notification {
            val toggle = if (notice.playing) {
                NotificationCompat.Action(
                    android.R.drawable.ic_media_pause,
                    notice.pauseLabel,
                    control(context, ACTION_PAUSE, 1),
                )
            } else {
                NotificationCompat.Action(
                    android.R.drawable.ic_media_play,
                    notice.playLabel,
                    control(context, ACTION_PLAY, 2),
                )
            }
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(notice.title)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setForegroundServiceBehavior(
                    NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE,
                )
                .addAction(toggle)
                .addAction(
                    NotificationCompat.Action(
                        android.R.drawable.ic_menu_close_clear_cancel,
                        notice.stopLabel,
                        control(context, ACTION_STOP, 3),
                    ),
                )
            if (notice.text.isNotEmpty()) builder.setContentText(notice.text)
            openApp(context)?.let { builder.setContentIntent(it) }
            return builder.build()
        }

        /** A control: delivered to the running service, which tells Dart. */
        private fun control(context: Context, action: String, code: Int): PendingIntent =
            PendingIntent.getService(
                context,
                code,
                Intent(context, CastKeepAliveService::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun openApp(context: Context): PendingIntent? {
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName) ?: return null
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(
                context,
                0x0CA5,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun holdLocks(context: Context) {
            val app = context.applicationContext
            val wake = wakeLock ?: (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)
                .also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
            wake.acquire(WAKE_LOCK_MS)
            if (wifiLock == null) {
                val wifi = app.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                // The TV fetches from this phone: its Wi-Fi mustn't doze.
                @Suppress("DEPRECATION")
                wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, LOCK_TAG)
                    ?.also {
                        it.setReferenceCounted(false)
                        it.acquire()
                    }
            }
        }

        private fun releaseLocks() {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }
}
