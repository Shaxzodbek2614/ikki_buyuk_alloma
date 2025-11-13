// lib/main.dart
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'audio_handler/my_audio_handler.dart';
import 'pages/home_page.dart';

// Config: assertga mos
Future<MyAudioHandler> initAudioService() async {
  return await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'uz.aloma.player.channel.audio',
      androidNotificationChannelName: 'Music playback',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      preloadArtwork: true,
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ❶ Faqat bir marta yaratiladi:
  final handlerFuture = initAudioService();
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }
  runApp(MyApp(audioHandlerFuture: handlerFuture));
}

class MyApp extends StatefulWidget {
  final Future<MyAudioHandler> audioHandlerFuture;
  const MyApp({super.key, required this.audioHandlerFuture});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // ❷ Memoize: Future qayta yaratilmaydi
  late final Future<MyAudioHandler> _future = widget.audioHandlerFuture;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FutureBuilder<MyAudioHandler>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return Scaffold(
              body: Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Ishga tushirishda xatolik:\n${snap.error}'),
              )),
            );
          }
          return HomePage(audioHandler: snap.data!);
        },
      ),
    );
  }
}
