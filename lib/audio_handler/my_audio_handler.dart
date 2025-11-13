import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../model/track.dart' show Track;

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  final _items = <MediaItem>[];
  ConcatenatingAudioSource? _playlist;

  // Subscriptions (tozalash uchun)
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<PlaybackEvent>? _playbackEventSub;
  StreamSubscription<SequenceState?>? _sequenceStateSub;

  MyAudioHandler() {
    _wirePlayerToHandler();
    _attachDebugLogs();
  }

  // Ixtiyoriy: debug loglar
  void _attachDebugLogs() {
    _playerStateSub = _player.playerStateStream.listen((st) {
      debugPrint('DBG playerState: playing=${st.playing} proc=${st.processingState}');
    });
    _playbackEventSub = _player.playbackEventStream.listen((ev) {
      debugPrint('DBG event: proc=${ev.processingState} pos=${ev.updatePosition} '
          'buff=${ev.bufferedPosition} idx=${ev.currentIndex}');
    });
  }

  // Track -> MediaItem
  MediaItem _toItem(Track t) {
    final uri = (t.localPath != null && t.localPath!.isNotEmpty)
        ? Uri.file(t.localPath!).toString()
        : (t.url ?? '');
    return MediaItem(
      id: uri,
      title: t.title,
      artist: t.masterName ?? '',
      duration: t.duration,
      extras: {
        'trackId': t.id,
        'masterId': t.masterId,
        'local': (t.localPath ?? '').isNotEmpty,
      },
    );
  }

  Future<void> _configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  Future<void> _setSource(
      List<MediaItem> items, {
        int initialIndex = 0,
        Duration? initialPosition,
      }) async {
    await _configureSession();

    // Oldingi playlist bilan to‘qnashmasin
    await _player.stop();
    _playlist = ConcatenatingAudioSource(
      children: items.map((m) => AudioSource.uri(Uri.parse(m.id))).toList(),
    );

    await _player.setAudioSource(
      _playlist!,
      initialIndex: initialIndex,
      initialPosition: initialPosition ?? Duration.zero,
    );

    if (items.isNotEmpty) {
      final idx = _player.currentIndex ?? initialIndex;
      if (idx >= 0 && idx < items.length) {
        mediaItem.add(items[idx]);
      } else {
        mediaItem.add(items[initialIndex]);
      }
    }
  }

  /// Navbatni o‘rnatish. `autoplay=false` bo‘lsa avtomatik ijro qilmaydi.
  Future<void> playQueue(
      List<Track> tracks, {
        int startIndex = 0,
        Duration? startPosition,
        bool autoplay = false,
      }) async {
    _items
      ..clear()
      ..addAll(tracks.map(_toItem));
    queue.add(_items); // media notification queue

    await _setSource(
      _items,
      initialIndex: startIndex,
      initialPosition: startPosition,
    );

    if (autoplay) {
      await play();
    }
  }

  // ---------- BaseAudioHandler overrides ----------
  @override
  Future<void> play() async {
    if (_player.sequence == null || _player.sequence!.isEmpty) return;

    final session = await AudioSession.instance;
    await session.setActive(true);

    if (_player.processingState == ProcessingState.completed) {
      final idx = _player.currentIndex ?? 0;
      await _player.seek(Duration.zero, index: idx);
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    final session = await AudioSession.instance;
    await session.setActive(false);
  }

  @override
  Future<void> stop() async {
    // Tozalash (onClose o‘rniga)
    try { await _player.stop(); } catch (_) {}
    try { await _playerStateSub?.cancel(); } catch (_) {}
    try { await _playbackEventSub?.cancel(); } catch (_) {}
    try { await _sequenceStateSub?.cancel(); } catch (_) {}
    try { await _player.dispose(); } catch (_) {}

    return super.stop();
  }

  @override
  Future<void> playPause() async {
    if (_player.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  void _wirePlayerToHandler() {
    _playbackEventSub ??= _player.playbackEventStream.listen((event) {
      final playing = _player.playing;

      final controls = playing
          ? const <MediaControl>[
        MediaControl.pause,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
        MediaControl.stop,
      ]
          : const <MediaControl>[
        MediaControl.play,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
        MediaControl.stop,
      ];

      playbackState.add(
        PlaybackState(
          controls: controls,
          androidCompactActionIndices: const [0, 1, 2],
          processingState: _mapProcessingState(event.processingState),
          updatePosition: event.updatePosition,
          bufferedPosition: event.bufferedPosition,
          queueIndex: event.currentIndex ?? _player.currentIndex,
          speed: _player.speed,
          systemActions: const {
            MediaAction.play,
            MediaAction.pause,
            MediaAction.playPause,
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
            MediaAction.skipToPrevious,
            MediaAction.skipToNext,
            MediaAction.stop,
          },
          playing: playing,
        ),
      );
    });

    _sequenceStateSub ??= _player.sequenceStateStream.listen((seq) {
      final idx = _player.currentIndex;
      if (idx != null && idx >= 0 && idx < _items.length) {
        mediaItem.add(_items[idx]);
      }
    });
  }

  AudioProcessingState _mapProcessingState(ProcessingState s) {
    switch (s) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  /// Track yuklab bo‘lingach, queue dagi mos elementni file URI ga ko‘tarish
  Future<void> promoteToLocalByTrackId(int trackId, String filePath) async {
    final i = _items.indexWhere(
          (m) => (m.extras?['trackId'] as int?) == trackId,
    );
    if (i == -1 || _playlist == null) return;

    final fileUri = Uri.file(filePath).toString();
    if (_items[i].id == fileUri) return;

    final updated = _items[i].copyWith(
      id: fileUri,
      extras: {
        ...?_items[i].extras,
        'local': true,
      },
    );
    _items[i] = updated;
    queue.add(_items);

    // Playlist ichida ham almashtiramiz
    await _playlist!.removeAt(i);
    await _playlist!.insert(i, AudioSource.uri(Uri.file(filePath)));
  }

  // Ixtiyoriy: UI uchun oqimlar
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<Duration> get bufferedPositionStream => _player.bufferedPositionStream;
}
