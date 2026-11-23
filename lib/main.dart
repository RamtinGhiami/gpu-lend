import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/engine.dart';
import 'core/platform_utils.dart';
import 'core/updater.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

const appVersion = '2.0.0';
const _instancePort = 47831;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // one copy only: a second start asks the first one to show its window
  ServerSocket? lock;
  try {
    lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, _instancePort);
  } on SocketException {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort, timeout: const Duration(seconds: 2));
      s.write('show');
      await s.flush();
      await s.close();
    } catch (_) {}
    exit(0);
  }

  final minimized = args.contains('--minimized');
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(460, 690),
    minimumSize: Size(460, 690),
    maximumSize: Size(460, 690),
    center: true,
    title: 'GPU Lend',
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Palette.background,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setPreventClose(true);
    // a fixed size: no resizing, no maximize
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    if (!minimized) {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  LaunchAtStartup.instance.setup(appName: 'GpuLend', appPath: Platform.resolvedExecutable, args: const ['--minimized'], packageName: 'com.gpulend.gpuLend');
  final engine = Engine(
    version: appVersion,
    onAutostart: (on) async {
      if (on) {
        await LaunchAtStartup.instance.enable();
      } else {
        await LaunchAtStartup.instance.disable();
      }
    },
  );
  await engine.start();
  final host = _TrayHost(engine);
  await host.init();
  lock.listen((client) {
    client.listen((_) => host.showWindow());
  });

  // a painting error must leave a trace: the log says what failed instead of a white window
  FlutterError.onError = (details) => engine.log('ui error: ${details.exceptionAsString()}');
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    engine.log('error: $error');
    return true;
  };

  Updater(engine).start();
  runApp(GpuLendApp(engine: engine));
}

class GpuLendApp extends StatelessWidget {
  const GpuLendApp({super.key, required this.engine});
  final Engine engine;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GPU Lend',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: Shell(engine: engine),
      );
}

/// The tray icon and the window's close button: closing hides the window, the tray menu quits for real.
class _TrayHost with TrayListener, WindowListener {
  _TrayHost(this.engine);
  final Engine engine;

  Future<void> init() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    final icon = trayIconPath();
    if (File(icon).existsSync()) await trayManager.setIcon(icon);
    await trayManager.setToolTip('GPU Lend');
    await _menu();
    engine.addListener(_menu);
  }

  Future<void> _menu() async {
    final lending = engine.config.localEnabled;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open GPU Lend'),
      MenuItem.separator(),
      MenuItem(key: 'toggle', label: lending ? 'Pause lending' : 'Resume lending', disabled: !engine.config.paired),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit (stops the model)'),
    ]));
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    // a window shown after hours in the tray can come back blank: ask for a frame, then nudge the size to rebuild the surface
    WidgetsBinding.instance.scheduleForcedFrame();
    final size = await windowManager.getSize();
    await windowManager.setSize(Size(size.width + 1, size.height));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await windowManager.setSize(size);
    WidgetsBinding.instance.scheduleForcedFrame();
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'open':
        await showWindow();
      case 'toggle':
        await engine.setLocalEnabled(!engine.config.localEnabled);
      case 'quit':
        await engine.shutdown();
        await trayManager.destroy();
        exit(0);
    }
  }

  @override
  void onWindowClose() async {
    // the window is only hidden: the app keeps lending from the tray
    await windowManager.hide();
  }
}
