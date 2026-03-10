// lib/core/services/liveness_service.dart
//
// Production liveness service — fixed & hardened.
//
// ── Changes vs original ────────────────────────────────────────────────────────
//  • reset() no longer re-uses a disposed instance — after dispose() all public
//    methods are silent no-ops, preventing "setState after dispose" crashes when
//    the camera page is torn down while liveness is mid-flow.
//  • _blinkClosedFrames raised to 2 — reduces false positives from single-frame
//    glitches where ML Kit momentarily reports low eye probability.
//  • Eye-open threshold lowered slightly (0.55) for users with naturally
//    smaller eye apertures / glasses who struggled to pass.
//  • Added _maxFramesWithoutFace counter: if the face disappears mid-flow for
//    > 30 consecutive frames the step resets to waitingForBlink so the user
//    gets clear feedback rather than the liveness check silently hanging.
//  • All notifyListeners() calls go through _safeNotify() (already existed)
//    — no change required.

import 'package:flutter/foundation.dart';

enum LivenessStep {
  waitingForBlink,
  blinkDetected,
  waitingForTurn,
  turnDetected,
  passed,
  failed,
}

class LivenessState {
  final LivenessStep step;
  final String instruction;
  final double progress;

  const LivenessState({
    required this.step,
    required this.instruction,
    required this.progress,
  });

  bool get isPassed => step == LivenessStep.passed;
  bool get isFailed => step == LivenessStep.failed;
}

class LivenessService extends ChangeNotifier {
  // ── Thresholds ────────────────────────────────────────────────────────────────
  static const double _eyeClosedThreshold  = 0.25;
  static const double _eyeOpenThreshold    = 0.55; // slightly relaxed
  static const double _turnAngleThreshold  = 15.0;
  static const double _centreAngleThreshold = 8.0;
  static const int    _blinkClosedFrames   = 2;    // require 2 closed frames
  static const int    _maxNoFaceFrames     = 30;   // reset after 30 frames without face

  // ── State ─────────────────────────────────────────────────────────────────────
  LivenessStep _step        = LivenessStep.waitingForBlink;
  bool _eyesWereOpen        = false;
  int  _closedFrames        = 0;
  bool _eyesClosed          = false;
  bool _hasTurned           = false;
  int  _noFaceFrames        = 0;
  bool _disposed            = false;

  LivenessState get state => _buildState();

  /// Feed this with every camera frame where a face MAY be present.
  ///
  /// Pass null for all params when no face is detected — this increments the
  /// no-face counter and resets blink tracking if the face disappears too long.
  void processFrame({
    required double? leftEye,
    required double? rightEye,
    required double? eulerY,
  }) {
    if (_disposed) return;
    if (_step == LivenessStep.passed || _step == LivenessStep.failed) return;

    // No face in this frame
    if (leftEye == null && rightEye == null && eulerY == null) {
      _noFaceFrames++;
      if (_noFaceFrames > _maxNoFaceFrames &&
          _step != LivenessStep.waitingForBlink) {
        debugPrint('[Liveness] face lost too long — resetting to waitingForBlink');
        _resetBlink();
        _safeNotify();
      }
      return;
    }

    _noFaceFrames = 0; // face visible → reset counter

    switch (_step) {
      case LivenessStep.waitingForBlink:
        _trackBlink(leftEye, rightEye);
        break;
      case LivenessStep.blinkDetected:
      // Transition immediately on the next processFrame after blink.
        _step = LivenessStep.waitingForTurn;
        _safeNotify();
        break;
      case LivenessStep.waitingForTurn:
        _trackTurn(eulerY);
        break;
      case LivenessStep.turnDetected:
        _step = LivenessStep.passed;
        _safeNotify();
        break;
      default:
        break;
    }
  }

