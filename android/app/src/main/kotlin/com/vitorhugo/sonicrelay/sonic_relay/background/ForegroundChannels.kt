package com.vitorhugo.sonicrelay.sonic_relay.background

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Wires the foreground-service channels onto the process-lifetime FlutterEngine.
 *
 * These used to be registered from `MainActivity.configureFlutterEngine`, which runs on every
 * activity attach — while the engine that owns them is created, and starts running Dart, in
 * [com.vitorhugo.sonicrelay.sonic_relay.SonicRelayApplication] before any activity exists. That
 * mismatch broke the notification buttons two ways:
 *
 *  - Dart could subscribe to the event channel before an activity had ever registered a handler
 *    for it. `EventChannel.receiveBroadcastStream` reports that failure through
 *    `FlutterError.reportError` and never retries, so `onListen` — and with it
 *    [ForegroundBridge.attach] — was simply never reached, and every button press was dropped.
 *  - Re-registering on a later attach installs a fresh handler whose sink is null, and an
 *    already-subscribed Dart stream never re-sends `listen`, so `onListen` does not fire again.
 *
 * Registering here, once per process and before the Dart entrypoint runs, means the handlers are
 * always in place before Dart can subscribe and are never swapped out underneath it. The service
 * is driven entirely through `applicationContext`, so nothing here needs an activity.
 */
object ForegroundChannels {

    private const val METHOD_CHANNEL = "sonicrelay/foreground"
    private const val EVENT_CHANNEL = "sonicrelay/foreground/events"

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val intent = serviceIntent(appContext, SonicRelayForegroundService.ACTION_START).apply {
                        putExtra(SonicRelayForegroundService.EXTRA_TITLE, call.argument<String>("title"))
                        putExtra(SonicRelayForegroundService.EXTRA_BODY, call.argument<String>("body"))
                        putExtra(
                            SonicRelayForegroundService.EXTRA_RECONNECT,
                            call.argument<Boolean>("showReconnect") ?: false,
                        )
                        putExtra(
                            SonicRelayForegroundService.EXTRA_MICROPHONE,
                            call.argument<Boolean>("usesMicrophone") ?: false,
                        )
                    }
                    ContextCompat.startForegroundService(appContext, intent)
                    result.success(null)
                }
                "stop" -> {
                    val intent = serviceIntent(appContext, SonicRelayForegroundService.ACTION_STOP).apply {
                        putExtra(
                            SonicRelayForegroundService.EXTRA_ENDED_NOTICE,
                            call.argument<String>("endedNotice"),
                        )
                    }
                    // A running foreground service permits starting a service even from the
                    // background, so this is safe while backgrounded.
                    appContext.startService(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    ForegroundBridge.attach(events)
                }

                override fun onCancel(arguments: Any?) {
                    ForegroundBridge.detach()
                }
            },
        )
    }

    private fun serviceIntent(context: Context, action: String) =
        Intent(context, SonicRelayForegroundService::class.java).apply { this.action = action }
}
