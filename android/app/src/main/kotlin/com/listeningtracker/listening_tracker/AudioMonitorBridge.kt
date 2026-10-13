package com.listeningtracker.listening_tracker

import android.app.Activity
import android.app.ForegroundServiceStartNotAllowedException
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.regex.Pattern

/**
 * Unified coordination bridge connecting:
 * 1. AudioMonitorEngine (native detection)
 * 2. AudioMonitorService (persistent foreground service)
 * 3. FlutterEngine (Dart SessionEngine and UI)
 * 4. System Bluetooth connection events (Receiver & CompanionDeviceService)
 */
object AudioMonitorBridge {

    private const val TAG = "AudioMonitorBridge"
    const val FLUTTER_ENGINE_ID = "listening_tracker_flutter_engine"
    const val METHOD_CHANNEL = "com.listeningtracker/audio_monitor"
    const val EVENT_CHANNEL = "com.listeningtracker/audio_events"
    private const val ALERT_NOTIFICATION_ID = 2002
    private const val ALERT_CHANNEL_ID = "listening_tracker_alerts"

    private val mainHandler = Handler(Looper.getMainLooper())

    var monitorEngine: AudioMonitorEngine? = null
        private set

    private var eventSink: EventChannel.EventSink? = null
    private val pendingEvents = ArrayDeque<Map<String, Any?>>()
    private var cachedFlutterEngine: FlutterEngine? = null
    private var attachedActivity: Activity? = null
    private var appContext: Context? = null

    fun getOrCreateMonitorEngine(context: Context): AudioMonitorEngine {
        val appCtx = context.applicationContext
        appContext = appCtx

        val existing = monitorEngine
        if (existing != null) return existing

        val engine = AudioMonitorEngine(appCtx)
        monitorEngine = engine
        AudioMonitorService.monitorEngine = engine

        engine.eventListener = object : AudioEventListener {
            override fun onEvent(event: AudioEvent) {
                mainHandler.post {
                    Log.d(TAG, "Forwarding event to Flutter: ${event.type}")
                    val payload = event.toMap()
                    val sink = eventSink
                    if (sink != null) sink.success(payload) else {
                        synchronized(pendingEvents) {
                            if (pendingEvents.size >= 100) pendingEvents.removeFirst()
                            pendingEvents.addLast(payload)
                        }
                        NativeLifecycleDiagnostics.record(appCtx, "NATIVE_EVENT_BUFFERED", mapOf("eventType" to event.type.name))
                    }
                }
            }
        }

        engine.onMonitoringLifecycleRequested = { shouldStart ->
            mainHandler.post {
                if (shouldStart) {
                    startMonitoringWithService(appCtx)
                } else {
                    stopMonitoringWithService(appCtx)
                }
            }
        }

        engine.initialize()
        return engine
    }

    fun ensureFlutterEngine(context: Context): FlutterEngine {
        val appCtx = context.applicationContext
        appContext = appCtx

        val cached = FlutterEngineCache.getInstance().get(FLUTTER_ENGINE_ID)
        if (cached != null) {
            cachedFlutterEngine = cached
            return cached
        }

        Log.i(TAG, "Initializing FlutterEngine for Listening Tracker")
        val engine = FlutterEngine(appCtx)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(FLUTTER_ENGINE_ID, engine)
        cachedFlutterEngine = engine

        setupChannels(engine, null)
        return engine
    }

