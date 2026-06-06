import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowControl {
  static const MethodChannel _channel = MethodChannel('window_control');

  /// Restore the window from minimized state
  static Future<void> restoreWindow() async {
    try {
      await _channel.invokeMethod('restoreWindow');
    } catch (e) {
      debugPrint('Failed to restore window: $e');
    }
  }

  /// Minimize the window
  static Future<void> minimizeWindow() async {
    try {
      await _channel.invokeMethod('minimizeWindow');
    } catch (e) {
      debugPrint('Failed to minimize window: $e');
    }
  }

  /// Close the window and exit the application
  static Future<void> closeWindow() async {
    try {
      await _channel.invokeMethod('closeWindow');
    } catch (e) {
      debugPrint('Failed to close window: $e');
    }
  }
}