import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pty/pty.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xterm/xterm.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setAsFrameless();
    const options = WindowOptions(
      size: Size(1200, 760),
      minimumSize: Size(900, 560),
      center: true,
      backgroundColor: Colors.transparent,
      title: 'zet-ssh terminal',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ZetSshApp());
}

const _desktopPlatforms = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
};

bool get _isDesktop =>
    !kIsWeb && _desktopPlatforms.contains(defaultTargetPlatform);

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

class _TerminalSession {
  _TerminalSession({
    required this.label,
    required this.terminal,
    required this.controller,
    required this.pty,
    required this.outputSub,
  });

  final String label;
  final Terminal terminal;
  final TerminalController controller;
  final PseudoTerminal pty;
  final StreamSubscription<String> outputSub;

  Future<void> dispose() async {
    await outputSub.cancel();
    pty.kill();
    controller.dispose();
  }
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  static const bool _debugFromDartDefine =
      bool.fromEnvironment('ZET_SSH_DEBUG_KEYS');

  static bool get _debugEnabled {
    if (_debugFromDartDefine) return true;
    final env = Platform.environment['ZET_SSH_DEBUG_KEYS'];
    return env == '1' || env?.toLowerCase() == 'true';
  }

  final List<_TerminalSession> _sessions = [];
  int _activeIndex = 0;
  bool _bootFailed = false;
  int _sessionCounter = 0;

  void _debug(String message) {
    if (_debugEnabled) {
      // ignore: avoid_print
      print('[zet-ssh] $message');
    }
  }

  _TerminalSession? get _activeSession {
    if (_sessions.isEmpty) return null;
    if (_activeIndex < 0 || _activeIndex >= _sessions.length) return null;
    return _sessions[_activeIndex];
  }

  @override
  void initState() {
    super.initState();
    _createSession(workingDirectory: Directory.current.path, activate: true);
  }

  String _resolveShell() {
    if (Platform.isWindows) {
      return 'powershell.exe';
    }

    return Platform.environment['SHELL'] ?? '/bin/bash';
  }

  List<String> _shellArgsFor(String shellPath) {
    final shellName = shellPath.split('/').last.toLowerCase();
    if (shellName.contains('bash') ||
        shellName.contains('zsh') ||
        shellName.contains('fish')) {
      return const ['-i'];
    }
    return const [];
  }

  void _createSession({
    required String workingDirectory,
    required bool activate,
  }) {
    try {
      final shell = _resolveShell();
      final shellArgs = _shellArgsFor(shell);
      final shellName = shell.split('/').last.toLowerCase();
      final filterLinuxBashNoise = Platform.isLinux && shellName.contains('bash');

      _debug('starting shell=$shell args=$shellArgs cwd=$workingDirectory');

      final terminal = Terminal(maxLines: 20000);
      final controller = TerminalController();
      final pty = PseudoTerminal.start(
        shell,
        shellArgs,
        workingDirectory: workingDirectory,
        environment: {
          ...Platform.environment,
          'TERM': 'xterm-256color',
          'COLORTERM': 'truecolor',
        },
      );

      final outputSub = pty.out.listen((raw) {
        var data = raw;
        if (filterLinuxBashNoise) {
          data = data
              .replaceAll(
                RegExp(
                  r'bash: cannot set terminal process group \(\d+\): Inappropriate ioctl for device\r?\n?',
                ),
                '',
              )
              .replaceAll('bash: no job control in this shell\r\n', '')
              .replaceAll('bash: no job control in this shell\n', '');
        }
        terminal.write(data);
      });

      terminal.onOutput = (data) {
        _debug('terminal->pty bytes=${data.codeUnits}');
        pty.write(data);
      };

      terminal.onResize = (width, height, _, _) {
        pty.resize(width, height);
      };

      final session = _TerminalSession(
        label: 'term ${++_sessionCounter}',
        terminal: terminal,
        controller: controller,
        pty: pty,
        outputSub: outputSub,
      );

      setState(() {
        _sessions.add(session);
        if (activate) {
          _activeIndex = _sessions.length - 1;
        }
        _bootFailed = false;
      });
    } catch (_) {
      if (_sessions.isEmpty) {
        setState(() => _bootFailed = true);
      }
    }
  }

  Future<String> _resolveWorkingDirectoryForNewSession() async {
    final session = _activeSession;
    if (session == null) return Directory.current.path;

    if (Platform.isLinux) {
      final pid = session.pty.pid;
      if (pid != null) {
        final procCwd = Link('/proc/$pid/cwd');
        if (await procCwd.exists()) {
          try {
            return await procCwd.resolveSymbolicLinks();
          } catch (_) {
            return Directory.current.path;
          }
        }
      }
    }

    return Directory.current.path;
  }

  Future<void> _openNewTerminalFromActiveDir() async {
    final cwd = await _resolveWorkingDirectoryForNewSession();
    _createSession(workingDirectory: cwd, activate: true);
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      session.outputSub.cancel();
      session.pty.kill();
      session.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _copySelection() async {
    final session = _activeSession;
    if (session == null) return;

    final selection = session.controller.selection;
    if (selection == null) return;
    final text = session.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _pasteClipboard() async {
    final session = _activeSession;
    if (session == null) return;

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    session.terminal.paste(text);
    session.controller.clearSelection();
  }

  Future<void> _showContextMenu(Offset globalPosition) async {
    final session = _activeSession;
    if (session == null) return;

    final selection = session.controller.selection;
    final copied = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      color: const Color(0xFF0F1A2E),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: selection != null,
          child: const Text('Copy'),
        ),
        const PopupMenuItem(
          value: 'paste',
          child: Text('Paste'),
        ),
      ],
    );