    fun setupChannels(engine: FlutterEngine, activity: Activity?) {
        if (activity != null) {
            attachedActivity = activity
            appContext = activity.applicationContext
        }

        val ctx = appContext ?: activity?.applicationContext
            ?: throw IllegalStateException("AudioMonitorBridge requires context before setupChannels")

        // MethodChannel
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                val currentEngine = getOrCreateMonitorEngine(ctx)

                when (call.method) {
                    "startMonitoring" -> {
                        result.success(startMonitoringWithService(ctx))
                    }
                    "stopMonitoring" -> {
                        stopMonitoringWithService(ctx)
                        result.success(true)
                    }
                    "getCurrentState" -> {
                        val state = currentEngine.getCurrentState()
                        result.success(state)
                    }
                    "checkPermissions" -> {
                        result.success(checkAllPermissions(ctx))
                    }
                    "requestPermissions" -> {
                        attachedActivity?.let { act ->
                            if (act is MainActivity) {
                                act.requestRequiredPermissions()
                            }
                        }
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations(ctx))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations(ctx)
                        result.success(true)
                    }
                    "isCompanionAssociated" -> {
                        result.success(isCompanionAssociated(ctx))
                    }
                    "associateCompanionDevice" -> {
                        val deviceNamePattern = call.argument<String>("namePattern") ?: ".*"
                        attachedActivity?.let { act ->
                            associateCompanionDevice(act, deviceNamePattern)
                            result.success(true)
                        } ?: run {
                            result.error("NO_ACTIVITY", "Cannot associate companion device without active Activity", null)
                        }
                    }
                    "shareLogFile" -> {
                        val content = call.argument<String>("content") ?: ""
                        val fileName = call.argument<String>("fileName") ?: "listening_tracker_diagnostic_logs.json"
                        val success = shareLogFile(ctx, content, fileName)
                        result.success(success)
                    }
                    "drainNativeLifecycleEvents" -> result.success(NativeLifecycleDiagnostics.drain(ctx))
                    "ackNativeLifecycleEvents" -> {
                        val ids = call.argument<List<String>>("ids")?.toSet() ?: emptySet()
                        NativeLifecycleDiagnostics.acknowledge(ctx, ids)
                        result.success(true)
                    }
                    "showBreakNotification" -> {
                        val id = call.argument<Int>("id") ?: BREAK_SOON_NOTIFICATION_ID
                        val title = call.argument<String>("title") ?: "Listening Break Reminder"
                        val body = call.argument<String>("body") ?: "Time to give your ears a rest."
                        val snoozeMinutes = call.argument<Int>("snoozeMinutes") ?: 10
                        val success = showBreakNotification(ctx, id, title, body, snoozeMinutes)
                        result.success(success)
                    }
                    "cancelBreakNotification" -> {
                        val id = call.argument<Int>("id") ?: BREAK_SOON_NOTIFICATION_ID
                        cancelBreakNotification(ctx, id)
                        result.success(true)
                    }
                    "cancelAllBreakNotifications" -> {
                        cancelAllBreakNotifications(ctx)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // EventChannel
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.d(TAG, "Flutter EventChannel opened")
                    eventSink = events
                    NativeLifecycleDiagnostics.record(ctx, "FLUTTER_EVENT_CHANNEL_SUBSCRIBED")

                    val buffered = synchronized(pendingEvents) {
                        pendingEvents.toList().also { pendingEvents.clear() }
                    }
                    buffered.forEach { events?.success(it) }
                    NativeLifecycleDiagnostics.record(ctx, "NATIVE_EVENT_BUFFER_DRAINED", mapOf("count" to buffered.size))

                    // Replay currently connected devices to the new Flutter subscriber
                    val engineRef = monitorEngine
                    if (engineRef != null && engineRef.isMonitoring) {
                        mainHandler.post {
                            val state = engineRef.getCurrentState()
                            Log.d(TAG, "Replaying current state snapshot on EventChannel subscription")
                            events?.success(mapOf("type" to "MONITORING_STATE_CHANGED", "isMonitoring" to true, "reason" to "subscription_snapshot", "timestamp" to System.currentTimeMillis()))
                            // Snapshot device events if devices already connected
                            val devices = state["connectedDevices"] as? List<*>
                            devices?.forEach { dev ->
                                if (dev is Map<*, *>) {
                                    events?.success(mapOf(
                                        "type" to AudioEventType.DEVICE_CONNECTED.name,
                                        "deviceId" to dev["id"],
                                        "deviceName" to dev["name"],
                                        "deviceType" to dev["typeName"],
                                        "connectionType" to dev["connectionType"],
                                        "deviceAddress" to dev["address"],
                                        "timestamp" to System.currentTimeMillis()
                                    ))
                                }
                            }
                            val isAudioPlaying = state["isAudioPlaying"] as? Boolean ?: false
                            if (isAudioPlaying) {
                                val activeDev = devices?.firstOrNull() as? Map<*, *>
                                events?.success(mapOf(
                                    "type" to AudioEventType.AUDIO_STARTED.name,
                                    "deviceId" to activeDev?.get("id"),
                                    "deviceName" to (state["outputDeviceName"] ?: activeDev?.get("name")),
                                    "deviceType" to (state["outputDeviceType"] ?: activeDev?.get("typeName")),
                                    "connectionType" to (state["outputConnectionType"] ?: activeDev?.get("connectionType")),
                                    "deviceAddress" to (state["outputDeviceAddress"] ?: activeDev?.get("address")),
                                    "isAudioPlaying" to true,
                                    "diagnostics" to "subscription_snapshot_playback_active",
                                    "timestamp" to System.currentTimeMillis()
                                ))
                            }
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    Log.d(TAG, "Flutter EventChannel closed")
                    eventSink = null
                }
            })
    }

