import 'package:flutter_test/flutter_test.dart';

/// Dart mirror of native PlaybackStateResolver.kt for unit validation
enum PlaybackTransition {
  none,
  started,
  stopped,
}

class PlaybackStateResolver {
  bool _isPlaying;
  final int confirmationWindowMs;
  bool _isStopPending = false;
  int? _stopPendingSinceMs;

  PlaybackStateResolver([
    this._isPlaying = false,
    this.confirmationWindowMs = 2000,
  ]);

  bool get isCurrentlyPlaying => _isPlaying;
  bool get isStopPending => _isStopPending;
  int? get stopPendingSinceMs => _stopPendingSinceMs;

  PlaybackTransition resolve({
    required bool hasMediaConfig,
    required bool isMusicActive,
    bool isA2dpStreaming = false,
    int? currentTimeMs,
  }) {
    final now = currentTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    final isAudioActive = hasMediaConfig || isMusicActive || isA2dpStreaming;

    if (!_isPlaying && isAudioActive) {
      _isPlaying = true;
      _isStopPending = false;
      _stopPendingSinceMs = null;
      return PlaybackTransition.started;
    }

    if (_isPlaying && isAudioActive) {
      // Audio recovered or remains active -> cancel any pending stop window
      _isStopPending = false;
      _stopPendingSinceMs = null;
      return PlaybackTransition.none;
    }

    if (_isPlaying && !isAudioActive) {
      final pendingSince = _stopPendingSinceMs;
      if (!_isStopPending || pendingSince == null) {
        // First detection of all false signals: start confirmation window
        _isStopPending = true;
        _stopPendingSinceMs = now;
        return PlaybackTransition.none;
      } else {
        final elapsed = now - pendingSince;
        if (elapsed >= confirmationWindowMs) {
          // Full window elapsed with continuous false signals -> genuine stop
          _isPlaying = false;
          _isStopPending = false;
          _stopPendingSinceMs = null;
          return PlaybackTransition.stopped;
        } else {
          // Still within confirmation window -> remain active, emit nothing
          return PlaybackTransition.none;
        }
      }
    }

    return PlaybackTransition.none;
  }

  PlaybackTransition confirmPendingStop() {
    if (_isPlaying && _isStopPending) {
      _isPlaying = false;
      _isStopPending = false;
      _stopPendingSinceMs = null;
      return PlaybackTransition.stopped;
    }
    return PlaybackTransition.none;
  }

  void cancelPendingStop() {
    _isStopPending = false;
    _stopPendingSinceMs = null;
  }

  String getResolutionReason({
    required bool hasMediaConfig,
    required bool isMusicActive,
    required bool isA2dpStreaming,
  }) {
    if (hasMediaConfig) return 'active_media_configuration';
    if (isA2dpStreaming) return 'bluetooth_a2dp_streaming';
    if (isMusicActive) return 'audio_manager_music_active';
    return 'no_active_media_or_sound';
  }

  void reset([bool initialPlaying = false]) {
    _isPlaying = initialPlaying;
    _isStopPending = false;
    _stopPendingSinceMs = null;
  }
}

