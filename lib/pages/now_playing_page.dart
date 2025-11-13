  import 'package:flutter/foundation.dart';
  import 'package:flutter/material.dart';

  class CarModePage extends StatelessWidget {
    final ValueListenable<String> titleListenable;
    final ValueListenable<bool> isPlayingListenable;
    final Future<void> Function() onNext;
    final Future<void> Function() onPrev;
    final Future<void> Function() onToggle;

    const CarModePage({
      super.key,
      required this.titleListenable,
      required this.isPlayingListenable,
      required this.onNext,
      required this.onPrev,
      required this.onToggle,
    });

    @override
    Widget build(BuildContext context) {
      const Color primary = Color(0xff6200ed);
      const Color surface = Color(0xff13002e);

      return Scaffold(
        backgroundColor: surface,
        appBar: AppBar(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          title: const Text('Машина режими', style: TextStyle(fontWeight: FontWeight.bold)),
          centerTitle: true,
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              final isWide = c.maxWidth > 480;
              final mainSize = isWide ? 200.0 : 200.0;
              final sideSize = isWide ? 85.0 : 70.0;
              final titleSize = isWide ? 32.0 : 26.0;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggle, // ekranning istalgan joyini bosganda play/pause
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),
                    ValueListenableBuilder<String>(
                      valueListenable: titleListenable,
                      builder: (_, title, __) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: titleSize,
                            fontFamily: "Yotiq",
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    ValueListenableBuilder<bool>(
                      valueListenable: isPlayingListenable,
                      builder: (_, playing, __) => _RoundControl(
                        icon: playing ? Icons.pause : Icons.play_arrow,
                        size: mainSize,
                        onTap: onToggle,
                        bg: Colors.white,
                        iconColor: surface,
                        border: Colors.white,
                        elevated: true,
                      ),
                    ),
                    const SizedBox(height: 40),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundControl(
                            icon: Icons.skip_previous,
                            size: sideSize,
                            onTap: onPrev,
                            bg: Colors.white.withOpacity(0.1),
                            iconColor: Colors.white,
                            border: Colors.white24,
                          ),
                          _RoundControl(
                            icon: Icons.skip_next,
                            size: sideSize,
                            onTap: onNext,
                            bg: Colors.white.withOpacity(0.1),
                            iconColor: Colors.white,
                            border: Colors.white24,
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(height: 20),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }
  }

  class _RoundControl extends StatelessWidget {
    final IconData icon;
    final double size;
    final VoidCallback onTap;
    final Color bg;
    final Color iconColor;
    final Color border;
    final bool elevated;

    const _RoundControl({
      required this.icon,
      required this.size,
      required this.onTap,
      required this.bg,
      required this.iconColor,
      required this.border,
      this.elevated = false,
    });

    @override
    Widget build(BuildContext context) {
      return Material(
        color: bg,
        shape: CircleBorder(side: BorderSide(color: border, width: 2)),
        elevation: elevated ? 8 : 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: iconColor, size: size * 0.45),
          ),
        ),
      );
    }
  }
