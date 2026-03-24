package com.duckegg.nx4board

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.*

class ScreenRecorderThread(
    private val context: Context,
    private val mediaProjection: MediaProjection,
    private val onComplete: () -> Unit,
    private val onError: (String) -> Unit
) : Thread() {

    private var mediaRecorder: MediaRecorder? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    var isRecording = false
        private set
    private var shouldStop = false
    private val recordingDurationMs = 60000L // 60 seconds

    override fun run() {
        try {
            val displayMetrics = context.resources.displayMetrics
            val density = displayMetrics.density
            val screenWidth = 1920
            val screenHeight = 1080
            val screenDpi = (displayMetrics.densityDpi * density).toInt()

            // Create output directory
            val outputDir = File(
                context.getExternalFilesDir(null),
                "recordings"
            )
            if (!outputDir.exists()) {
                outputDir.mkdirs()
            }

            // Create output file with timestamp
            val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val outputFile = File(outputDir, "screen_recording_$timestamp.mp4")

            // Setup MediaRecorder
            mediaRecorder = MediaRecorder().apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setVideoEncodingBitRate(5000000) // 5 Mbps for 1080P
                setVideoFrameRate(30)
                setVideoSize(screenWidth, screenHeight)
                setAudioSamplingRate(44100)
                setAudioChannels(2)
                setAudioEncodingBitRate(128000)
                setOutputFile(outputFile.absolutePath)
            }

            mediaRecorder!!.prepare()

            // Get surface from MediaRecorder
            val surface = mediaRecorder!!.surface
            virtualDisplay = mediaProjection.createVirtualDisplay(
                "ScreenRecording",
                screenWidth,
                screenHeight,
                screenDpi,
                WindowManager.LayoutParams.TYPE_APPLICATION,
                surface,
                null,
                null
            )

            // Start recording
            mediaRecorder!!.start()
            isRecording = true

            // Wait for duration or until stopRecording is called
            val startTime = System.currentTimeMillis()
            while (!shouldStop && System.currentTimeMillis() - startTime < recordingDurationMs) {
                Thread.sleep(100)
            }

            // Stop recording
            stopAndSaveRecording(outputFile)
            
            onComplete()
        } catch (e: Exception) {
            onError(e.message ?: "Unknown error")
        } finally {
            isRecording = false
            mediaRecorder?.release()
            mediaRecorder = null
            
            try {
                virtualDisplay?.release()
                virtualDisplay = null
            } catch (e: Exception) {}
            
            try {
                mediaProjection.stop()
            } catch (e: Exception) {}
            
            // 錄影結束後停止前景服務
            try {
                val serviceIntent = Intent(context, ScreenRecordingService::class.java)
                context.stopService(serviceIntent)
            } catch (e: Exception) {
                // Ignore
            }
        }
    }

    private fun stopAndSaveRecording(outputFile: File) {
        try {
            mediaRecorder?.apply {
                try {
                    stop()
                } catch (e: Exception) {
                    // 錄影時間太短或發生錯誤時 stop() 可能失敗，可忽略此處異常
                }
            }

            // 使用 MediaStore.Video 儲存影片，確保能出現在相簿中
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, outputFile.name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.DATE_ADDED, System.currentTimeMillis() / 1000)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/NX4Board")
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
            }

            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }

            val uri = context.contentResolver.insert(collection, values)
            uri?.let { targetUri ->
                context.contentResolver.openOutputStream(targetUri)?.use { outputStream ->
                    outputFile.inputStream().use { inputStream ->
                        inputStream.copyTo(outputStream)
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    values.clear()
                    values.put(MediaStore.Video.Media.IS_PENDING, 0)
                    context.contentResolver.update(targetUri, values, null, null)
                }
            }
        } catch (e: Exception) {
            onError("Failed to save recording: ${e.message}")
        }
    }

    fun stopRecording() {
        shouldStop = true
    }
}