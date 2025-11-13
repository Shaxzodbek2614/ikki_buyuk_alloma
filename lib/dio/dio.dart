import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../model/track.dart';

String _safe(String s) => s
    .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Future<String> getTracksDirPath() async {
  final dir = await getApplicationDocumentsDirectory(); // /data/data/<app>/files
  final folder = Directory('${dir.path}/tracks');
  if (!await folder.exists()) await folder.create(recursive: true);
  return folder.path;
}

Future<File> localFileFor(Track t) async {
  final base = await getTracksDirPath();
  final name = '${t.id}_${_safe(t.title)}.mp3';
  return File('$base/$name');
}

Future<void> downloadTrack(Track t, void Function(double p) onProgress) async {
  if (t.url == null) throw Exception('URL mavjud emas');
  final saveFile = await localFileFor(t);
  final dio = Dio();
  await dio.download(
    t.url!,
    saveFile.path,
    onReceiveProgress: (rec, total) {
      if (total > 0) onProgress(rec / total); // 0..1
    },
    options: Options(responseType: ResponseType.bytes, followRedirects: true),
  );
  t.localPath = saveFile.path;
}