    private var lastConnectedAddress: String? = null
    private var lastConnectedTimestamp: Long = 0L
    @Volatile private var lastServiceStartTimestamp: Long = 0L
    @Volatile private var lastServiceStartOrigin: String? = null

    fun handleBluetoothConnected(
        context: Context,
        deviceName: String,
        deviceAddress: String,
        startupPath: String = "bluetooth"
    ) {
        val now = System.currentTimeMillis()
        val isRecentDuplicate = deviceAddress.isNotBlank() &&
            deviceAddress.equals(lastConnectedAddress, ignoreCase = true) &&
            (now - lastConnectedTimestamp < 2500L)

        lastConnectedAddress = deviceAddress
        lastConnectedTimestamp = now

        Log.d(TAG, "handleBluetoothConnected: device=$deviceName, address=$deviceAddress, isRecentDuplicate=$isRecentDuplicate, startupPath=$startupPath")
        val appContext = context.applicationContext
        NativeLifecycleDiagnostics.record(appContext, "BLUETOOTH_CONNECTION_HANDLED", mapOf(
            "deviceName" to deviceName,
            "addressPresent" to deviceAddress.isNotBlank(),
            "isDuplicate" to isRecentDuplicate,
            "startupPath" to startupPath,
        ))

        // Dismiss any existing fallback alert notification
        dismissFallbackNotification(appContext)

        // 1. Initialize engine (fast native callback setup)
        val engine = getOrCreateMonitorEngine(appContext)

        // 2. Start foreground service IMMEDIATELY from background receiver.
        // CRITICAL FIX: Do NOT call ensureFlutterEngine() here! Cold-starting FlutterEngine synchronously
        // takes 20+ seconds on the main thread, causing Android's temporary BroadcastReceiver FGS exemption
        // (mAllowStartForeground) to expire and throw ForegroundServiceStartNotAllowedException.
        // Instead, start the service directly. AudioMonitorService.onStartCommand() promotes to foreground
        // immediately and then safely initializes FlutterEngine.
        if (!isRecentDuplicate && !engine.isMonitoring) {
            val serviceIntent = Intent(appContext, AudioMonitorService::class.java).apply {
                action = AudioMonitorService.ACTION_START_MONITORING
                putExtra(AudioMonitorService.EXTRA_DEVICE_NAME, deviceName)
                putExtra(AudioMonitorService.EXTRA_DEVICE_ADDRESS, deviceAddress)
                putExtra("origin", startupPath)
                putExtra("startupPath", startupPath)
            }

            NativeLifecycleDiagnostics.record(appContext, "SERVICE_START_REQUEST_DISPATCHED", mapOf(
                "origin" to startupPath,
                "startupPath" to startupPath,
                "deviceName" to deviceName,
                "addressPresent" to deviceAddress.isNotBlank(),
            ))

            try {
                ContextCompat.startForegroundService(appContext, serviceIntent)
                lastServiceStartTimestamp = now
                lastServiceStartOrigin = startupPath
                Log.i(TAG, "startForegroundService initiated successfully from $startupPath")
                NativeLifecycleDiagnostics.record(appContext, "SERVICE_START_REQUEST_ACCEPTED", mapOf(
                    "origin" to startupPath,
                    "startupPath" to startupPath,
                ))
            } catch (e: Exception) {
                val isFgsException = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && e is ForegroundServiceStartNotAllowedException
                Log.w(TAG, "Unable to start foreground service directly from $startupPath (${e.javaClass.simpleName}): ${e.message}")
                NativeLifecycleDiagnostics.record(appContext, "SERVICE_START_REQUEST_REJECTED", mapOf(
                    "origin" to startupPath,
                    "startupPath" to startupPath,
                    "error" to e.javaClass.name,
                    "message" to (e.message ?: ""),
                    "isForegroundServiceStartNotAllowed" to isFgsException,
                    "isIgnoringBatteryOptimizations" to isIgnoringBatteryOptimizations(appContext),
                    "isCompanionAssociated" to isCompanionAssociated(appContext),
                    "recoveryStrategy" to "direct_notification_action",
                ))
                showConnectionFallbackNotification(appContext, deviceName, deviceAddress, startupPath)
            }
        }

        // 3. Update engine device state without triggering redundant startMonitoring lifecycle requests
        engine.handleDeviceConnected(deviceName, deviceAddress, triggerLifecycleRequest = false)
    }

