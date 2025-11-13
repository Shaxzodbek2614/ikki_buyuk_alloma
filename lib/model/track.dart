// model/track.dart
class Track {
  final int id;
  final String title;
  final String? assetPath;
  final String? url;
  String? localPath;

  final int? masterId;
  final String? masterName;

  late final Duration? duration;   // NEW
  final double? sizeMb;       // NEW

  Track(
      this.title,
      this.assetPath, {
        this.id = 0,
        this.url,
        this.localPath,
        this.masterId,
        this.masterName,
        this.duration,            // NEW
        this.sizeMb,              // NEW
      });

  bool get isDownloaded => localPath != null && localPath!.isNotEmpty;
}
