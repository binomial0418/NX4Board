package com.example.speed_limit_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.*
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val METHOD_CHANNEL = "classic_bt"
    private val EVENT_CHANNEL = "classic_bt/data"
    
    private var bluetoothSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private val executor = Executors.newSingleThreadExecutor()
    
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBondedDevices" -> {
                    val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                    val adapter = bluetoothManager.adapter
                    val bondedDevices = adapter.bondedDevices
                    val devicesList = bondedDevices.map { 
                        mapOf("name" to it.name, "address" to it.address)
                    }
                    result.success(devicesList)
                }
                "connect" -> {
                    val address = call.argument<String>("address")
                    if (address != null) {
                        connectToDevice(address, result)
                    } else {
                        result.error("INVALID_ADDRESS", "Address is null", null)
                    }
                }
                "write" -> {
                    val data = call.argument<String>("data")
                    if (data != null) {
                        writeToSocket(data, result)
                    } else {
                        result.error("INVALID_DATA", "Data is null", null)
                    }
                }
                "disconnect" -> {
                    disconnect()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    private fun connectToDevice(address: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                disconnect() // Close existing first
                
                val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val adapter = bluetoothManager.adapter
                val device = adapter.getRemoteDevice(address)
                
                // --- Torque Pro Style: Blind Insecure Connection ---
                // Method 1: Reflection call to createInsecureRfcommSocket (Port 1)
                // This bypasses SDP and often bypasses pairing prompts.
                var socket: BluetoothSocket? = null
                try {
                    val method = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                    socket = method.invoke(device, 1) as BluetoothSocket
                } catch (e: Exception) {
                    // Fallback: Standard Insecure UUID
                    val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
                    socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                }
                
                bluetoothSocket = socket
                bluetoothSocket?.connect()
                
                inputStream = bluetoothSocket?.inputStream
                outputStream = bluetoothSocket?.outputStream
                
                startReading()
                
                runOnUiThread { result.success(true) }
            } catch (e: IOException) {
                runOnUiThread { result.error("CONNECT_FAILED", e.message, null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("ERROR", e.message, null) }
            }
        }
    }

    private fun startReading() {
        executor.execute {
            val buffer = ByteArray(1024)
            while (bluetoothSocket?.isConnected == true) {
                try {
                    val bytes = inputStream?.read(buffer) ?: -1
                    if (bytes > 0) {
                        val readData = buffer.copyOfRange(0, bytes)
                        runOnUiThread {
                            eventSink?.success(readData)
                        }
                    }
                } catch (e: IOException) {
                    runOnUiThread {
                        eventSink?.error("READ_FAILED", e.message, null)
                    }
                    break
                }
            }
        }
    }

    private fun writeToSocket(data: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                outputStream?.write(data.toByteArray())
                runOnUiThread { result.success(true) }
            } catch (e: IOException) {
                runOnUiThread { result.error("WRITE_FAILED", e.message, null) }
            }
        }
    }

    private fun disconnect() {
        try {
            inputStream?.close()
            outputStream?.close()
            bluetoothSocket?.close()
        } catch (e: IOException) {
            // ignore
        } finally {
            inputStream = null
            outputStream = null
            bluetoothSocket = null
        }
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }
}
