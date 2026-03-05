import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

const _desktopTargets = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
};

bool get _isDesktop =>
    !kIsWeb && _desktopTargets.contains(defaultTargetPlatform);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setAsFrameless();

    const windowOptions = WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(940, 620),
      center: true,
      backgroundColor: Colors.transparent,
      title: 'Cozy Glass Window',
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const CozyGlassApp());
}

class CozyGlassApp extends StatelessWidget {
  const CozyGlassApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Cozy Glass Window',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Segoe UI',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD08B5B),
          brightness: Brightness.dark,
        ),
      ),
      home: const CozyWindowPage(),
    );
  }
}

class CozyWindowPage extends StatefulWidget {
  const CozyWindowPage({super.key});

  @override
  State<CozyWindowPage> createState() => _CozyWindowPageState();
}

class _CozyWindowPageState extends State<CozyWindowPage> with WindowListener {
  double _glassOpacity = 0.85;
  double _blurSigma = 18;
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      windowManager.addListener(this);
      _syncWindowState();
    }
  }

  Future<void> _syncWindowState() async {
    _isMaximized = await windowManager.isMaximized();
    await windowManager.setOpacity(_glassOpacity);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _onWindowOpacityChanged(double value) async {
    setState(() => _glassOpacity = value);
    if (_isDesktop) {
      await windowManager.setOpacity(value);
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) {
      setState(() => _isMaximized = true);
    }
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) {
      setState(() => _isMaximized = false);
    }
  }

  Future<void> _onMinimize() async {
    if (_isDesktop) await windowManager.minimize();
  }

  Future<void> _onToggleMaximize() async {
    if (!_isDesktop) return;

    final currentlyMaximized = await windowManager.isMaximized();
    if (currentlyMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _onClose() async {
    if (_isDesktop) {
      await windowManager.close();
      return;
    }
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        padding: EdgeInsets.all(_isDesktop && !_isMaximized ? 10 : 0),
        child: _GlassWindow(
          blurSigma: _blurSigma,
          glassOpacity: _glassOpacity,
          isMaximized: _isMaximized,
          onMinimize: _onMinimize,
          onToggleMaximize: _onToggleMaximize,
          onClose: _onClose,
          onOpacityChanged: (value) {
            _onWindowOpacityChanged(value);
          },
          onBlurChanged: (value) {
            setState(() => _blurSigma = value);
          },
        ),
      ),
    );

    if (_isDesktop) {
      return DragToResizeArea(child: content);
    }

    return content;
  }
}

class _GlassWindow extends StatelessWidget {
  const _GlassWindow({
    required this.blurSigma,
    required this.glassOpacity,
    required this.isMaximized,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    required this.onOpacityChanged,
    required this.onBlurChanged,
  });

  final double blurSigma;
  final double glassOpacity;
  final bool isMaximized;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<double> onBlurChanged;

