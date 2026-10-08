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
  }) {
    final isAudioActive = hasMediaConfig || isMusicActive;

    if (!_isPlaying && isAudioActive) {
      _isPlaying = true;
      return PlaybackTransition.started;
    } else if (_isPlaying && !hasMediaConfig && !isMusicActive) {
      _isPlaying = false;
      return PlaybackTransition.stopped;
    } else {
      return PlaybackTransition.none;
    }
  }

  void reset({bool initialPlaying = false}) {
    _isPlaying = initialPlaying;
  }
}

void main() {
  group('Native PlaybackStateResolver Specification Tests', () {
    late PlaybackStateResolver resolver;

    setUp(() {
      resolver = PlaybackStateResolver();
    });

    test('Test 1: Previous ACTIVE, config = none, isMusicActive = true => No AUDIO_STOPPED', () {
      // Setup: initially playing
      resolver.reset(initialPlaying: true);
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Media config temporarily disappears, but isMusicActive remains true
      final transition = resolver.resolve(hasMediaConfig: false, isMusicActive: true);

      // Must remain in active playing state and emit no STOPPED transition
      expect(transition, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 2: Previous ACTIVE, config = none, isMusicActive = false => One AUDIO_STOPPED', () {
      // Setup: initially playing
      resolver.reset(initialPlaying: true);
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Playback genuinely stopped
      final transition = resolver.resolve(hasMediaConfig: false, isMusicActive: false);

      // Transitions to inactive and emits STOPPED exactly once
      expect(transition, equals(PlaybackTransition.stopped));
      expect(resolver.isCurrentlyPlaying, isFalse);

      // Subsequent identical inactive callback emits nothing
      final nextTransition = resolver.resolve(hasMediaConfig: false, isMusicActive: false);
      expect(nextTransition, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isFalse);
    });

    test('Test 3: Previous INACTIVE, current active playback, isMusicActive = true => One AUDIO_STARTED', () {
      // Setup: initially inactive
      resolver.reset(initialPlaying: false);
      expect(resolver.isCurrentlyPlaying, isFalse);

      // Playback starts
      final transition = resolver.resolve(hasMediaConfig: true, isMusicActive: true);

      // Transitions to active and emits STARTED exactly once
      expect(transition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 4: Multiple playback configs where one disappears but another remains => No AUDIO_STOPPED', () {
      // Setup: initially playing
      resolver.reset(initialPlaying: true);

      // Scenario: Two playback configs were present, one disappears (e.g. system notification sound ends),
      // but media stream remains. hasMediaConfig is still true.
      final transition = resolver.resolve(hasMediaConfig: true, isMusicActive: true);

      expect(transition, equals(PlaybackTransition.none));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 5: Repeated ACTIVE callbacks => No duplicate AUDIO_STARTED', () {
      // Setup: start playback
      final firstTransition = resolver.resolve(hasMediaConfig: true, isMusicActive: true);
      expect(firstTransition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Repeated active callbacks
      for (int i = 0; i < 5; i++) {
        final repeatTransition = resolver.resolve(hasMediaConfig: true, isMusicActive: true);
        expect(repeatTransition, equals(PlaybackTransition.none),
            reason: 'Callback iteration $i should not emit duplicate STARTED');
      }
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 6: Temporary config disappearance followed by config returning while music remains active => No STOPPED -> STARTED cycle', () {
      // Step 1: Active music playback
      final start = resolver.resolve(hasMediaConfig: true, isMusicActive: true);
      expect(start, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Step 2: ExoPlayer / track transition transiently drops config to 0, but isMusicActive is true
      final transientDrop = resolver.resolve(hasMediaConfig: false, isMusicActive: true);
      expect(transientDrop, equals(PlaybackTransition.none),
          reason: 'Must NOT emit AUDIO_STOPPED during transient config drop');
      expect(resolver.isCurrentlyPlaying, isTrue);

      // Step 3: Config returns for new track
      final configReturns = resolver.resolve(hasMediaConfig: true, isMusicActive: true);
      expect(configReturns, equals(PlaybackTransition.none),
          reason: 'Must NOT emit duplicate AUDIO_STARTED when config returns');
      expect(resolver.isCurrentlyPlaying, isTrue);
    });

    test('Test 7: Start triggered by isMusicActive alone when config is delayed', () {
      // Some players render audio before AudioPlaybackConfiguration is published
      resolver.reset(initialPlaying: false);
      final transition = resolver.resolve(hasMediaConfig: false, isMusicActive: true);

      expect(transition, equals(PlaybackTransition.started));
      expect(resolver.isCurrentlyPlaying, isTrue);
    });
  });
}
