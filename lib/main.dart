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
    final forceStartupFocus =
        Platform.environment['ZET_SSH_FORCE_FOCUS'] == '1';
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
      if (forceStartupFocus) {
        // Retry focus in short bursts to improve foreground behavior on Wayland WMs.
        for (var i = 0; i < 4; i++) {
          await windowManager.setAlwaysOnTop(true);
          await windowManager.focus();
          await Future<void>.delayed(const Duration(milliseconds: 90));
          await windowManager.setAlwaysOnTop(false);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await windowManager.focus();
      }
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

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  static const bool _debugFromDartDefine =
      bool.fromEnvironment('ZET_SSH_DEBUG_KEYS');

  static bool get _debugKeys {
    if (_debugFromDartDefine) return true;
    final env = Platform.environment['ZET_SSH_DEBUG_KEYS'];
    return env == '1' || env?.toLowerCase() == 'true';
  }
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  PseudoTerminal? _pty;
  StreamSubscription<String>? _outputSub;
  bool _bootFailed = false;
  bool _filterLinuxBashNoise = false;
  String? _cachedExecutablePath;

  void _debug(String message) {
    if (_debugKeys) {
      // ignore: avoid_print
      print('[zet-ssh] $message');
    }
  }

  @override
  void initState() {
    super.initState();

    _terminal = Terminal(
      maxLines: 20000,
    );
    _terminalController = TerminalController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startShell();
      }
    });
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

  void _startShell() {
    try {
      final shell = _resolveShell();
      final shellArgs = _shellArgsFor(shell);
      final shellName = shell.split('/').last.toLowerCase();
      _filterLinuxBashNoise = Platform.isLinux && shellName.contains('bash');
      _debug('starting shell=$shell args=$shellArgs cwd=${Directory.current.path}');

      final pty = PseudoTerminal.start(
        shell,
        shellArgs,
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'TERM': 'xterm-256color',
          'COLORTERM': 'truecolor',
        },
      );

      _pty = pty;

      _outputSub = pty.out.listen((data) {
        if (_filterLinuxBashNoise) {
          data = data
              .replaceAll(
                RegExp(
                  r'bash: cannot set terminal process group \(\d+\): Inappropriate ioctl for device\r?\n?',
                ),
                '',
              )
              .replaceAll(
                'bash: no job control in this shell\r\n',
                '',
              )
              .replaceAll(
                'bash: no job control in this shell\n',
                '',
              );
        }
        _terminal.write(data);
      });

      _terminal.onOutput = (data) {
        _debug('terminal->pty bytes=${data.codeUnits}');
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
    _terminalController.dispose();
    super.dispose();
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _terminal.paste(text);
    _terminalController.clearSelection();
  }

  Future<void> _showContextMenu(Offset globalPosition) async {
    final selection = _terminalController.selection;
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

  Future<String> _resolveActiveWorkingDirectory() async {
    if (Platform.isLinux) {
      final pid = _pty?.pid;
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

  Future<void> _openNewTerminalWindow() async {
    final cwd = await _resolveActiveWorkingDirectory();

    try {
      final executablePath = await _resolveSelfExecutablePath();

      final child = await Process.start(
        executablePath,
        const [],
        workingDirectory: cwd,
        mode: ProcessStartMode.detached,
        environment: {
          'ZET_SSH_FORCE_FOCUS': '1',
        },
      );
      if (_debugKeys) {
        _debug('spawned direct pid=${child.pid} cwd=$cwd');
      }

      // KDE Wayland focus-stealing policy may keep the new window behind.
      // Minimizing current window after spawn gives foreground to the new one.
      if (_isKdeWaylandSession()) {
        unawaited(windowManager.minimize());
      }
    } catch (_) {
      // no-op: keep terminal stable even if spawning fails
    }
  }

  Future<String> _resolveSelfExecutablePath() async {
    final cached = _cachedExecutablePath;
    if (cached != null) return cached;

    var executablePath = Platform.resolvedExecutable;
    if (Platform.isLinux) {
      final selfExe = File('/proc/self/exe');
      if (await selfExe.exists()) {
        executablePath = await selfExe.resolveSymbolicLinks();
      }
    }

    _cachedExecutablePath = executablePath;
    return executablePath;
  }

  bool _isKdeWaylandSession() {
    if (!Platform.isLinux) return false;
    final desktop =
        (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
    final sessionType =
        (Platform.environment['XDG_SESSION_TYPE'] ?? '').toLowerCase();
    return desktop.contains('kde') && sessionType == 'wayland';
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
                      onMinimize: _isDesktop
                          ? () {
                              unawaited(windowManager.minimize());
                            }
                          : null,
                      onToggleMaximize: _isDesktop
                          ? () {
                              unawaited(() async {
                                if (await windowManager.isMaximized()) {
                                  await windowManager.unmaximize();
                                } else {
                                  await windowManager.maximize();
                                }
                              }());
                            }
                          : null,
                      onClose: _isDesktop
                          ? () {
                              unawaited(windowManager.close());
                            }
                          : null,
                    ),
                    Expanded(
                      child: TerminalView(
                        _terminal,
                        controller: _terminalController,
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
                          ): PasteTextIntent(SelectionChangedCause.keyboard),
                          SingleActivator(
                            LogicalKeyboardKey.keyA,
                            control: true,
                          ): SelectAllTextIntent(SelectionChangedCause.keyboard),
                        },
                        onSecondaryTapDown: (details, _) {
                          _showContextMenu(details.globalPosition);
                        },
                        onKeyEvent: (_, event) {
                          final keys =
                              HardwareKeyboard.instance.logicalKeysPressed;
                          final ctrlPressed =
                              keys.contains(LogicalKeyboardKey.controlLeft) ||
                                  keys.contains(LogicalKeyboardKey.controlRight);
                          final shiftPressed =
                              keys.contains(LogicalKeyboardKey.shiftLeft) ||
                                  keys.contains(LogicalKeyboardKey.shiftRight);
                          final isCopyChordKey =
                              event.logicalKey == LogicalKeyboardKey.keyC ||
                                  event.logicalKey == LogicalKeyboardKey.copy;

                          if (event is KeyDownEvent &&
                              ctrlPressed &&
                              shiftPressed &&
                              event.logicalKey == LogicalKeyboardKey.keyN) {
                            unawaited(_openNewTerminalWindow());
                            return KeyEventResult.handled;
                          }

                          if (event is KeyDownEvent &&
                              ctrlPressed &&
                              !shiftPressed &&
                              isCopyChordKey) {
                            _pty?.write('\x03');
                            return KeyEventResult.handled;
                          }
                          if (event is KeyDownEvent) {
                            _debug(
                              'keyDown key=${event.logicalKey.keyLabel} '
                              'logical=${event.logicalKey.debugName} ctrl=$ctrlPressed shift=$shiftPressed',
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

  final VoidCallback? onMinimize;
  final VoidCallback? onToggleMaximize;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
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
      child: Stack(
        children: [
          const Positioned.fill(
            child: DragToMoveArea(
              child: SizedBox.expand(),
            ),
          ),
          Positioned.fill(
            child: Row(
              children: [
                _Dot(color: const Color(0xFFFFC75F), onTap: onMinimize),
                const SizedBox(width: 8),
                _Dot(color: const Color(0xFF47E6A1), onTap: onToggleMaximize),
                const SizedBox(width: 8),
                _Dot(color: const Color(0xFFFF6B6B), onTap: onClose),
                const SizedBox(width: 12),
                const Expanded(
                  child: IgnorePointer(
                    child: Text(
                      'zet-ssh terminal',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFA8B4CF),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 56),
              ],
            ),
          ),
        ],
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTapDown: onTap == null ? null : (_) => onTap!(),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 14,
          height: 14,
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
