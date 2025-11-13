// lib/pages/home_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio_handler/my_audio_handler.dart';
import '../model/track.dart';
import 'now_playing_page.dart';

class HomePage extends StatefulWidget {
  final MyAudioHandler audioHandler;
  const HomePage({super.key, required this.audioHandler});

  @override
  State<HomePage> createState() => _HomePageState();
}

// Ustoz (master) bo'yicha guruh
class MasterGroup {
  final int id;
  final String name;
  final List<Track> tracks;
  MasterGroup({required this.id, required this.name, required this.tracks});
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  // === Services
  MyAudioHandler get audioHandler => widget.audioHandler;

  // === API
  static const String apiUrl = 'http://64.225.63.121/api/audios';

  // CarMode uchun VN’lar
  final ValueNotifier<String> _titleVN = ValueNotifier<String>('');
  final ValueNotifier<bool> _playingVN = ValueNotifier<bool>(false);

  // === Persist keys
  static const _prefKeyLastState  = 'last_playback_state';
  static const _prefKeyMasters    = 'cached_masters_map';     // id->name
  static const _prefKeyDurations  = 'cached_durations_ms';    // key -> ms
  static const _prefKeyRawTracks  = 'cached_tracks_raw_list'; // API xom ro'yxat

  // === UI / Net
  bool _loaded = false;
  bool _online = true;
  String? _error;

  // === Data
  final Map<int, String> _masters = {};
  final List<int> _masterOrder = [];
  List<MasterGroup> _groups = [];

  // === Playback mirrors
  late final StreamSubscription<PlaybackState> _psSub;
  late final StreamSubscription<MediaItem?> _miSub;
  late final StreamSubscription<Duration> _posSub;

  // Slider uchun silliq pozitsiya
  PlaybackState? _lastPs;

  bool isPlaying = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String nowTitle = '';
  int _playingTab = 0;
  final Map<int, int> _currentIndexMap = {}; // tab -> index

  // === Scroll per tab
  final Map<int, ScrollController> _tabScrollCtrls = {};
  TabController? _tabCtrl;

  // === Downloads
  final Map<int, double> _progress = {};
  final Set<int> _downloading = {};

  // === Connectivity (5.x: yagona ConnectivityResult oqimi)
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  // === Debounce saver
  Timer? _debounceSaver;

  // === “Resume Candidate”
  int? _resumeTab;
  int? _resumeIndex;
  int? _resumeTrackId;
  int? _resumePosMs;

  // === Duration cache
  Map<String, int> _durationCache = {};
  final Set<String> _probing = {};

