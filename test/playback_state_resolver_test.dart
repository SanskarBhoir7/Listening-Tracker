import 'package:flutter_test/flutter_test.dart';

/// Dart mirror of native PlaybackStateResolver.kt for unit validation
enum PlaybackTransition {
  none,
  started,
  stopped,
}

class PlaybackStateResolver {
  bool _isPlaying;

  PlaybackStateResolver([this._isPlaying = false]);

  bool get isCurrentlyPlaying => _isPlaying;

  PlaybackTransition resolve({
    required bool hasMediaConfig,
    required bool isMusicActive,
    bool isA2dpStreaming = false,
  }) {
    final isAudioActive = hasMediaConfig || isMusicActive || isA2dpStreaming;

    if (!_isPlaying && isAudioActive) {
      _isPlaying = true;
      return PlaybackTransition.started;
    } else if (_isPlaying && !hasMediaConfig && !isMusicActive && !isA2dpStreaming) {
      _isPlaying = false;
      return PlaybackTransition.stopped;
    } else {
      return PlaybackTransition.none;
    }
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
  }
}

void main() {
  group('Native PlaybackStateResolver Specification Tests (Tests 1-7)', () {
    late PlaybackStateResolver resolver;

    setUp(() {
      resolver = PlaybackStateResolver();
    });

    test('Test 1: Continuous playback with temporary configuration loss => No AUDIO_STOPPED', () {
      // Setup: initially playing
      resolver.reset(true);
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Media configuration temporarily disappears, but Bluetooth A2DP is still streaming or music is active
      final transitionA = resolver.resolve(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: true);
      expect(transitionA, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);

      final transitionB = resolver.resolve(hasMediaConfig: false, isMusicActive: true, isA2dpStreaming: false);
      expect(transitionB, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 2: playerState transitions (STARTED vs PAUSED) => Correct resolution', () {
      resolver.reset(false);

      // Player in STARTED state: hasMediaConfig is true
      final startTransition = resolver.resolve(hasMediaConfig: true, isMusicActive: false);
      expect(startTransition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Player transitions to PAUSED: hasMediaConfig becomes false, music not active, not streaming
      final pauseTransition = resolver.resolve(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: false);
      expect(pauseTransition, equals(PlaybackTransition.stopped));
      expect(resolver.isCurrentlyPlaying, isFalse);
    });

    test('Test 3: isMusicActive transitions => Triggers start and sustains playback', () {
      resolver.reset(false);

      // When config is delayed but isMusicActive is true, transitions to active
      final startTransition = resolver.resolve(hasMediaConfig: false, isMusicActive: true);
      expect(startTransition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);

      // When isMusicActive drops but media config is present, remains active
      final sustainTransition = resolver.resolve(hasMediaConfig: true, isMusicActive: false);
      expect(sustainTransition, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 4: Multiple playback configs where one disappears but another remains => No AUDIO_STOPPED', () {
      resolver.reset(true);

      // Multiple configs exist (e.g. system sound ends, music remains) -> hasMediaConfig is true
      final transition = resolver.resolve(hasMediaConfig: true, isMusicActive: true, isA2dpStreaming: true);
      expect(transition, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 5: Genuine pause => Emits AUDIO_STOPPED exactly once', () {
      resolver.reset(true);

      // Genuine pause: all signals indicate no audio
      final transition = resolver.resolve(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: false);
      expect(transition, equals(PlaybackTransition.stopped));
      expect(resolver.isCurrentlyPlaying, isFalse);
      expect(resolver.getResolutionReason(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: false),
          equals('no_active_media_or_sound'));

      // Subsequent identical inactive call emits nothing
      final repeat = resolver.resolve(hasMediaConfig: false, isMusicActive: false, isA2dpStreaming: false);
      expect(repeat, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isFalse);
    });

    test('Test 6: Genuine resume => Emits AUDIO_STARTED exactly once', () {
      resolver.reset(false);

      // Resumes playback
      final transition = resolver.resolve(hasMediaConfig: true, isMusicActive: true, isA2dpStreaming: true);
      expect(transition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);
      expect(resolver.getResolutionReason(hasMediaConfig: true, isMusicActive: true, isA2dpStreaming: true),
          equals('active_media_configuration'));
    });

    test('Test 7: No duplicate start/stop events across repeated identical states', () {
      resolver.reset(false);

      // Start once
      expect(resolver.resolve(hasMediaConfig: true, isMusicActive: true), equals(PlaybackTransition.started));

      // 5 repeated active calls => all none
      for (int i = 0; i < 5; i++) {
        expect(resolver.resolve(hasMediaConfig: true, isMusicActive: true), equals(PlaybackTransition.none));
      }

      // Stop once
      expect(resolver.resolve(hasMediaConfig: false, isMusicActive: false), equals(PlaybackTransition.stopped));

      // 5 repeated inactive calls => all none
      for (int i = 0; i < 5; i++) {
        expect(resolver.resolve(hasMediaConfig: false, isMusicActive: false), equals(PlaybackTransition.none));
      }
    });
  });
}