  @override
  Widget build(BuildContext context) {
    const windowRadius = 40.0;
    final opacityFactor = ((glassOpacity - 0.18) / 0.82).clamp(0.0, 1.0);
    final frameStrength = opacityFactor;
    final blurFactor = (blurSigma / 48).clamp(0.0, 1.0);
    final bgTop = Color.lerp(
      const Color(0xFF171320),
      const Color(0xFF9C6C58),
      opacityFactor,
    )!;
    final bgMiddle = Color.lerp(
      const Color(0xFF0D2232),
      const Color(0xFF3C7687),
      opacityFactor,
    )!;
    final bgBottom = Color.lerp(
      const Color(0xFF0B1324),
      const Color(0xFF48639B),
      opacityFactor,
    )!;
    final glassTopTint = Color.lerp(
      const Color(0x1EFFFFFF),
      const Color(0x73FFD4B0),
      opacityFactor,
    )!;
    final glassBottomTint = Color.lerp(
      const Color(0x10FFFFFF),
      const Color(0x554BC9FF),
      opacityFactor,
    )!;

    return ClipRRect(
      borderRadius: BorderRadius.circular(windowRadius),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [bgTop, bgMiddle, bgBottom],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Stack(
              children: [
                _SoftBlob(
                  alignment: const Alignment(-0.9, -0.85),
                  size: 380,
                  color:
                      const Color(0x66FF8B6A).withValues(alpha: glassOpacity),
                ),
                _SoftBlob(
                  alignment: const Alignment(0.95, -0.5),
                  size: 420,
                  color:
                      const Color(0x6676E0FF).withValues(alpha: glassOpacity),
                ),
                _SoftBlob(
                  alignment: const Alignment(0.1, 0.92),
                  size: 520,
                  color:
                      const Color(0x5542D6A4).withValues(alpha: glassOpacity),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 10 + (blurSigma * 0.75),
                  sigmaY: 10 + (blurSigma * 0.75),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: const Alignment(-0.7, -1),
                      end: const Alignment(0.8, 1),
                      colors: [
                        const Color(0x55FFFFFF)
                            .withValues(alpha: 0.10 + (opacityFactor * 0.22)),
                        const Color(0x44A5D6FF)
                            .withValues(alpha: 0.06 + (blurFactor * 0.14)),
                        const Color(0x55FFD7B8)
                            .withValues(alpha: 0.05 + (opacityFactor * 0.16)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(windowRadius),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      glassTopTint.withValues(
                        alpha: (0.16 + (glassOpacity * 0.50)).clamp(0.0, 1.0),
                      ),
                      glassBottomTint.withValues(
                        alpha: (0.10 + (glassOpacity * 0.36)).clamp(0.0, 1.0),
                      ),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: 0.18 + (glassOpacity * 0.36) + (blurFactor * 0.08),
                    ),
                    width: 1.0 + (frameStrength * 1.1),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: 0.35 + (frameStrength * 0.35),
                      ),
                      blurRadius: 30 + (frameStrength * 28),
                      spreadRadius: frameStrength * 0.8,
                      offset: Offset(0, 14 + (frameStrength * 14)),
                    ),
                    BoxShadow(
                      color: const Color(0x66B4E4FF)
                          .withValues(alpha: 0.04 + (blurFactor * 0.12)),
                      blurRadius: 24 + (blurSigma * 0.9),
                      spreadRadius: blurFactor * 0.4,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    _WindowTopBar(
                      isMaximized: isMaximized,
                      frameStrength: frameStrength,
                      glassOpacity: glassOpacity,
                      onMinimize: onMinimize,
                      onToggleMaximize: onToggleMaximize,
                      onClose: onClose,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(22),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 900;
                            if (compact) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _LeftPanel(
                                    glassOpacity: glassOpacity,
                                    blurSigma: blurSigma,
                                    onOpacityChanged: onOpacityChanged,
                                    onBlurChanged: onBlurChanged,
                                  ),
                                  const SizedBox(height: 18),
                                  const _RightPanel(),
                                ],
                              );
                            }

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: _LeftPanel(
                                    glassOpacity: glassOpacity,
                                    blurSigma: blurSigma,
                                    onOpacityChanged: onOpacityChanged,
                                    onBlurChanged: onBlurChanged,
                                  ),
                                ),
                                const SizedBox(width: 18),
                                const Expanded(flex: 4, child: _RightPanel()),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            top: 10,
            height: 120,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: RadialGradient(
                    center: const Alignment(-0.35, -1.2),
                    radius: 1.55,
                    colors: [
                      Colors.white.withValues(
                        alpha: 0.10 + (blurFactor * 0.16),
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowTopBar extends StatelessWidget {
  const _WindowTopBar({
    required this.isMaximized,
    required this.frameStrength,
    required this.glassOpacity,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  final bool isMaximized;
  final double frameStrength;
  final double glassOpacity;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final dragRegion = Row(
      children: [
        const SizedBox(width: 16),
        Text(
          'Cozy Workspace',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFFEDEFF7),
                fontWeight: FontWeight.w600,
              ),
        ),
        const Spacer(),
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0x1EFFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x22FFFFFF)),
          ),
          child: const Row(
            children: [
              Icon(Icons.folder_open_rounded, size: 16, color: Color(0xD7FFFFFF)),
              SizedBox(width: 8),
              Text(
                'Project / Cozy UI',
                style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 12.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 140,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0x24FFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x24FFFFFF)),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_rounded, size: 18, color: Color(0xCCFFFFFF)),
              SizedBox(width: 8),
              Text(
                'Search',
                style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.15 + (frameStrength * 0.22)),
          ),
        ),
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.07 + (glassOpacity * 0.22)),
            Colors.white.withValues(alpha: 0.02 + (glassOpacity * 0.08)),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: [
          const _WindowDot(color: Color(0xFFF9736A), icon: Icons.close_rounded),
          const SizedBox(width: 9),
          const _WindowDot(
            color: Color(0xFFFCCB58),
            icon: Icons.minimize_rounded,
          ),
          const SizedBox(width: 9),
          const _WindowDot(
            color: Color(0xFF49D18E),
            icon: Icons.crop_square_rounded,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _isDesktop ? DragToMoveArea(child: dragRegion) : dragRegion,
          ),
          const SizedBox(width: 12),
          _WindowActionButton(
            icon: Icons.minimize_rounded,
            intensity: frameStrength,
            onPressed: onMinimize,
          ),
          const SizedBox(width: 8),
          _WindowActionButton(
            icon: isMaximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            intensity: frameStrength,
            onPressed: onToggleMaximize,
          ),
          const SizedBox(width: 8),
          _WindowActionButton(
            icon: Icons.close_rounded,
            intensity: frameStrength,
            onPressed: onClose,
            isClose: true,
          ),
        ],
      ),
    );
  }
}

