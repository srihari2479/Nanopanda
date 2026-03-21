// lib/core/services/liveness_service.dart
//
// Anti-spoofing liveness: blink → head-turn → passed.
//
// KEY FIXES vs previous version:
//  • Sliding window for blink (3 out of last 5 frames closed) instead of
//    "2 consecutive" — a natural blink = ~4 frames but any single miss used
//    to reset the counter to 0, making blinks almost impossible to detect.
//  • _blinkThreshold raised 0.25 → 0.45. ML Kit returns 0.3–0.5 for closed
//    eyes on mid-range phones; 0.25 never triggered.
//  • _turnThreshold lowered 20° → 15°. Gentler turn still proves liveness.
//  • Removed microtask-based auto-advance — direct advance, no race condition.
//  • blinkProgress getter lets UI show a live progress ring during blink phase.
//  • Turn counter decrements (not hard-resets) on brief return to center.

import 'package:flutter/foundation.dart';

enum LivenessStep { waitingForBlink, waitingForTurn, passed }

class LivenessState {
  final LivenessStep step;
  final double blinkProgress; // 0.0–1.0

  const LivenessState(this.step, {this.blinkProgress = 0.0});

  bool get isPassed => step == LivenessStep.passed;

  String get instruction {
    switch (step) {
      case LivenessStep.waitingForBlink:
        return 'Blink your eyes slowly';
      case LivenessStep.waitingForTurn:
        return 'Turn your head left or right';
      case LivenessStep.passed:
        return 'Liveness verified!';
    }
  }

  String get subInstruction {
    switch (step) {
      case LivenessStep.waitingForBlink:
        return 'Close both eyes fully for a moment';
      case LivenessStep.waitingForTurn:
        return 'Blink detected ✓  Turn head gently';
      case LivenessStep.passed:
        return 'Capturing your face now…';
    }
  }
}

class LivenessService extends ChangeNotifier {
  // ML Kit returns 0.3–0.5 for genuinely closed eyes on most phones
  static const double _blinkThreshold = 0.45;
  // 15° is enough to prove liveness without requiring an exaggerated turn
  static const double _turnThreshold  = 15.0;

  // Sliding window: 3 out of last 5 frames must be "eyes closed"
  static const int _windowSize  = 5;
  static const int _minHits     = 3;
  // Turn: 2 consecutive frames above threshold confirms a turn
  static const int _turnConfirm = 2;

  LivenessState _state = const LivenessState(LivenessStep.waitingForBlink);
  LivenessState get state => _state;

  final List<bool> _window = []; // sliding blink window
  int _turnCount = 0;

  void processFrame({
    required double? leftEye,
    required double? rightEye,
    required double? eulerY,
  }) {
    if (_state.isPassed) return;
    switch (_state.step) {
      case LivenessStep.waitingForBlink: _checkBlink(leftEye, rightEye); break;
      case LivenessStep.waitingForTurn:  _checkTurn(eulerY);             break;
      case LivenessStep.passed:          break;
    }
  }

  void reset() {
    _state      = const LivenessState(LivenessStep.waitingForBlink);
    _window.clear();
    _turnCount  = 0;
    notifyListeners();
    debugPrint('[LivenessService] reset');
  }

  void _checkBlink(double? leftEye, double? rightEye) {
    // Unknown = treat as open so null doesn't accidentally pass liveness
    final closed = leftEye != null &&
        rightEye != null &&
        leftEye  < _blinkThreshold &&
        rightEye < _blinkThreshold;

    _window.add(closed);
    if (_window.length > _windowSize) _window.removeAt(0);

    final hits     = _window.where((v) => v).length;
    final progress = (hits / _minHits).clamp(0.0, 1.0);

    debugPrint('[LivenessService] blink window=$_window hits=$hits '
        'L=${leftEye?.toStringAsFixed(2) ?? "null"} '
        'R=${rightEye?.toStringAsFixed(2) ?? "null"}');

    // Always notify so UI progress bar updates
    _state = LivenessState(LivenessStep.waitingForBlink, blinkProgress: progress);
    notifyListeners();

    if (hits >= _minHits) {
      _window.clear();
      _turnCount = 0;
      debugPrint('[LivenessService] ✓ blink confirmed → waitingForTurn');
      _advance(LivenessStep.waitingForTurn);
    }
  }

  void _checkTurn(double? eulerY) {
    if (eulerY == null) return;
    if (eulerY.abs() > _turnThreshold) {
      _turnCount++;
      debugPrint('[LivenessService] turn frame $_turnCount/$_turnConfirm '
          'eulerY=${eulerY.toStringAsFixed(1)}°');
      if (_turnCount >= _turnConfirm) {
        debugPrint('[LivenessService] ✓ turn confirmed → passed');
        _advance(LivenessStep.passed);
      }
    } else {
      // Soft decrement — brief return to center doesn't cancel a turning gesture
      if (_turnCount > 0) _turnCount--;
    }
  }

  void _advance(LivenessStep next) {
    _state = LivenessState(next, blinkProgress: 1.0);
    notifyListeners();
  }
}