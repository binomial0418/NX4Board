import 'package:flutter/services.dart';

enum RecordingState {
  idle,
  recording,
  completed,
  error,
}

class ScreenRecorderService {
  static const platform = MethodChannel('com.duckegg.nx4board/screenrecord');

  static final ScreenRecorderService _instance = ScreenRecorderService._internal();

  factory ScreenRecorderService() {
    return _instance;
  }

  ScreenRecorderService._internal();

  RecordingState _recordingState = RecordingState.idle;
  int _remainingSeconds = 0;

  RecordingState get recordingState => _recordingState;
  int get remainingSeconds => _remainingSeconds;

  /// 開始錄製螢幕（60 秒）
  Future<bool> startRecording() async {
    try {
      _recordingState = RecordingState.recording;
      _remainingSeconds = 180;

      // 啟動倒數計時
      _startCountdown();

      final result = await platform.invokeMethod('startRecording');
      return result == true;
    } on PlatformException catch (e) {
      _recordingState = RecordingState.error;
      print('Failed to start recording: ${e.message}');
      return false;
    }
  }

  /// 停止錄製
  Future<bool> stopRecording() async {
    try {
      final result = await platform.invokeMethod('stopRecording');
      if (result == true) {
        _recordingState = RecordingState.completed;
        _remainingSeconds = 0;
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      print('Failed to stop recording: ${e.message}');
      return false;
    }
  }

  /// 開始倒數計時
  void _startCountdown() {
    _remainingSeconds = 180;
    _countdownTimer();
  }

  /// 倒數計時執行函式（遞迴）
  void _countdownTimer() {
    if (_recordingState != RecordingState.recording) {
      return;
    }

    _remainingSeconds--;

    if (_remainingSeconds <= 0) {
      // 自動停止
      stopRecording();
    } else {
      // 繼續倒數
      Future.delayed(const Duration(seconds: 1), _countdownTimer);
    }
  }

  /// 重置狀態
  void reset() {
    _recordingState = RecordingState.idle;
    _remainingSeconds = 0;
  }
}