  // ==== Utils
  String _safe(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();

  Duration _parseDuration(String s) {
    final p = s.split(':');
    int h = 0, m = 0;
    double sec = 0;
    if (p.length == 3) {
      h = int.tryParse(p[0]) ?? 0;
      m = int.tryParse(p[1]) ?? 0;
      sec = double.tryParse(p[2]) ?? 0;
    } else if (p.length == 2) {
      m = int.tryParse(p[0]) ?? 0;
      sec = double.tryParse(p[1]) ?? 0;
    } else if (p.length == 1) {
      sec = double.tryParse(p[0]) ?? 0;
    }
    return Duration(milliseconds: ((h * 3600 + m * 60) * 1000 + (sec * 1000).round()));
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String _fmtClock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String _fmtSize(double? mb) =>
      mb == null ? '—' : '${mb.toStringAsFixed(2).replaceAll('.', ',')}Мб';

  // ==== Disk paths
  Future<String> _tracksDirPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/tracks');
    if (!await folder.exists()) await folder.create(recursive: true);
    return folder.path;
  }

  Future<File> _localFileFor(Track t) async {
    final base = await _tracksDirPath();
    return File('$base/${t.masterId}_${t.id}_${_safe(t.title)}.mp3');
  }

  // ==== Duration cache helpers
  Future<void> _loadDurationCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKeyDurations);
    if (raw == null) return;
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      _durationCache = m.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {}
  }

  Future<void> _saveDurationCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyDurations, jsonEncode(_durationCache));
  }

  String _durationKeyFor(Track t) {
    return (t.localPath != null && t.localPath!.isNotEmpty)
        ? t.localPath!
        : (t.url ?? 'id:${t.id}');
  }

  Future<void> _ensureDurationFor(Track t) async {
    if (t.duration != null) return;

    final key = _durationKeyFor(t);
    final cachedMs = _durationCache[key];
    if (cachedMs != null && cachedMs > 0) {
      if (mounted) setState(() => t.duration = Duration(milliseconds: cachedMs));
      return;
    }

    if (_probing.contains(key)) return;
    _probing.add(key);

    try {
      final player = AudioPlayer();
      try {
        if ((t.localPath ?? '').isNotEmpty) {
          await player.setFilePath(t.localPath!);
        } else if ((t.url ?? '').isNotEmpty) {
          await player.setUrl(t.url!);
        } else {
          return;
        }

        final d = await player.durationStream
            .firstWhere((d) => d != null, orElse: () => null)
            .timeout(const Duration(seconds: 3), onTimeout: () => null);

        if (d != null && mounted) {
          setState(() => t.duration = d);
          _durationCache[key] = d.inMilliseconds;
          await _saveDurationCache();
        }
      } finally {
        await player.dispose();
      }
    } catch (_) {
      // duration bo'lmasa ham ijro etilishi mumkin
    } finally {
      _probing.remove(key);
    }
  }

  // ==== API
  Future<List<Map<String, dynamic>>> _fetchRaw() async {
    final res = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('Server: ${res.statusCode}');
    final body = jsonDecode(res.body);
    if (body is List) return body.cast<Map<String, dynamic>>();
    throw Exception('Noto‘g‘ri JSON');
  }

  Future<void> _loadFromApi() async {
    final raw = await _fetchRaw();
    final map = <int, MasterGroup>{};

    for (final j in raw) {
      final master = j['master'] as Map<String, dynamic>;
      final mid = (master['id'] as num).toInt();
      final mname = master['name'] as String;

      _masters[mid] = mname;
      if (!_masterOrder.contains(mid)) _masterOrder.add(mid);
      map.putIfAbsent(mid, () => MasterGroup(id: mid, name: mname, tracks: []));

      final id = (j['id'] as num).toInt();
      final title = j['name'] as String;
      final url = j['file'] as String?;
      final dur = _parseDuration((j['duration'] as String?) ?? '0');
      final sizeMb = (j['size'] as num?)?.toDouble();

      final t = Track(
        title, null,
        id: id,
        url: url,
        masterId: mid,
        masterName: mname,
        duration: dur,
        sizeMb: sizeMb,
      );

      final f = await _localFileFor(t);
      if (await f.exists()) t.localPath = f.path;

      map[mid]!.tracks.add(t);
    }

    _groups = _orderByMasters(map);

    // Kesh: ustoz nomlari + xom ro'yxat
    final prefs = await SharedPreferences.getInstance();
    final names = _masters.map((k, v) => MapEntry(k.toString(), v));
    await prefs.setString(_prefKeyMasters, jsonEncode(names));
    await prefs.setString(_prefKeyRawTracks, jsonEncode(raw));
  }

  Future<bool> _loadFromCachedRaw() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKeyRawTracks);
      if (saved == null) return false;

      final raw = (jsonDecode(saved) as List).cast<Map<String, dynamic>>();
      final map = <int, MasterGroup>{};

      await _loadMastersFromCacheIfAny();

      for (final j in raw) {
        final master = j['master'] as Map<String, dynamic>;
        final mid = (master['id'] as num).toInt();
        final mname = (master['name'] as String?) ?? _masters[mid] ?? 'Ustoz $mid';

        _masters[mid] = mname;
        if (!_masterOrder.contains(mid)) _masterOrder.add(mid);
        map.putIfAbsent(mid, () => MasterGroup(id: mid, name: mname, tracks: []));

        final id = (j['id'] as num).toInt();
        final title = j['name'] as String? ?? 'Track $id';
        final url = j['file'] as String?;
        final dur = _parseDuration((j['duration'] as String?) ?? '0');
        final sizeMb = (j['size'] as num?)?.toDouble();

        final t = Track(
          title, null,
          id: id,
          url: url,
          masterId: mid,
          masterName: mname,
          duration: dur,
          sizeMb: sizeMb,
        );

        final f = await _localFileFor(t);
        if (await f.exists()) t.localPath = f.path;

        if (t.duration == null) {
          final key = _durationKeyFor(t);
          final cachedMs = _durationCache[key];
          if (cachedMs != null && cachedMs > 0) {
            t.duration = Duration(milliseconds: cachedMs);
          }
        }

        map[mid]!.tracks.add(t);
      }

      _groups = _orderByMasters(map);

      // UI tezligi uchun bir nechta duration’ni fon’da to‘ldiramiz
      for (final g in _groups) {
        for (final t in g.tracks.take(8)) {
          if (t.duration == null) _ensureDurationFor(t);
        }
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  List<MasterGroup> _orderByMasters(Map<int, MasterGroup> map) {
    final out = <MasterGroup>[];
    if (_masterOrder.isNotEmpty) {
      for (final mid in _masterOrder) {
        final g = map[mid] ?? MasterGroup(id: mid, name: _masters[mid] ?? 'Ustoz $mid', tracks: []);
        out.add(g);
      }
    } else {
      out.addAll(map.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
      for (final g in out) {
        _masters[g.id] = g.name;
        _masterOrder.add(g.id);
      }
    }
    return out;
  }

  Future<void> _loadMastersFromCacheIfAny() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKeyMasters);
    if (saved == null) return;
    try {
      final map = (jsonDecode(saved) as Map).cast<String, dynamic>();
      _masters.clear();
      for (final e in map.entries) {
        final id = int.tryParse(e.key);
        if (id != null) _masters[id] = e.value.toString();
      }
    } catch (_) {}
  }

  Future<bool> _loadFromDiskDownloads() async {
    try {
      await _loadMastersFromCacheIfAny();

      final dir = Directory(await _tracksDirPath());
      if (!await dir.exists()) return false;
      final files = await dir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.mp3'))
          .cast<File>()
          .toList();
      if (files.isEmpty) return false;

      final map = <int, MasterGroup>{};
      for (final f in files) {
        final base = f.path.split('/').last.replaceAll('.mp3', '');
        int? masterId;
        int? trackId;
        String title = base;
        final parts = base.split('_'); // masterId_trackId_title
        if (parts.length >= 3) {
          masterId = int.tryParse(parts[0]);
          trackId  = int.tryParse(parts[1]);
          title    = parts.sublist(2).join('_');
        }
        masterId ??= -1;
        trackId ??= DateTime.now().millisecondsSinceEpoch;

        final mname = _masters[masterId] ?? (masterId == -1 ? 'Yuklab olinganlar' : 'Ustoz $masterId');
        _masters[masterId] = mname;
        if (!_masterOrder.contains(masterId)) _masterOrder.add(masterId);

        map.putIfAbsent(masterId, () => MasterGroup(id: masterId!, name: mname, tracks: []));
        final t = Track(
          title, null,
          id: trackId!, url: null,
          masterId: masterId, masterName: mname,
          duration: null,
          sizeMb: (f.lengthSync() / (1024 * 1024)),
        )..localPath = f.path;

        final key = _durationKeyFor(t);
        final cachedMs = _durationCache[key];
        if (cachedMs != null && cachedMs > 0) {
          t.duration = Duration(milliseconds: cachedMs);
        }

        map[masterId]!.tracks.add(t);
      }

      _groups = _orderByMasters(map);

      for (final g in _groups) {
        for (final t in g.tracks.take(8)) {
          if (t.duration == null) _ensureDurationFor(t);
        }
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  // ==== Downloads
  DateTime? _lastNetWarnAt;
  void _warnNoInternetOnce() {
    final now = DateTime.now();
    if (_lastNetWarnAt != null && now.difference(_lastNetWarnAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastNetWarnAt = now;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Интернетга уланинг')));
  }

  Future<void> _downloadTrack(Track t) async {
    if (!_online) {
      _warnNoInternetOnce();
      return;
    }
    if (t.url == null || t.url!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('URL топилмади')));
      return;
    }
    try {
      if (mounted) setState(() => _progress[t.id] = 0);
      final file = await _localFileFor(t);
      await Dio().download(
        t.url!, file.path,
        onReceiveProgress: (r, total) {
          if (total > 0 && mounted) setState(() => _progress[t.id] = r / total);
        },
      );
      t.localPath = file.path;
      await audioHandler.promoteToLocalByTrackId(t.id, file.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Юклаб олинди ✅')));
      setState(() {});
      await _ensureDurationFor(t);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Internetga ulaning')));
    } finally {
      if (mounted) setState(() => _progress.remove(t.id));
    }
  }

  // ==== Player helpers
  List<Track> _tracksOf(int tab) => _groups[tab].tracks;
  int _currentIndexOf(int tab) => _currentIndexMap[tab] ?? 0;
  void _setCurrentIndexOf(int tab, int idx) => _currentIndexMap[tab] = idx;

  Future<void> _playQueue(List<Track> list, int index) async {
    await audioHandler.playQueue(list, startIndex: index);
  }

  void _clearResumeCandidate() {
    _resumeTab = null;
    _resumeIndex = null;
    _resumeTrackId = null;
    _resumePosMs = null;
  }

  Future<void> _onItemTap({required int tab, required int index}) async {
    final list = _tracksOf(tab);
    if (index < 0 || index >= list.length) return;
    final t = list[index];

    final isResumeCandidate = (_resumeTab == tab) &&
        (_resumeIndex == index) &&
        (_resumeTrackId == t.id) &&
        (_resumePosMs != null && _resumePosMs! > 0);

    if (isResumeCandidate) {
      await audioHandler.play();
      _clearResumeCandidate();
      return;
    }

    _clearResumeCandidate();
    _playingTab = tab;
    _setCurrentIndexOf(tab, index);
    await _playQueue(list, index);
    await audioHandler.play();

    if (list.isNotEmpty) {
      final nextIndex = (index + 1) % list.length;
      _ensureDownloadedInBackground(list[nextIndex]);
    }
  }

  Future<void> _ensureDownloadedInBackground(Track t) async {
    if (t.isDownloaded || t.url == null || _downloading.contains(t.id)) return;
    _downloading.add(t.id);
    try { await _downloadTrack(t); } catch (_) {} finally { _downloading.remove(t.id); }
  }

  Future<void> _next() => audioHandler.skipToNext();
  Future<void> _prev() => audioHandler.skipToPrevious();

  Future<void> _seekRelativeSeconds(int d) async {
    final st = _lastPs;
    final base = st?.position ?? Duration.zero;
    var tgt = base + Duration(seconds: d);
    if (tgt.isNegative) tgt = Duration.zero;
    await audioHandler.seek(tgt);
  }

  // ==== Persist & restore
  Future<void> _savePlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final mi = await audioHandler.mediaItem.first;
    final ps = _lastPs ?? await audioHandler.playbackState.first;
    if (mi == null) return;

    final saved = {
      'playingTab': _playingTab,
      'trackId': _trackIdFromMediaItem(mi),
      'positionMillis': ps.position.inMilliseconds, // 🔥 to‘g‘ridan-to‘g‘ri
    };
    await prefs.setString(_prefKeyLastState, jsonEncode(saved));
  }

  Future<void> _restorePlaybackStateAndScroll() async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(_prefKeyLastState);
    if (savedJson == null) return;

    Map<String, dynamic> saved;
    try {
      saved = jsonDecode(savedJson) as Map<String, dynamic>;
    } catch (_) { return; }

    final tab = (saved['playingTab'] as num?)?.toInt();
    final trackId = (saved['trackId'] as num?)?.toInt();
    final posMs = (saved['positionMillis'] as num?)?.toInt();
    if (tab == null || trackId == null || posMs == null) return;
    if (tab < 0 || tab >= _groups.length) return;

    final list = _tracksOf(tab);
    final index = list.indexWhere((t) => t.id == trackId);
    if (index == -1) return;

    _playingTab = tab;
    _setCurrentIndexOf(tab, index);
    if (_tabCtrl?.index != tab) _tabCtrl?.index = tab;

    await _playQueue(list, index);
    final restorePosition = Duration(milliseconds: posMs);
    await audioHandler.seek(restorePosition);
    await audioHandler.pause();

    final sel = list[index];
    if (sel.duration == null) {
      final key = _durationKeyFor(sel);
      final cached = _durationCache[key];
      if (cached != null && cached > 0) {
        sel.duration = Duration(milliseconds: cached);
      } else {
        _ensureDurationFor(sel);
      }
    }

    if (!mounted) return;
    setState(() {
      position = restorePosition;
      nowTitle = sel.title;
      duration = sel.duration ?? Duration.zero;
    });

    _resumeTab = tab;
    _resumeIndex = index;
    _resumeTrackId = trackId;
    _resumePosMs = posMs;

    _jumpToIndexSmooth(tab: tab, index: index);
  }

  void _jumpToIndexSmooth({required int tab, required int index}) {
    final c = _tabScrollCtrls.putIfAbsent(tab, () => ScrollController());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!c.hasClients) return;
      double est = (index * 72.0).clamp(0, c.position.maxScrollExtent);
      c.jumpTo(est);
    });
  }

  void _openCurrentTrackInList() {
    if (_groups.isEmpty) return;

    // Qaysi tabda ijro ketayotgan bo'lsa — o'sha
    int tab = _playingTab;
    if (tab < 0 || tab >= _groups.length) {
      // Agar hali hech narsa o'ynamagan bo'lsa — 0-tab
      tab = 0;
    }

    // Shu tabdagi hozirgi trek indexi
    int index = _currentIndexOf(tab);
    if (index < 0 || index >= _tracksOf(tab).length) {
      index = 0;
    }

    // TabBar bo'lsa — o'sha tabga o'tamiz
    if (_tabCtrl != null && _tabCtrl!.index != tab) {
      _tabCtrl!.animateTo(tab);
    }

    // Ro'yxatda o'sha elementga skroll qilamiz
    _jumpToIndexSmooth(tab: tab, index: index);
  }


  int? _trackIdFromMediaItem(MediaItem? mi) {
    final x = mi?.extras;
    if (x == null) return null;
    final v = x['trackId'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }






  String _mediaIdForTrack(Track t) {
    return (t.localPath != null && t.localPath!.isNotEmpty)
        ? Uri.file(t.localPath!).toString()
        : (t.url ?? '');
  }

  void _maybePrefetchNext(List<Track> list, int currentIndex) {
    if (list.isEmpty) return;
    final nextIndex = (currentIndex + 1) % list.length;
    final nextTrack = list[nextIndex];
    _ensureDownloadedInBackground(nextTrack);
  }

  // ==== Lifecycle
  @override
  void initState() {
    super.initState();
    _loadDurationCache();

    // PlaybackState oqimi
    _psSub = audioHandler.playbackState.listen((ps) {
      _playingVN.value = ps.playing;
      _lastPs = ps;
      if (!mounted) return;

      if (ps.playing != isPlaying) {
        setState(() => isPlaying = ps.playing);
      }

      // Prefetch
      if (ps.playing) {
        final tab = _playingTab;
        if (tab >= 0 && tab < _groups.length) {
          final list = _groups[tab].tracks;
          final idx  = _currentIndexMap[tab] ?? -1;
          if (idx >= 0 && idx < list.length) {
            _maybePrefetchNext(list, idx);
          }
        }
      }

      // Debounced save
      _debounceSaver?.cancel();
      _debounceSaver = Timer(const Duration(seconds: 2), () {
        if (_lastPs?.playing == true) _savePlaybackState();
      });
    });

    _miSub = audioHandler.mediaItem.listen((mi) {
      _titleVN.value = mi?.title ?? '';
      if (!mounted) return;

      setState(() {
        nowTitle = mi?.title ?? '';
        duration = mi?.duration ?? Duration.zero;
      });

      if (mi == null) return;

      for (int tab = 0; tab < _groups.length; tab++) {
        final list = _groups[tab].tracks;
        final idx = list.indexWhere((t) => _mediaIdForTrack(t) == mi.id);
        if (idx != -1) {
          setState(() {
            _playingTab = tab;
            _currentIndexMap[tab] = idx;
          });
          _maybePrefetchNext(list, idx);
          break;
        }
      }
    });

    // Ticker
    _posSub = audioHandler.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => position = pos);
    });

    // Net + birinchi yuklash
    () async {
      final initialConn = await Connectivity().checkConnectivity();
      _online = initialConn != ConnectivityResult.none;

      _connSub = Connectivity().onConnectivityChanged.listen((result) async {
        final wasOnline = _online;
        _online = result != ConnectivityResult.none;

        if (_online && !wasOnline) {
          try {
            await _loadFromApi(); // kesh ham yangilanadi
            if (mounted) setState(() {});
          } catch (_) {}
        } else if (!_online && wasOnline) {
          // Offline bo'ldi — HECH NIMA filtrlab yubormaymiz, keshdagi to‘liq ro‘yxat qoladi
          if (mounted) setState(() {});
        }
      });

      try {
        if (_online) {
          await _loadFromApi();
        } else {
          bool ok = await _loadFromCachedRaw();     // to‘liq kesh
          if (!ok) ok = await _loadFromDiskDownloads(); // bo‘lmasa diskdagi mp3
          if (!ok) _groups = [];
        }

        if (!mounted) return;
        _tabCtrl = TabController(
          length: _groups.length,
          vsync: this,
          initialIndex: (_playingTab >= 0 && _playingTab < _groups.length) ? _playingTab : 0,
        )..addListener(() { if (mounted) setState(() {}); });

        setState(() => _loaded = true);
        await _restorePlaybackStateAndScroll();
      } catch (e) {
        bool ok = await _loadFromCachedRaw();
        if (!ok) ok = await _loadFromDiskDownloads();
        _error = e.toString();
        if (!ok) _groups = [];
        if (!mounted) return;
        _tabCtrl = TabController(length: _groups.length, vsync: this, initialIndex: 0);
        setState(() => _loaded = true);
        await _restorePlaybackStateAndScroll();
      }
    }();
  }

  @override
  void dispose() {
    _debounceSaver?.cancel();
    _savePlaybackState();
    _psSub.cancel();
    _titleVN.dispose();
    _playingVN.dispose();
    _miSub.cancel();
    _connSub?.cancel();
    _posSub.cancel();
    for (final c in _tabScrollCtrls.values) { c.dispose(); }
    _tabCtrl?.dispose();
    super.dispose();
  }

  // ==== UI helpers
  Widget _tileFor(Track t, bool isCurrentPlaying, VoidCallback onTap) {
    final pr = _progress[t.id];
    Widget trailing;
    if (pr != null) {
      trailing = SizedBox(
        width: 28, height: 28,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CircularProgressIndicator(value: pr, strokeWidth: 3),
            Center(child: Text('${(pr * 100).round()}%', style: const TextStyle(fontSize: 9))),
          ],
        ),
      );
    } else if (t.isDownloaded) {
      trailing = const Icon(Icons.download_done_rounded, color: Colors.indigo);
    } else {
      trailing = IconButton(
        padding: const EdgeInsets.only(left: 20),
        icon: const Icon(Icons.download),
        onPressed: () => _downloadTrack(t), // offline bo'lsa SnackBar ko'rsatadi
      );
    }

    final icon = isCurrentPlaying
        ? (isPlaying ? Icons.graphic_eq : Icons.pause_circle_filled)
        : Icons.music_note;

    return ListTile(
      leading: Icon(icon, color: isCurrentPlaying ? Colors.indigo : null),
      title: Text(t.title, style: const TextStyle(fontFamily: 'Yotiq', fontWeight: FontWeight.w600)),
      subtitle: Row(
        children: [
          const Icon(Icons.access_time, size: 14, color: Colors.black45), const SizedBox(width: 4),
          Text(_fmtClock(t.duration ?? Duration.zero), style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(width: 12),
          const Icon(Icons.sd_storage, size: 14, color: Colors.black45), const SizedBox(width: 4),
          Text(_fmtSize(t.sizeMb), style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
      onTap: onTap,
      trailing: trailing,
    );
  }

  Widget _buildList(int tab) {
    final list = _tracksOf(tab);
    final playingIdx = _currentIndexOf(_playingTab);

    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text('Бу устоз учун треклар топилмади'),
        ),
      );
    }

    final controller = _tabScrollCtrls.putIfAbsent(tab, () => ScrollController());

    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = list[i];

        if (t.duration == null) {
          _ensureDurationFor(t);
        }

        final isCurrentPlaying = (tab == _playingTab) && (i == playingIdx);
        return _tileFor(t, isCurrentPlaying, () => _onItemTap(tab: tab, index: i));
      },
    );
  }

  Widget _buildNowPlayingBar() {
    double max = duration.inMilliseconds.toDouble().clamp(0, double.infinity);
    double value = position.inMilliseconds.toDouble().clamp(0, max);

    return Material(
      elevation: 8,
      color: const Color(0xff13002e),
      child: InkWell(
        onTap: _openCurrentTrackInList,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(nowTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontFamily: "Yotiq")),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(iconSize: 34, onPressed: _prev, icon: const Icon(Icons.skip_previous, color: Colors.white)),
                    IconButton(iconSize: 30, onPressed: () => _seekRelativeSeconds(-5), icon: const Icon(Icons.replay_5, color: Colors.white)),
                    IconButton(
                      iconSize: 34,
                      onPressed: () async {
                        if (isPlaying) {
                          await audioHandler.pause();
                        } else {
                          await audioHandler.play();
                          _clearResumeCandidate();
                        }
                      },
                      icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                    ),
                    IconButton(iconSize: 30, onPressed: () => _seekRelativeSeconds(5), icon: const Icon(Icons.forward_5, color: Colors.white)),
                    IconButton(iconSize: 34, onPressed: _next, icon: const Icon(Icons.skip_next, color: Colors.white)),
                  ],
                ),
                Row(
                  children: [
                    Text(_fmt(position), style: const TextStyle(fontSize: 12, color: Colors.white)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Slider(
                        activeColor: Colors.white,
                        inactiveColor: Colors.grey,
                        min: 0,
                        max: max > 0 ? max : 1,
                        value: value,
                        onChanged: (v) => setState(() => position = Duration(milliseconds: v.toInt())),
                        onChangeEnd: (v) async => audioHandler.seek(Duration(milliseconds: v.toInt())),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(_fmt(duration), style: const TextStyle(fontSize: 12, color: Colors.white)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==== Build
  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final tabCount = _groups.length;

    if (tabCount == 0) {
      return Scaffold(
        appBar: AppBar(
          leading: Image.asset("assets/images/img.png"),
          title: const Text('Икки буюк Aллома', style: TextStyle(fontFamily: 'Yotiq', fontStyle: FontStyle.italic)),
          foregroundColor: Colors.white,
          backgroundColor: const Color(0xff6200ed),
          actions: [
            if (!_online)
              const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.wifi_off, color: Colors.yellowAccent)),
          ],
        ),
        body: Center(child: Text(_online ? (_error ?? 'Треклар топилмади') : 'Оффлайн: kesh yoki yuklab olinganlar topilmadi')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: Image.asset("assets/images/img.png"),
        title: const Text('Икки буюк Aллома', style: TextStyle(fontFamily: 'Yotiq', fontStyle: FontStyle.italic)),
        foregroundColor: Colors.white,
        backgroundColor: const Color(0xff6200ed),
        actions: [
          if (!_online)
            const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.wifi_off, color: Colors.yellowAccent)),
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CarModePage(
                    titleListenable: _titleVN,
                    isPlayingListenable: _playingVN,
                    onNext: _next,
                    onPrev: _prev,
                    onToggle: () async {
                      if (isPlaying) {
                        await audioHandler.pause();
                      } else {
                        await audioHandler.play();
                        _clearResumeCandidate();
                      }
                    },
                  ),
                ),
              );
            },
            icon: Image.asset("assets/icons/wheel.png", width: 26),
          ),
          IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
        ],
        bottom: (tabCount > 1)
            ? TabBar(
          controller: _tabCtrl,
          isScrollable: false,
          labelColor: Colors.white,
          indicatorWeight: 3,
          indicatorColor: Colors.white,
          labelStyle: TextStyle(fontWeight: FontWeight.bold),
          unselectedLabelColor: Colors.white70,
          indicatorSize: TabBarIndicatorSize.tab,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          tabs: [
            for (final g in _groups)
              Tab(
                child: Text(
                  g.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
        )
            : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: (tabCount > 1)
                ? TabBarView(
              controller: _tabCtrl,
              children: [for (int i = 0; i < tabCount; i++) _buildList(i)],
            )
                : _buildList(0),
          ),
          _buildNowPlayingBar(),
        ],
      ),
    );
  }
}
