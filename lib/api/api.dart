import 'dart:convert';
import 'package:http/http.dart' as http;

import '../model/api_item.dart';
import '../model/track.dart';


Future<List<ApiItem>> fetchApiItems() async {
  // O'zingizning endpoint'ingizni qo'ying:
  final uri = Uri.parse('http://64.225.63.121/api/audios/');
  final res = await http.get(uri).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw Exception('Server xatosi: ${res.statusCode}');
  }
  final List data = jsonDecode(res.body);
  return data.map((e) => ApiItem.fromJson(e)).toList();
}

class MasterGroup {
  final int id;
  final String name;
  final List<Track> tracks;
  MasterGroup({required this.id, required this.name, required this.tracks});
}

List<MasterGroup> groupByMaster(List<ApiItem> items) {
  final map = <int, MasterGroup>{};
  for (final it in items) {
    map.putIfAbsent(it.masterId, () => MasterGroup(id: it.masterId, name: it.masterName, tracks: []));
    map[it.masterId]!.tracks.add(Track(id: it.id, title: it.title, url: it.fileUrl));
  }
  return map.values.toList();
}
