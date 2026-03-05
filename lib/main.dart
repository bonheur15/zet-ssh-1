import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pty/pty.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xterm/xterm.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final launchConfig = LaunchConfig.fromArgs(args);

  if (_isDesktop && !launchConfig.isSubWindow) {
    await windowManager.ensureInitialized();
    await windowManager.setAsFrameless();
    final forceStartupFocus = launchConfig.forceStartupFocus;
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

  runApp(ZetSshApp(launchConfig: launchConfig));
}

const _desktopPlatforms = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
};

bool get _isDesktop =>
    !kIsWeb && _desktopPlatforms.contains(defaultTargetPlatform);

class ZetSshApp extends StatelessWidget {
  const ZetSshApp({
    required this.launchConfig,
    super.key,
  });

  final LaunchConfig launchConfig;

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
      home: TerminalPage(launchConfig: launchConfig),
    );
  }
}

class LaunchConfig {
  const LaunchConfig({
    required this.initialWorkingDirectory,
    required this.forceStartupFocus,
    required this.isSubWindow,
    required this.windowId,
  });

  final String initialWorkingDirectory;
  final bool forceStartupFocus;
  final bool isSubWindow;
  final int windowId;

  static LaunchConfig fromArgs(List<String> args) {
    var cwd = Directory.current.path;
    var focus = false;
    var isSubWindow = false;
    var windowId = 0;

    if (args.length >= 3 && args[0] == 'multi_window') {
      isSubWindow = true;
      windowId = int.tryParse(args[1]) ?? 0;
      try {
        final raw = args[2];
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final argCwd = decoded['cwd'];
          final argFocus = decoded['focus'];
          if (argCwd is String && argCwd.isNotEmpty) {
            cwd = argCwd;
          }
          if (argFocus is bool) {
            focus = argFocus;
          }
        }
      } catch (_) {
        // ignore malformed window arguments
      }
    }

    return LaunchConfig(
      initialWorkingDirectory: cwd,
      forceStartupFocus: focus,
      isSubWindow: isSubWindow,
      windowId: windowId,
    );
  }
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    required this.launchConfig,
    super.key,
  });

  final LaunchConfig launchConfig;

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

  void _debug(String message) {
    if (_debugKeys) {
      // ignore: avoid_print
      print('[zet-ssh] $message');
    }
  }

  bool get _useWindowManager => _isDesktop && !widget.launchConfig.isSubWindow;

  @override
  void initState() {
    super.initState();

    _terminal = Terminal(
      maxLines: 20000,
    );
    _terminalController = TerminalController();
    DesktopMultiWindow.setMethodHandler((call, _) async {
      if (call.method == 'focus_window') {
        await _focusThisWindow();
      }
      return null;
    });

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
      _debug(
        'starting shell=$shell args=$shellArgs cwd=${widget.launchConfig.initialWorkingDirectory}',
      );

      final pty = PseudoTerminal.start(
        shell,
        shellArgs,
        workingDirectory: widget.launchConfig.initialWorkingDirectory,
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
    DesktopMultiWindow.setMethodHandler(null);
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

    return widget.launchConfig.initialWorkingDirectory;
  }

  Future<void> _openNewTerminalWindow() async {
    final cwd = await _resolveActiveWorkingDirectory();

    try {
      final controller = await DesktopMultiWindow.createWindow(
        jsonEncode(<String, dynamic>{
          'cwd': cwd,
          'focus': true,
        }),
      );
      await controller.setFrame(const Rect.fromLTWH(120, 120, 1200, 760));
      await controller.center();
      await controller.show();

      unawaited(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration(milliseconds: 120 * (i + 1)));
          await DesktopMultiWindow.invokeMethod(
            controller.windowId,
            'focus_window',
          );
        }
      }());

      if (_debugKeys) {
        _debug('spawned multi-window id=${controller.windowId} cwd=$cwd');
      }
    } catch (_) {
      // no-op: keep terminal stable even if spawning fails
    }
  }

  Future<void> _focusThisWindow() async {
    if (!_useWindowManager) {
      if (widget.launchConfig.windowId > 0) {
        await WindowController.fromWindowId(widget.launchConfig.windowId).show();
      }
      return;
    }

    for (var i = 0; i < 4; i++) {
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      await windowManager.setAlwaysOnTop(false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await windowManager.focus();
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
                      draggable: _useWindowManager,
                      onMinimize: _useWindowManager
                          ? () {
                              unawaited(windowManager.minimize());
                            }
                          : null,
                      onToggleMaximize: _useWindowManager
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
                      onClose: () {
                        unawaited(() async {
                          if (_useWindowManager) {
                            await windowManager.close();
                          } else if (widget.launchConfig.windowId > 0) {
                            await WindowController.fromWindowId(
                              widget.launchConfig.windowId,
                            ).close();
                          }
                        }());
                      },
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < 80 ||
                              constraints.maxHeight < 80) {
                            return const SizedBox.expand();
                          }
                          return TerminalView(
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
                          );
                        },
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

    if (_useWindowManager) {
      return DragToResizeArea(child: content);
    }

    return content;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.draggable,
    this.onMinimize,
    this.onToggleMaximize,
    this.onClose,
  });

  final bool draggable;
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
          if (draggable)
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