    fun handleBluetoothDisconnected(context: Context, deviceName: String, deviceAddress: String) {
        Log.d(TAG, "handleBluetoothDisconnected: device=$deviceName, address=$deviceAddress")
        val appContext = context.applicationContext

        lastConnectedAddress = null
        lastConnectedTimestamp = 0L

        dismissFallbackNotification(appContext)

        monitorEngine?.let { engine ->
            engine.handleDeviceDisconnected(deviceName, deviceAddress)
        }
    }

    fun notifyMonitoringState(context: Context, active: Boolean, reason: String? = null) {
        val payload = mapOf(
            "type" to "MONITORING_STATE_CHANGED",
            "isMonitoring" to active,
            "reason" to reason,
            "timestamp" to System.currentTimeMillis(),
        )
        mainHandler.post {
            val sink = eventSink
            if (sink != null) sink.success(payload) else synchronized(pendingEvents) {
                if (pendingEvents.size >= 100) pendingEvents.removeFirst()
                pendingEvents.addLast(payload)
            }
        }
    }

    fun startMonitoringWithService(context: Context, startupPath: String = "bridge"): Boolean {
        Log.d(TAG, "startMonitoringWithService requested from $startupPath")
        val appContext = context.applicationContext

        dismissFallbackNotification(appContext)
        val engine = getOrCreateMonitorEngine(appContext)
        ensureFlutterEngine(appContext)

        if (engine.isMonitoring) {
            Log.d(TAG, "Audio monitoring already active; skipping redundant service start request")
            return true
        }

        val now = System.currentTimeMillis()
        if (now - lastServiceStartTimestamp < 1500L) {
            Log.d(TAG, "Service start already in progress for recent request ($lastServiceStartOrigin); skipping duplicate start")
            return true
        }

        val serviceIntent = Intent(appContext, AudioMonitorService::class.java).apply {
            action = AudioMonitorService.ACTION_START_MONITORING
            putExtra("origin", startupPath)
            putExtra("startupPath", startupPath)
        }

        NativeLifecycleDiagnostics.record(appContext, "SERVICE_START_REQUEST_DISPATCHED", mapOf(
            "origin" to startupPath,
            "startupPath" to startupPath,
        ))

        try {
            ContextCompat.startForegroundService(appContext, serviceIntent)
            lastServiceStartTimestamp = now
            lastServiceStartOrigin = startupPath
            NativeLifecycleDiagnostics.record(appContext, "SERVICE_START_REQUEST_ACCEPTED", mapOf(
                "origin" to startupPath,
                "startupPath" to startupPath,
            ))
            return true
        } catch (e: Exception) {
            val isFgsException = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && e is ForegroundServiceStartNotAllowedException
            Log.w(TAG, "Foreground service start rejected ($startupPath): ${e.message}")
            NativeLifecycleDiagnostics.record(appContext, "SERVICE_START_REQUEST_REJECTED", mapOf(
                "origin" to startupPath,
                "startupPath" to startupPath,
                "error" to e.javaClass.name,
                "message" to (e.message ?: ""),
                "isForegroundServiceStartNotAllowed" to isFgsException,
                "isIgnoringBatteryOptimizations" to isIgnoringBatteryOptimizations(appContext),
                "isCompanionAssociated" to isCompanionAssociated(appContext),
                "recoveryStrategy" to "direct_notification_action",
            ))
            showConnectionFallbackNotification(appContext, "Audio Device", "", startupPath)
            engine.stopMonitoring()
            return false
        }
    }

    fun stopMonitoringWithService(context: Context) {
        Log.d(TAG, "stopMonitoringWithService requested")
        val appContext = context.applicationContext

        dismissFallbackNotification(appContext)
        monitorEngine?.stopMonitoring()

        val serviceIntent = Intent(appContext, AudioMonitorService::class.java).apply {
            action = AudioMonitorService.ACTION_STOP_MONITORING
        }
        appContext.stopService(serviceIntent)
    }

    private fun showConnectionFallbackNotification(
        context: Context,
        deviceName: String,
        deviceAddress: String,
        startupPath: String = "bluetooth"
    ) {
        createAlertNotificationChannel(context)

        // 1. Content intent: opens the Flutter app UI if the user taps the notification
        val activityIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("auto_start_monitoring", true)
            putExtra("device_name", deviceName)
        }

