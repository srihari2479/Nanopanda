// lib/core/services/camera_service.dart
//
// Wraps the `camera` plugin: finds front camera, initialises controller,
// exposes isReady guard and safe dispose.

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class CameraService {
  CameraController? _controller;
  bool _disposed = false;

  CameraController? get controller => _controller;

  bool get isReady =>
      _controller != null &&
          _controller!.value.isInitialized &&
          !_disposed;

  /// Finds the front camera and initialises the controller.
  /// Resolution is set to medium — fast enough for ML Kit frame processing.
  Future<void> initialize() async {
    if (_disposed) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) throw Exception('No cameras available');

    final front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    // Dispose previous controller cleanly before creating new one
    await _safeDisposeController();

    _controller = CameraController(
      front,
      ResolutionPreset.medium,   // 480p — optimal for ML Kit speed vs quality
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    debugPrint('[CameraService] initialized (${front.name}, '
        'sensor=${front.sensorOrientation}°)');
  }

  Future<void> _safeDisposeController() async {
    final old = _controller;
    _controller = null;
    if (old == null) return;
    try {
      if (old.value.isStreamingImages) {
        await old.stopImageStream();
      }
      await old.dispose();
    } catch (e) {
      debugPrint('[CameraService] dispose old controller error: $e');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _safeDisposeController();
    debugPrint('[CameraService] disposed');
  }
}