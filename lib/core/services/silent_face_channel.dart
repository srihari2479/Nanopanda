// lib/core/services/silent_face_channel.dart
//
// Flutter wrapper around the native SilentFaceService.
// Call [SilentFaceChannel.capture] to trigger a background camera capture
// and get back a JPEG as Uint8List.

import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SilentFaceChannel {
  SilentFaceChannel._();

  static const _channel = MethodChannel('nanopanda/silent_face');

  static bool _busy = false;

  /// Silently captures one front-camera frame.
  /// Returns JPEG bytes on success, null on failure or if already busy.
  static Future<Uint8List?> capture() async {
    if (_busy) {
      debugPrint('[SilentFaceChannel] already capturing');
      return null;
    }
    _busy = true;
    try {
      final result = await _channel.invokeMethod<Uint8List>('capture');
      return result;
    } on PlatformException catch (e) {
      debugPrint('[SilentFaceChannel] capture error: ${e.code} — ${e.message}');
      return null;
    } finally {
      _busy = false;
    }
  }
}