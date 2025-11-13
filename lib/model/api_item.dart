class ApiItem {
  final int id;
  final int masterId;
  final String masterName;
  final String title;
  final String? fileUrl;      // to‘liq http(s) URL
  final Duration duration;

  ApiItem({
    required this.id,
    required this.masterId,
    required this.masterName,
    required this.title,
    required this.fileUrl,
    required this.duration,
  });

  factory ApiItem.fromJson(Map<String, dynamic> j) {
    return ApiItem(
      id: j['id'] as int,
      masterId: j['master']['id'] as int,
      masterName: j['master']['name'] as String,
      title: j['name'] as String,
      fileUrl: j['file'] as String?,  // sizning JSON’da bor
      duration: _parseDur(j['duration'] as String),
    );
  }

  static Duration _parseDur(String s) {
    // "HH:MM:SS.micro" formatlarni ham yutib yuboradi
    final parts = s.split(':');                 // ["HH","MM","SS.micro"]
    final ss = double.parse(parts[2]);          // sekund + ulush
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final totalMs = ((h * 3600 + m * 60) * 1000) + (ss * 1000).round();
    return Duration(milliseconds: totalMs);
  }
}