        val activityPendingIntent = PendingIntent.getActivity(
            context,
            0,
            activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 2. Direct Service Action: allows background recovery without opening the Flutter UI.
        // Under Android 12+, interacting with a notification action grants an explicit FGS start exemption.
        val serviceIntent = Intent(context, AudioMonitorService::class.java).apply {
            action = AudioMonitorService.ACTION_START_MONITORING
            putExtra(AudioMonitorService.EXTRA_DEVICE_NAME, deviceName)
            putExtra(AudioMonitorService.EXTRA_DEVICE_ADDRESS, deviceAddress)
            putExtra("origin", "notification_action")
            putExtra("startupPath", "notification_action")
        }

        val servicePendingIntent = PendingIntent.getForegroundService(
            context,
            1,
            serviceIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, ALERT_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("$deviceName Connected")
            .setContentText("Tap to open app, or tap Start Monitoring below to run in background")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setContentIntent(activityPendingIntent)
            .addAction(android.R.drawable.ic_media_play, "Start Monitoring", servicePendingIntent)
            .build()

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(ALERT_NOTIFICATION_ID, notification)

        NativeLifecycleDiagnostics.record(context, "RECOVERY_NOTIFICATION_POSTED", mapOf(
            "deviceName" to deviceName,
            "addressPresent" to deviceAddress.isNotBlank(),
            "hasDirectServiceAction" to true,
            "startupPath" to startupPath,
        ))
    }

    fun syncCompanionDevicePresence(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cdm = context.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager
                ?: return
            try {
                val associations = cdm.associations
                Log.d(TAG, "Syncing companion device presence for ${associations.size} association(s)")
                for (address in associations) {
                    try {
                        cdm.startObservingDevicePresence(address)
                        Log.i(TAG, "Started observing companion device presence: $address")
                        NativeLifecycleDiagnostics.record(context, "COMPANION_OBSERVATION_STARTED", mapOf(
                            "addressPresent" to address.isNotBlank(),
                            "address" to address
                        ))
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed startObservingDevicePresence for $address: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to query companion device associations", e)
            }
        }
    }

    private fun dismissFallbackNotification(context: Context) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(ALERT_NOTIFICATION_ID)
        } catch (_: Exception) {}
    }

    private fun createAlertNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                ALERT_CHANNEL_ID,
                "Device Connection Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerts when audio devices connect to trigger monitoring"
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    const val BREAK_REMINDER_CHANNEL_ID = "listening_tracker_break_reminders"
    const val BREAK_SOON_NOTIFICATION_ID = 3001
    const val BREAK_RECOMMENDED_NOTIFICATION_ID = 3002

