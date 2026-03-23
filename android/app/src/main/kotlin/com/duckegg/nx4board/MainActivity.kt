package com.duckegg.nx4board

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.media.AudioManager
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.*
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "classic_bt"
    private val EVENT_CHANNEL  = "classic_bt/data"
    private val WIFI_CHANNEL   = "wifi"
    private val VOLUME_CHANNEL = "com.duckegg.nx4board/volume"
    private val VOLUME_EVENT_CHANNEL = "com.duckegg.nx4board/volumeEvents"
    private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var audioManager: AudioManager? = null
    private var volumeEventSink: EventChannel.EventSink? = null
    private var lastReportedVolume: Double = -1.0
    private var volumeCheckTimer: Timer? = null

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


    // =========================================================================
    // Flutter Engine 設定
    // =========================================================================

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize AudioManager
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

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
    // 生命週期
    // =========================================================================

    override fun onDestroy() {
        disconnect()
        volumeCheckTimer?.cancel()
        volumeCheckTimer = null
        connectExecutor.shutdownNow()
        writeExecutor.shutdownNow()
        super.onDestroy()
    }
}