  /// Full reset — safe to call multiple times, including after dispose().
  void reset() {
    if (_disposed) return;
    _resetBlink();
    _hasTurned    = false;
    _step         = LivenessStep.waitingForBlink;
    _noFaceFrames = 0;
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ── Internal ──────────────────────────────────────────────────────────────────

  void _resetBlink() {
    _eyesWereOpen = false;
    _closedFrames = 0;
    _eyesClosed   = false;
  }

  void _trackBlink(double? left, double? right) {
    // ── BUG FIX: ML Kit returns NULL (not 0.0) when eyes are fully closed ──
    //
    // During a real blink, ML Kit often CANNOT compute eye-open probability
    // for fully-closed eyes and returns null instead of a low number.
    // The old code bailed out with `if (left == null || right == null) return`
    // which meant every single closed-eye frame was silently skipped.
    // _closedFrames never incremented, so blink was NEVER detected no matter
    // how many times the user blinked — the page just hung forever.
    //
    // FIX: Treat null as 0.0 (eyes fully closed). This is semantically
    // correct — ML Kit returns null precisely when it cannot measure the
    // eye aperture, which is exactly when the eye is shut.
    // Only bail if BOTH values are null (no face data at all).
    if (left == null && right == null) return;

    final double l   = left  ?? 0.0; // null → fully closed
    final double r   = right ?? 0.0; // null → fully closed
    final double avg = (l + r) / 2.0;

    debugPrint('[Liveness] eye avg=${avg.toStringAsFixed(2)} '
        'open=$_eyesWereOpen closed=$_eyesClosed frames=$_closedFrames '
        'raw(L=${left?.toStringAsFixed(2) ?? "null"} '
        'R=${right?.toStringAsFixed(2) ?? "null"})');

    // 1 — establish baseline: eyes must be clearly open first.
    if (!_eyesWereOpen && avg > _eyeOpenThreshold) {
      _eyesWereOpen = true;
      debugPrint('[Liveness] baseline open established');
    }

    // 2 — detect eyes closing (null values also count as closed).
    if (_eyesWereOpen && !_eyesClosed) {
      if (avg < _eyeClosedThreshold) {
        _closedFrames++;
        debugPrint('[Liveness] closed frame #$_closedFrames');
        if (_closedFrames >= _blinkClosedFrames) {
          _eyesClosed = true;
          debugPrint('[Liveness] eyes CLOSED confirmed (${_closedFrames}f)');
        }
      } else {
        // Eyes open again before streak completed — reset.
        if (_closedFrames > 0) {
          debugPrint('[Liveness] closed streak reset (was $_closedFrames)');
        }
        _closedFrames = 0;
      }
    }

    // 3 — detect eyes re-opening after confirmed close → blink complete.
    if (_eyesWereOpen && _eyesClosed && avg > _eyeOpenThreshold) {
      debugPrint('[Liveness] BLINK confirmed!');
      _step = LivenessStep.blinkDetected;
      _safeNotify();
    }
  }

  void _trackTurn(double? eulerY) {
    if (eulerY == null) return;
    if (!_hasTurned && eulerY.abs() > _turnAngleThreshold) {
      _hasTurned = true;
      debugPrint('[Liveness] turn detected ${eulerY.toStringAsFixed(1)}°');
    }
    if (_hasTurned && eulerY.abs() < _centreAngleThreshold) {
      debugPrint('[Liveness] turn confirmed + centred');
      _step = LivenessStep.turnDetected;
      _safeNotify();
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  LivenessState _buildState() {
    switch (_step) {
      case LivenessStep.waitingForBlink:
        return const LivenessState(
          step: LivenessStep.waitingForBlink,
          instruction: 'Blink your eyes slowly',
          progress: 0.0,
        );
      case LivenessStep.blinkDetected:
        return const LivenessState(
          step: LivenessStep.blinkDetected,
          instruction: 'Blink detected ✓ — now turn your head slightly',
          progress: 0.5,
        );
      case LivenessStep.waitingForTurn:
        return const LivenessState(
          step: LivenessStep.waitingForTurn,
          instruction: 'Turn your head slightly left or right',
          progress: 0.5,
        );
      case LivenessStep.turnDetected:
        return const LivenessState(
          step: LivenessStep.turnDetected,
          instruction: 'Head turn detected ✓',
          progress: 0.9,
        );
      case LivenessStep.passed:
        return const LivenessState(
          step: LivenessStep.passed,
          instruction: 'Liveness verified ✓',
          progress: 1.0,
        );
      case LivenessStep.failed:
        return const LivenessState(
          step: LivenessStep.failed,
          instruction: 'Liveness check failed. Try again.',
          progress: 0.0,
        );
    }
  }
}