    private fun createBreakReminderChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                BREAK_REMINDER_CHANNEL_ID,
                "Listening Break Reminders",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Periodic reminders to take ear breaks during continuous listening"
                setShowBadge(true)
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    fun showBreakNotification(context: Context, id: Int, title: String, body: String, snoozeMinutes: Int = 10): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val hasPermission = ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!hasPermission) {
                Log.w(TAG, "POST_NOTIFICATIONS permission not granted; cannot display break notification")
                NativeLifecycleDiagnostics.record(context, "BREAK_NOTIFICATION_SKIPPED_PERMISSION_DENIED", mapOf(
                    "id" to id,
                    "title" to title
                ))
                return false
            }
        }

        createBreakReminderChannel(context)

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // PendingIntent for Snooze Action
        val snoozeIntent = Intent(context, BreakActionReceiver::class.java).apply {
            action = BreakActionReceiver.ACTION_SNOOZE
            putExtra(BreakActionReceiver.EXTRA_NOTIFICATION_ID, id)
            putExtra(BreakActionReceiver.EXTRA_SNOOZE_MINUTES, snoozeMinutes)
        }
        val snoozePendingIntent = PendingIntent.getBroadcast(
            context,
            id * 10 + 1,
            snoozeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // PendingIntent for Dismiss Action
        val dismissIntent = Intent(context, BreakActionReceiver::class.java).apply {
            action = BreakActionReceiver.ACTION_DISMISS
            putExtra(BreakActionReceiver.EXTRA_NOTIFICATION_ID, id)
        }
        val dismissPendingIntent = PendingIntent.getBroadcast(
            context,
            id * 10 + 2,
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, BREAK_REMINDER_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setDeleteIntent(dismissPendingIntent)
            .addAction(
                android.R.drawable.ic_lock_idle_alarm,
                "Snooze (${snoozeMinutes}m)",
                snoozePendingIntent
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Dismiss",
                dismissPendingIntent
            )
            .build()

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(id, notification)

        NativeLifecycleDiagnostics.record(context, "BREAK_NOTIFICATION_POSTED", mapOf(
            "id" to id,
            "title" to title,
            "body" to body,
            "snoozeMinutes" to snoozeMinutes
        ))
        return true
    }

    fun handleBreakAction(context: Context, action: String, id: Int, snoozeMinutes: Int = 10) {
        cancelBreakNotification(context, id)
        NativeLifecycleDiagnostics.record(context, "BREAK_NOTIFICATION_ACTION_CLICKED", mapOf(
            "action" to action,
            "id" to id,
            "snoozeMinutes" to snoozeMinutes
        ))

        val payload = mapOf(
            "type" to "BREAK_ACTION",
            "action" to action,
            "id" to id,
            "snoozeMinutes" to snoozeMinutes,
            "timestamp" to System.currentTimeMillis()
        )

        mainHandler.post {
            val sink = eventSink
            if (sink != null) {
                sink.success(payload)
            } else {
                synchronized(pendingEvents) {
                    if (pendingEvents.size >= 100) pendingEvents.removeFirst()
                    pendingEvents.addLast(payload)
                }
            }
        }
    }

    fun cancelBreakNotification(context: Context, id: Int) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(id)
            NativeLifecycleDiagnostics.record(context, "BREAK_NOTIFICATION_CANCELLED", mapOf("id" to id))
        } catch (_: Exception) {}
    }

    fun cancelAllBreakNotifications(context: Context) {
        cancelBreakNotification(context, BREAK_SOON_NOTIFICATION_ID)
        cancelBreakNotification(context, BREAK_RECOMMENDED_NOTIFICATION_ID)
    }

    fun checkAllPermissions(context: Context): Map<String, Boolean> {
        val permissions = mutableMapOf<String, Boolean>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions["bluetooth_connect"] = ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.BLUETOOTH_CONNECT
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            permissions["bluetooth_connect"] = true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions["post_notifications"] = ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.POST_NOTIFICATIONS
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            permissions["post_notifications"] = true
        }

        permissions["battery_optimizations_ignored"] = isIgnoringBatteryOptimizations(context)
        permissions["companion_associated"] = isCompanionAssociated(context)

        return permissions
    }

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            return powerManager?.isIgnoringBatteryOptimizations(context.packageName) ?: false
        }
        return true
    }

    private fun requestIgnoreBatteryOptimizations(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:${context.packageName}")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to start ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS intent", e)
            }
        }
    }

    fun isCompanionAssociated(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val cdm = context.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager
            return try {
                val associations = cdm?.associations ?: emptyList()
                associations.isNotEmpty()
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    private fun associateCompanionDevice(activity: Activity, namePattern: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val cdm = activity.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager
                ?: return

            val deviceFilter = BluetoothDeviceFilter.Builder()
                .setNamePattern(Pattern.compile(namePattern, Pattern.CASE_INSENSITIVE))
                .build()

            val pairingRequest = AssociationRequest.Builder()
                .addDeviceFilter(deviceFilter)
                .setSingleDevice(true)
                .build()

            cdm.associate(pairingRequest, object : CompanionDeviceManager.Callback() {
                override fun onDeviceFound(chooserLauncher: IntentSender) {
                    try {
                        activity.startIntentSenderForResult(
                            chooserLauncher,
                            COMPANION_ASSOCIATION_REQUEST_CODE,
                            null, 0, 0, 0
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to launch companion association chooser", e)
                    }
                }

                override fun onFailure(error: CharSequence?) {
                    Log.e(TAG, "Companion device association failed: $error")
                }
            }, mainHandler)
        }
    }

    const val COMPANION_ASSOCIATION_REQUEST_CODE = 3001

    private fun shareLogFile(context: Context, content: String, fileName: String): Boolean {
        return try {
            val file = java.io.File(context.cacheDir, fileName)
            file.writeText(content, Charsets.UTF_8)
            val uri = androidx.core.content.FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "Listening Tracker Diagnostic Logs")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (attachedActivity == null) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            val chooser = Intent.createChooser(shareIntent, "Share Diagnostic Logs").apply {
                if (attachedActivity == null) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            val act = attachedActivity
            if (act != null) {
                act.startActivity(chooser)
            } else {
                context.startActivity(chooser)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to share log file", e)
            false
        }
    }
}