class _LeftPanel extends StatelessWidget {
  const _LeftPanel({
    required this.glassOpacity,
    required this.blurSigma,
    required this.onOpacityChanged,
    required this.onBlurChanged,
  });

  final double glassOpacity;
  final double blurSigma;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<double> onBlurChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0x18FFFFFF),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0x2DFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Warm. Calm. Focused.',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: const Color(0xFFF6F7FB),
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            'Frameless window with custom top bar and adjustable glass intensity.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: const Color(0xCCFFFFFF),
                  height: 1.45,
                ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('Launch'),
                style: ElevatedButton.styleFrom(
                  foregroundColor: const Color(0xFF25161D),
                  backgroundColor: const Color(0xFFFAB07E),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () {},
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xE6FFFFFF),
                  side: const BorderSide(color: Color(0x55FFFFFF)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text('Preview'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _GlassSliderCard(
            opacityValue: glassOpacity,
            blurValue: blurSigma,
            onOpacityChanged: onOpacityChanged,
            onBlurChanged: onBlurChanged,
          ),
        ],
      ),
    );
  }
}

class _GlassSliderCard extends StatelessWidget {
  const _GlassSliderCard({
    required this.opacityValue,
    required this.blurValue,
    required this.onOpacityChanged,
    required this.onBlurChanged,
  });

  final double opacityValue;
  final double blurValue;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<double> onBlurChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0x20FFFFFF),
        border: Border.all(color: const Color(0x24FFFFFF)),
      ),
      child: Column(
        children: [
          _SliderRow(
            label: 'Window Opacity',
            valueText: '${(opacityValue * 100).round()}%',
            min: 0.18,
            max: 1.0,
            value: opacityValue,
            onChanged: onOpacityChanged,
          ),
          const SizedBox(height: 10),
          _SliderRow(
            label: 'Liquid Blur',
            valueText: blurValue.toStringAsFixed(0),
            min: 8,
            max: 48,
            value: blurValue,
            onChanged: onBlurChanged,
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueText,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double min;
  final double max;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xE9FFFFFF),
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              valueText,
              style: const TextStyle(color: Color(0xCCFFFFFF)),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFFFAB07E),
            inactiveTrackColor: const Color(0x44FFFFFF),
            thumbColor: const Color(0xFFFFD6B2),
            overlayColor: const Color(0x33FAB07E),
          ),
          child: Slider(
            min: min,
            max: max,
            value: value,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _RightPanel extends StatelessWidget {
  const _RightPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0x2DFFFFFF)),
      ),
      child: const Column(
        children: [
          _StatTile(
            icon: Icons.palette_rounded,
            title: 'Glassy Depth',
            subtitle: 'Opacity slider pushes more or less frosted depth',
            accent: Color(0xFFFF9A72),
          ),
          SizedBox(height: 12),
          _StatTile(
            icon: Icons.blur_on_rounded,
            title: 'Blur Control',
            subtitle: 'Tune strong or subtle blur without changing structure',
            accent: Color(0xFFFFD66E),
          ),
          SizedBox(height: 12),
          _StatTile(
            icon: Icons.window_rounded,
            title: 'Custom Frame',
            subtitle: 'Frameless window now uses your custom control buttons',
            accent: Color(0xFF7CCBFF),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0x20FFFFFF),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      child: Row(
        children: [
          Container(
            height: 40,
            width: 40,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFF3F4F8),
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xC7FFFFFF),
                    fontSize: 12.6,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowDot extends StatelessWidget {
  const _WindowDot({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            spreadRadius: 0.5,
          ),
        ],
      ),
      child: Icon(icon, size: 10, color: Colors.black.withValues(alpha: 0.5)),
    );
  }
}

class _WindowActionButton extends StatelessWidget {
  const _WindowActionButton({
    required this.icon,
    required this.onPressed,
    required this.intensity,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double intensity;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          backgroundColor:
              isClose
                  ? const Color(0x30F9736A)
                      .withValues(alpha: 0.20 + (intensity * 0.30))
                  : Colors.white.withValues(alpha: 0.11 + (intensity * 0.19)),
          foregroundColor:
              isClose ? const Color(0xFFFAC2BD) : const Color(0xE6FFFFFF),
          side: BorderSide(
            color: isClose
                ? const Color(0x45F9736A)
                    .withValues(alpha: 0.30 + (intensity * 0.35))
                : Colors.white.withValues(alpha: 0.14 + (intensity * 0.24)),
          ),
        ),
        icon: Icon(icon, size: 14),
      ),
    );
  }
}

class _SoftBlob extends StatelessWidget {
  const _SoftBlob({
    required this.alignment,
    required this.size,
    required this.color,
  });

  final Alignment alignment;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, Colors.transparent],
            ),
          ),
        ),
      ),
    );
  }
}