    if (copied == 'copy') {
      await _copySelection();
    } else if (copied == 'paste') {
      await _pasteClipboard();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bootFailed) {
      return const Scaffold(
        body: Center(child: Text('Failed to start shell process.')),
      );
    }

    final session = _activeSession;

    final content = Scaffold(
      backgroundColor: Colors.transparent,
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
            padding: EdgeInsets.zero,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_isDesktop ? 0 : 18),
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
                    _TopBar(
                      onMinimize: _isDesktop ? windowManager.minimize : null,
                      onToggleMaximize: _isDesktop
                          ? () async {
                              if (await windowManager.isMaximized()) {
                                await windowManager.unmaximize();
                              } else {
                                await windowManager.maximize();
                              }
                            }
                          : null,
                      onClose: _isDesktop ? windowManager.close : null,
                    ),
                    _SessionTabs(
                      sessions: _sessions,
                      activeIndex: _activeIndex,
                      onSelect: (index) {
                        setState(() => _activeIndex = index);
                      },
                    ),
                    Expanded(
                      child: session == null
                          ? const Center(child: CircularProgressIndicator())
                          : TerminalView(
                              session.terminal,
                              controller: session.controller,
                              backgroundOpacity: 0,
                              autofocus: true,
                              padding: const EdgeInsets.all(14),
                              shortcuts: const {
                                SingleActivator(
                                  LogicalKeyboardKey.keyC,
                                  control: true,
                                  shift: true,
                                ): CopySelectionTextIntent.copy,
                                SingleActivator(
                                  LogicalKeyboardKey.keyV,
                                  control: true,
                                  shift: true,
                                ): PasteTextIntent(
                                  SelectionChangedCause.keyboard,
                                ),
                                SingleActivator(
                                  LogicalKeyboardKey.keyA,
                                  control: true,
                                ): SelectAllTextIntent(
                                  SelectionChangedCause.keyboard,
                                ),
                              },
                              onSecondaryTapDown: (details, _) {
                                _showContextMenu(details.globalPosition);
                              },
                              onKeyEvent: (_, event) {
                                final keys =
                                    HardwareKeyboard.instance.logicalKeysPressed;
                                final ctrlPressed =
                                    keys.contains(LogicalKeyboardKey.controlLeft) ||
                                        keys.contains(
                                          LogicalKeyboardKey.controlRight,
                                        );
                                final shiftPressed =
                                    keys.contains(LogicalKeyboardKey.shiftLeft) ||
                                        keys.contains(
                                          LogicalKeyboardKey.shiftRight,
                                        );

                                if (event is KeyDownEvent &&
                                    ctrlPressed &&
                                    shiftPressed &&
                                    event.logicalKey == LogicalKeyboardKey.keyN) {
                                  _openNewTerminalFromActiveDir();
                                  return KeyEventResult.handled;
                                }

                                final isCopyChordKey =
                                    event.logicalKey == LogicalKeyboardKey.keyC ||
                                        event.logicalKey ==
                                            LogicalKeyboardKey.copy;

                                if (event is KeyDownEvent &&
                                    ctrlPressed &&
                                    !shiftPressed &&
                                    isCopyChordKey) {
                                  session.pty.write('\x03');
                                  return KeyEventResult.handled;
                                }

                                if (event is KeyDownEvent && _debugEnabled) {
                                  _debug(
                                    'keyDown key=${event.logicalKey.keyLabel} '
                                    'logical=${event.logicalKey.debugName} '
                                    'ctrl=$ctrlPressed shift=$shiftPressed',
                                  );
                                }
                                return KeyEventResult.ignored;
                              },
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

    if (_isDesktop) {
      return DragToResizeArea(child: content);
    }

    return content;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    this.onMinimize,
    this.onToggleMaximize,
    this.onClose,
  });

  final Future<void> Function()? onMinimize;
  final Future<void> Function()? onToggleMaximize;
  final Future<void> Function()? onClose;

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF1B2B45))),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF121C31), Color(0xFF0C1425)],
          ),
        ),
        child: Row(
          children: [
            _Dot(color: const Color(0xFFFFC75F), onTap: onMinimize),
            const SizedBox(width: 8),
            _Dot(color: const Color(0xFF47E6A1), onTap: onToggleMaximize),
            const SizedBox(width: 8),
            _Dot(color: const Color(0xFFFF6B6B), onTap: onClose),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'zet-ssh terminal',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFA8B4CF),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 56),
          ],
        ),
      ),
    );
  }
}

class _SessionTabs extends StatelessWidget {
  const _SessionTabs({
    required this.sessions,
    required this.activeIndex,
    required this.onSelect,
  });

  final List<_TerminalSession> sessions;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1B2B45))),
        color: Color(0x220A1322),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: sessions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final active = index == activeIndex;
          return GestureDetector(
            onTap: () => onSelect(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: active ? const Color(0xFF163153) : const Color(0xFF0B1527),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: active
                      ? const Color(0xFF3E86D5)
                      : const Color(0xFF1F3350),
                ),
              ),
              child: Text(
                sessions[index].label,
                style: TextStyle(
                  color:
                      active ? const Color(0xFFE8F1FF) : const Color(0xFF9FB1CC),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.color,
    this.onTap,
  });

  final Color color;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                onTap!.call();
              },
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6),
            ],
          ),
        ),
      ),
    );
  }
}
