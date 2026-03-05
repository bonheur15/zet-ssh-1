import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pty/pty.dart';
import 'package:xterm/xterm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZetSshApp());
}

class ZetSshApp extends StatelessWidget {
  const ZetSshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'zet-ssh terminal',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF06080F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF47E6A1),
          surface: Color(0xFF0B101D),
        ),
      ),
      home: const TerminalPage(),
    );
  }
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late final Terminal _terminal;
  PseudoTerminal? _pty;
  StreamSubscription<String>? _outputSub;
  bool _bootFailed = false;

  @override
  void initState() {
    super.initState();

    _terminal = Terminal(
      maxLines: 20000,
    );

    _startShell();
  }

  String _resolveShell() {
    if (Platform.isWindows) {
      return 'powershell.exe';
    }

    return Platform.environment['SHELL'] ?? '/bin/bash';
  }

  void _startShell() {
    try {
      final shell = _resolveShell();
      final pty = PseudoTerminal.start(
        shell,
        const [],
      );

      _pty = pty;

      _outputSub = pty.out.listen((data) {
        _terminal.write(data);
      });

      _terminal.onOutput = (data) {
        pty.write(data);
      };

      _terminal.onResize = (width, height, _, _) {
        pty.resize(width, height);
      };
    } catch (_) {
      setState(() => _bootFailed = true);
    }
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _pty?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_bootFailed) {
      return const Scaffold(
        body: Center(
          child: Text('Failed to start shell process.'),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A1120), Color(0xFF05070D), Color(0xFF09162A)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF1B2B45)),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF0E1728), Color(0xFF090F1B)],
                  ),
                ),
                child: Column(
                  children: [
                    const _TopBar(),
                    Expanded(
                      child: TerminalView(
                        _terminal,
                        backgroundOpacity: 0,
                        autofocus: true,
                        padding: const EdgeInsets.all(14),
                        theme: const TerminalTheme(
                          cursor: Color(0xFF47E6A1),
                          selection: Color(0x553C7EEA),
                          foreground: Color(0xFFD7E1F8),
                          background: Color(0x00000000),
                          black: Color(0xFF0D121D),
                          red: Color(0xFFFF607A),
                          green: Color(0xFF47E6A1),
                          yellow: Color(0xFFFFD166),
                          blue: Color(0xFF5EA5FF),
                          magenta: Color(0xFFDD7CFF),
                          cyan: Color(0xFF65E9FF),
                          white: Color(0xFFE9EEFF),
                          brightBlack: Color(0xFF55637D),
                          brightRed: Color(0xFFFF8499),
                          brightGreen: Color(0xFF78F2BE),
                          brightYellow: Color(0xFFFFE08F),
                          brightBlue: Color(0xFF8ABEFF),
                          brightMagenta: Color(0xFFE7A0FF),
                          brightCyan: Color(0xFF9EF2FF),
                          brightWhite: Color(0xFFFFFFFF),
                          searchHitBackground: Color(0xFF3C7EEA),
                          searchHitBackgroundCurrent: Color(0xFF47E6A1),
                          searchHitForeground: Color(0xFF08111F),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1B2B45))),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF121C31), Color(0xFF0C1425)],
        ),
      ),
      child: const Row(
        children: [
          _Dot(color: Color(0xFFFF6B6B)),
          SizedBox(width: 8),
          _Dot(color: Color(0xFFFFC75F)),
          SizedBox(width: 8),
          _Dot(color: Color(0xFF47E6A1)),
          Spacer(),
          Text(
            'zet-ssh terminal',
            style: TextStyle(
              color: Color(0xFFA8B4CF),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          Spacer(),
          SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6)],
      ),
    );
  }
}
