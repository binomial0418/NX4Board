package com.duckegg.nx4board

import android.content.Context
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * 頭頂天空的衛星摘要（給 Dart 的 SkyService 判斷是否在高架橋面下）。
 *
 * 衛星狀態回呼在獨立的背景執行緒上收、在那裡算好摘要，每秒最多送一筆到主執行緒，
 * 不和 Flutter／定位串流搶主執行緒。
 *
 * 每筆：
 *   hiTotal   仰角 ≥ 60° 的衛星數（含沒收到訊號的，代表「頭頂該有幾顆」）
 *   hiStrong  其中 C/N0 ≥ 25 dB-Hz 的顆數——橋面下會整批消失
 *   used      用於定位的衛星數
 *   top6      用於定位、訊號最強 6 顆的平均 C/N0
 *   hi        仰角 ≥ 45° 各衛星的 C/N0（調門檻用）
 */
class GnssSkyMonitor(context: Context) : EventChannel.StreamHandler {

    private val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val thread = HandlerThread("gnss-sky").apply { start() }
    private val bg = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null
    private var lastSentMs = 0L

    private val callback = object : GnssStatus.Callback() {
        override fun onSatelliteStatusChanged(status: GnssStatus) {
            val now = System.currentTimeMillis()
            if (now - lastSentMs < 900) return
            lastSentMs = now
            var hiTotal = 0
            var hiStrong = 0
            var used = 0
            val usedCn0 = ArrayList<Float>()
            val hi = ArrayList<Double>()
            for (i in 0 until status.satelliteCount) {
                val el = status.getElevationDegrees(i)
                val cn0 = status.getCn0DbHz(i)
                if (el >= 60f) {
                    hiTotal++
                    if (cn0 >= 25f) hiStrong++
                }
                if (el >= 45f) hi.add(Math.round(cn0 * 10.0) / 10.0)
                if (status.usedInFix(i)) {
                    used++
                    usedCn0.add(cn0)
                }
            }
            usedCn0.sortDescending()
            val top = usedCn0.take(6)
            val event = hashMapOf<String, Any?>(
                "t" to now,
                "hiTotal" to hiTotal,
                "hiStrong" to hiStrong,
                "used" to used,
                "top6" to if (top.isEmpty()) 0.0 else Math.round(top.average() * 10.0) / 10.0,
                "hi" to hi,
            )
            main.post { sink?.success(event) }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        try {
            locationManager.registerGnssStatusCallback(callback, bg)
        } catch (e: SecurityException) {
            // 還沒有定位權限：之後重新 listen 時再註冊
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        try {
            locationManager.unregisterGnssStatusCallback(callback)
        } catch (_: Exception) {
        }
    }

    fun dispose() {
        onCancel(null)
        thread.quitSafely()
    }
}
