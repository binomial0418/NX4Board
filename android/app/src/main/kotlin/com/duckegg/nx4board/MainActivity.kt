package com.duckegg.nx4board

import android.app.ActivityManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.MediaRecorder
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.location.GnssStatus
import android.location.LocationManager
import android.os.*
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "classic_bt"
    private val EVENT_CHANNEL  = "classic_bt/data"
    private val WIFI_CHANNEL   = "wifi"
    private val VOLUME_CHANNEL = "com.duckegg.nx4board/volume"
    private val VOLUME_EVENT_CHANNEL = "com.duckegg.nx4board/volumeEvents"
    private val DEVICE_INFO_CHANNEL  = "com.duckegg.nx4board/device_info"
    private val SCREEN_RECORD_CHANNEL = "com.duckegg.nx4board/screenrecord"
    private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var audioManager: AudioManager? = null
    private var volumeEventSink: EventChannel.EventSink? = null
    private var lastReportedVolume: Double = -1.0
    private var volumeCheckTimer: Timer? = null

    // --- Screen Recording ---
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var screenRecorderThread: ScreenRecorderThread? = null
    private val REQUEST_CODE_MEDIA_PROJECTION = 1001
    private var pendingScreenRecordResult: MethodChannel.Result? = null

    // ── Socket & Stream refs ──────────────────────────────────────────────────
    @Volatile private var bluetoothSocket: BluetoothSocket? = null
    @Volatile private var inputStream:  InputStream?  = null
    @Volatile private var outputStream: OutputStream? = null

    // ── 連線鎖：阻擋 Dart 端併發連線 ──────────────────────────────────────────
    private val isConnecting = AtomicBoolean(false)

    // ── 讀取迴圈控制旗標 ───────────────────────────────────────────────────────
    @Volatile private var isReading = false
    private var readThread: Thread? = null

    // ── Executors ─────────────────────────────────────────────────────────────
    // connectExecutor: 專門負責 socket.connect() 的背景執行緒（單執行緒，串行）
    private val connectExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bt-connect-thread")
    }
    // writeExecutor: 專門負責 outputStream.write()（與 readThread 完全分離）
    private val writeExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bt-write-thread")
    }

    // ── EventSink for data push ───────────────────────────────────────────────
    private var eventSink: EventChannel.EventSink? = null

    // ── GNSS Status Tracking ──────────────────────────────────────────────────
    private var satelliteCount = 0
    private var gnssStatusCallback: Any? = null // Using Any? for backward compatibility check


    // =========================================================================
    // Flutter Engine 設定
    // =========================================================================

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize AudioManager
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Initialize MediaProjectionManager
        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBondedDevices" -> handleGetBondedDevices(result)
                "connect"         -> {
                    val address = call.argument<String>("address")
                    if (address != null) connectToDevice(address, result)
                    else result.error("INVALID_ADDRESS", "Address is null", null)
                }
                "write"           -> {
                    val data = call.argument<ByteArray>("data")
                    if (data != null) writeToSocket(data, result)
                    else result.error("INVALID_DATA", "Data is null", null)
                }
                "disconnect"      -> {
                    disconnect()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── Volume MethodChannel ────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, VOLUME_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getVolume" -> {
                    val volume = getSystemVolume()
                    result.success(volume)
                }
                "setVolume" -> {
                    val volume = call.argument<Double>("volume") ?: 0.5
                    setSystemVolume(volume)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── Volume EventChannel ─────────────────────────────────────────────
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, VOLUME_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                volumeEventSink = sink
                lastReportedVolume = -1.0
                // Send current volume immediately
                val currentVolume = getSystemVolume()
                lastReportedVolume = currentVolume
                sink?.success(currentVolume)
                
                // Start periodic volume check (every 500ms)
                if (volumeCheckTimer == null) {
                    volumeCheckTimer = Timer()
                    volumeCheckTimer?.scheduleAtFixedRate(object : TimerTask() {
                        override fun run() {
                            val volume = getSystemVolume()
                            if (kotlin.math.abs(volume - lastReportedVolume) > 0.01) {
                                lastReportedVolume = volume
                                runOnUiThread {
                                    volumeEventSink?.success(volume)
                                }
                            }
                        }
                    }, 500, 500)
                }
            }

            override fun onCancel(arguments: Any?) {
                volumeEventSink = null
                volumeCheckTimer?.cancel()
                volumeCheckTimer = null
            }
        })

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        // ── WiFi MethodChannel ────────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, WIFI_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSSID"      -> handleGetSSID(result)
                "openSettings" -> { /* 已由 Flutter 接管或待補 */ }
                else           -> result.notImplemented()
            }
        }

        // ── Device Info MethodChannel ────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBatteryTemperature" -> {
                    val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val raw = intent?.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
                    result.success(if (raw >= 0) raw / 10.0 else null)
                }
                "getThermalStatus" -> {
                    // PowerManager.currentThermalStatus: Android 10+ (API 29)
                    // 0=NONE, 1=LIGHT, 2=MODERATE, 3=SEVERE, 4=CRITICAL, 5=EMERGENCY, 6=SHUTDOWN
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.currentThermalStatus)
                    } else {
                        result.success(0)
                    }
                }
                "getGpsSatelliteCount" -> {
                    result.success(satelliteCount)
                }
                else -> result.notImplemented()
            }
        }

        // Initialize GNSS Callback
        setupGnssCallback()

        // ── Screen Recording MethodChannel ──────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SCREEN_RECORD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    if (screenRecorderThread != null && screenRecorderThread!!.isRecording) {
                        result.error("ALREADY_RECORDING", "Already recording", null)
                    } else {
                        requestMediaProjection(result)
                    }
                }
                "stopRecording" -> {
                    stopRecording(result)
                }
                else -> result.notImplemented()
            }
        }
    }

    // =========================================================================
    // 系統音量控制
    // =========================================================================

    private fun getSystemVolume(): Double {
        val audioManager = audioManager ?: return 0.5
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return if (maxVolume > 0) currentVolume.toDouble() / maxVolume else 0.0
    }

    private fun setSystemVolume(volume: Double) {
        val audioManager = audioManager ?: return
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val targetVolume = (volume * maxVolume).toInt()
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)
    }

    // =========================================================================
    // getBondedDevices
    // =========================================================================

    private fun handleGetBondedDevices(result: MethodChannel.Result) {
        try {
            val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val devices = manager.adapter.bondedDevices.map {
                mapOf("name" to (it.name ?: "Unknown"), "address" to it.address)
            }
            result.success(devices)
        } catch (e: Exception) {
            result.error("BT_ERROR", e.message, null)
        }
    }

    // =========================================================================
    // 連線（背景執行緒 + 雙重策略）
    // =========================================================================

    private fun connectToDevice(address: String, result: MethodChannel.Result) {
        // ── 連線鎖 ──────────────────────────────────────────────────────────
        if (!isConnecting.compareAndSet(false, true)) {
            result.error("ALREADY_CONNECTING", "A connection attempt is already in progress", null)
            return
        }

        // ── 在 connectExecutor（背景執行緒）執行 ────────────────────────────
        connectExecutor.execute {
            var socket: BluetoothSocket? = null
            try {
                // 先關閉舊連線
                disconnect()

                val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val adapter: BluetoothAdapter = manager.adapter
                val device: BluetoothDevice  = adapter.getRemoteDevice(address)

                // ── 規範 2：connect 前強制取消掃描 ──────────────────────────
                adapter.cancelDiscovery()

                // ── 規範 4a：優先嘗試 Insecure RFCOMM ───────────────────────
                socket = try {
                    device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                } catch (e: Exception) {
                    null
                }

                var connected = false

                if (socket != null) {
                    try {
                        socket.connect()
                        connected = true
                    } catch (e: IOException) {
                        // Insecure RFCOMM 失敗，關閉後走 Reflection Fallback
                        try { socket.close() } catch (_: IOException) {}
                        socket = null
                    }
                }

                // ── 規範 4b：Reflection Fallback（Port 1）────────────────────
                if (!connected) {
                    adapter.cancelDiscovery() // 再次確保掃描已停止
                    try {
                        val method = device.javaClass.getMethod(
                            "createRfcommSocket",
                            Int::class.javaPrimitiveType!!
                        )
                        socket = method.invoke(device, 1) as BluetoothSocket
                        socket!!.connect()
                        connected = true
                    } catch (e: Exception) {
                        try { socket?.close() } catch (_: IOException) {}
                        socket = null
                        throw IOException("Both RFCOMM strategies failed: ${e.message}")
                    }
                }

                // ── 連線成功，儲存引用 ───────────────────────────────────────
                bluetoothSocket = socket
                inputStream     = socket!!.inputStream
                outputStream    = socket.outputStream

                // ── 規範 3：啟動獨立長效讀取執行緒 ──────────────────────────
                startReadingThread()

                runOnUiThread { result.success(true) }

            } catch (e: IOException) {
                try { socket?.close() } catch (_: IOException) {}
                runOnUiThread { result.error("CONNECT_FAILED", e.message, null) }
            } catch (e: Exception) {
                try { socket?.close() } catch (_: IOException) {}
                runOnUiThread { result.error("ERROR", e.message, null) }
            } finally {
                isConnecting.set(false)
            }
        }
    }

    // =========================================================================
    // 規範 3：獨立長效讀取執行緒
    // =========================================================================

    private fun startReadingThread() {
        // 先確保舊的讀取執行緒停止
        isReading = false
        readThread?.interrupt()

        isReading = true
        readThread = Thread({
            val buffer = ByteArray(1024)
            while (isReading) {
                try {
                    val stream = inputStream ?: break
                    val bytes = stream.read(buffer)
                    if (bytes > 0) {
                        val readData = buffer.copyOfRange(0, bytes)
                        runOnUiThread {
                            eventSink?.success(readData)
                        }
                    } else if (bytes < 0) {
                        // read 返回 -1 代表 EOF（socket 已被對端關閉）
                        runOnUiThread {
                            eventSink?.error("READ_FAILED", "bt socket closed, read return: -1", null)
                        }
                        break
                    }
                } catch (e: IOException) {
                    if (isReading) {
                        // 非主動斷線引發的異常才回報
                        runOnUiThread {
                            eventSink?.error("READ_FAILED", e.message, null)
                        }
                    }
                    break
                }
            }
        }, "bt-read-thread")

        readThread!!.isDaemon = true
        readThread!!.start()
    }

    // =========================================================================
    // 寫入（獨立 writeExecutor，不受 readThread 阻塞）
    // =========================================================================

    private fun writeToSocket(data: ByteArray, result: MethodChannel.Result) {
        writeExecutor.execute {
            try {
                val out = outputStream
                    ?: return@execute runOnUiThread {
                        result.error("WRITE_FAILED", "Not connected", null)
                    }.let {}
                out.write(data)
                out.flush()
                runOnUiThread { result.success(true) }
            } catch (e: IOException) {
                runOnUiThread { result.error("WRITE_FAILED", e.message, null) }
            }
        }
    }

    // =========================================================================
    // 斷線（設旗標 → 關閉 stream → 關閉 socket）
    // =========================================================================

    private fun disconnect() {
        // 先設旗標，讓 readThread 的 while 在下次迭代時自然退出
        isReading = false

        try { inputStream?.close()  } catch (_: IOException) {}
        try { outputStream?.close() } catch (_: IOException) {}
        try { bluetoothSocket?.close() } catch (_: IOException) {}

        inputStream     = null
        outputStream    = null
        bluetoothSocket = null
    }

    // =========================================================================
    // WiFi：讀取目前 SSID
    // =========================================================================

    @Suppress("DEPRECATION")
    private fun handleGetSSID(result: MethodChannel.Result) {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wifiManager.connectionInfo
            result.success(info.ssid ?: "")
        } catch (e: Exception) {
            result.error("WIFI_ERROR", e.message, null)
        }
    }

    // =========================================================================
    // 螢幕錄影相關
    // =========================================================================

    private fun requestMediaProjection(result: MethodChannel.Result) {
        val intent = mediaProjectionManager?.createScreenCaptureIntent()
        if (intent != null) {
            pendingScreenRecordResult = result
            startActivityForResult(intent, REQUEST_CODE_MEDIA_PROJECTION)
        } else {
            result.error("PERMISSION_FAILED", "Cannot request media projection", null)
        }
    }

    private fun startScreenRecording(mediaProjectionManager: MediaProjectionManager, resultCode: Int, data: Intent, flutterResult: MethodChannel.Result) {
        try {
            // Android 14+ (API 34) 要求：獲取 MediaProjection 令牌前，必須已有運行中的特定類型前景服務
            startForegroundService()

            val mediaProjection = mediaProjectionManager.getMediaProjection(resultCode, data)
            if (mediaProjection != null) {
                screenRecorderThread = ScreenRecorderThread(
                    context = this,
                    mediaProjection = mediaProjection,
                    onComplete = {
                        runOnUiThread {
                            flutterResult.success(true)
                        }
                    },
                    onError = { error ->
                        runOnUiThread {
                            flutterResult.error("RECORDING_FAILED", error, null)
                        }
                    }
                )
                screenRecorderThread!!.start()
            } else {
                flutterResult.error("PROJECTION_FAILED", "Cannot get media projection", null)
            }
        } catch (e: Exception) {
            flutterResult.error("EXCEPTION", e.message, null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (screenRecorderThread != null) {
            screenRecorderThread!!.stopRecording()
            result.success(true)
        } else {
            result.error("NOT_RECORDING", "Not currently recording", null)
        }
    }

    private fun startForegroundService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val serviceIntent = Intent(this, ScreenRecordingService::class.java)
            startForegroundService(serviceIntent)
        }
    }

    // =========================================================================
    // Activity Result
    // =========================================================================

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_CODE_MEDIA_PROJECTION && resultCode == RESULT_OK && data != null) {
            val flutterResult = pendingScreenRecordResult
            if (flutterResult != null && mediaProjectionManager != null) {
                pendingScreenRecordResult = null
                startScreenRecording(mediaProjectionManager!!, resultCode, data, flutterResult)
            }
        } else {
            val flutterResult = pendingScreenRecordResult
            if (flutterResult != null) {
                pendingScreenRecordResult = null
                flutterResult.error("PERMISSION_DENIED", "User denied screen capture permission", null)
            }
        }
    }

    // =========================================================================
    // 生命週期
    // =========================================================================

    private fun setupGnssCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val callback = object : GnssStatus.Callback() {
                override fun onSatelliteStatusChanged(status: GnssStatus) {
                    var count = 0
                    for (i in 0 until status.satelliteCount) {
                        if (status.usedInFix(i)) {
                            count++
                        }
                    }
                    satelliteCount = count
                }
            }
            gnssStatusCallback = callback
            try {
                locationManager.registerGnssStatusCallback(callback, Handler(Looper.getMainLooper()))
            } catch (e: SecurityException) {
                // Ignore if permission not yet granted; geolocator handles permission requests
            }
        }
    }

    override fun onDestroy() {
        disconnect()
        volumeCheckTimer?.cancel()
        volumeCheckTimer = null
        connectExecutor.shutdownNow()
        writeExecutor.shutdownNow()
        // Unregister GNSS Callback
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && gnssStatusCallback != null) {
            val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            locationManager.unregisterGnssStatusCallback(gnssStatusCallback as GnssStatus.Callback)
        }

        super.onDestroy()
    }
}