void main() {
  group('Native PlaybackStateResolver 2-Second Confirmation Window Specification Tests', () {
    late PlaybackStateResolver resolver;

    setUp(() {
      resolver = PlaybackStateResolver(false, 2000);
    });

    test('Requirement 1: AUDIO_STARTED remains immediate (0ms latency)', () {
      resolver.reset(false);
      expect(resolver.isCurrentlyPlaying, isFalse);

      final transition = resolver.resolve(
        hasMediaConfig: true,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );

      expect(transition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);
      expect(resolver.isStopPending, isFalse);
    });

    test('Requirement 2: Transient signal loss (<2s) schedules confirmation window and does NOT emit STOPPED', () {
      resolver.reset(true);
      expect(resolver.isCurrentlyPlaying, isTrue);

      // All signals drop to false at t=1000ms
      final transitionA = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );

      expect(transitionA, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue); // Still considered playing
      expect(resolver.isStopPending, isTrue);
      expect(resolver.stopPendingSinceMs, equals(1000));

      // Another check within window at t=1800ms (800ms elapsed < 2000ms)
      final transitionB = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1800,
      );

      expect(transitionB, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
      expect(resolver.isStopPending, isTrue);
    });

    test('Requirement 3: Playback recovery before deadline cancels pending stop and keeps session active', () {
      resolver.reset(true);

      // Drop at t=1000ms
      final drop = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );
      expect(drop, equals(PlaybackTransition.none));
      expect(resolver.isStopPending, isTrue);

      // Next track starts at t=1800ms (< 2000ms window)
      final recovery = resolver.resolve(
        hasMediaConfig: true,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1800,
      );

      expect(recovery, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
      expect(resolver.isStopPending, isFalse);
      expect(resolver.stopPendingSinceMs, isNull);
    });

    test('Requirement 4: Genuine pause: all signals remain false for full window (>=2000ms) => emits STOPPED exactly once', () {
      resolver.reset(true);

      // Signals drop at t=1000ms
      final drop = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );
      expect(drop, equals(PlaybackTransition.none));
      expect(resolver.isStopPending, isTrue);

      // Window expired at t=3000ms (2000ms elapsed)
      final stop = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 3000,
      );
      expect(stop, equals(PlaybackTransition.stopped));
      expect(resolver.isCurrentlyPlaying, isFalse);
      expect(resolver.isStopPending, isFalse);

      // Subsequent identical calls while inactive emit none
      final repeat = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 3500,
      );
      expect(repeat, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isFalse);
    });

    test('Requirement 4: confirmPendingStop emits STOPPED exactly once and prevents duplicates', () {
      resolver.reset(true);

      resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );
      expect(resolver.isStopPending, isTrue);

      final confirmed = resolver.confirmPendingStop();
      expect(confirmed, equals(PlaybackTransition.stopped));
      expect(resolver.isCurrentlyPlaying, isFalse);
      expect(resolver.isStopPending, isFalse);

      // Second invocation emits none
      final duplicate = resolver.confirmPendingStop();
      expect(duplicate, equals(PlaybackTransition.none));
    });

    test('Requirement 5: Bluetooth disconnection during pending window cancels verification immediately', () {
      resolver.reset(true);

      resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );
      expect(resolver.isStopPending, isTrue);

      // Disconnect occurs at t=1400ms
      resolver.cancelPendingStop();
      expect(resolver.isStopPending, isFalse);
      resolver.reset(false);
      expect(resolver.isCurrentlyPlaying, isFalse);

      // Stale timer firing at t=3000ms produces no event
      expect(resolver.confirmPendingStop(), equals(PlaybackTransition.none));
    });

    test('Requirement 6: Duplicate callbacks during pending window preserve original deadline', () {
      resolver.reset(true);

      resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 1000,
      );
      expect(resolver.stopPendingSinceMs, equals(1000));

      for (final time in [1200, 1400, 1600, 1800]) {
        final trans = resolver.resolve(
          hasMediaConfig: false,
          isMusicActive: false,
          isA2dpStreaming: false,
          currentTimeMs: time,
        );
        expect(trans, equals(PlaybackTransition.none));
        expect(resolver.stopPendingSinceMs, equals(1000));
        expect(resolver.isCurrentlyPlaying, isTrue);
      }

      // At t=3000ms (2000ms from t=1000ms), stop is emitted
      final finalTrans = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: false,
        currentTimeMs: 3000,
      );
      expect(finalTrans, equals(PlaybackTransition.stopped));
      expect(resolver.isCurrentlyPlaying, isFalse);
    });

    test('Requirement 7: Connected-but-idle never counts as active playback', () {
      resolver.reset(false);

      for (final time in [1000, 2000, 3000]) {
        final trans = resolver.resolve(
          hasMediaConfig: false,
          isMusicActive: false,
          isA2dpStreaming: false,
          currentTimeMs: time,
        );
        expect(trans, equals(PlaybackTransition.none));
        expect(resolver.isCurrentlyPlaying, isFalse);
        expect(resolver.isStopPending, isFalse);
      }
    });

    test('Continuous playback with A2DP or music active preserves playing state without stop', () {
      resolver.reset(true);

      // Config lost, but Bluetooth A2DP is streaming
      final transA = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: false,
        isA2dpStreaming: true,
      );
      expect(transA, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Config lost, but isMusicActive is true
      final transB = resolver.resolve(
        hasMediaConfig: false,
        isMusicActive: true,
        isA2dpStreaming: false,
      );
      expect(transB, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Resolution reasons are correctly formatted', () {
      expect(resolver.getResolutionReason(hasMediaConfig: true, isMusicActive: true, isA2dpStreaming: true),
          equals('active_media_configuration'));
      expect(resolver.getResolutionReason(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: true),
          equals('bluetooth_a2dp_streaming'));
      expect(resolver.getResolutionReason(hasMediaConfig: false, isMusicActive: true, isA2dpStreaming: false),
          equals('audio_manager_music_active'));
      expect(resolver.getResolutionReason(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: false),
          equals('no_active_media_or_sound'));
    });
  });
}
