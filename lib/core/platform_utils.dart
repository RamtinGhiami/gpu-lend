// The few things that differ between Windows, Linux and macOS: where the data lives, how the device token is kept, whether the
// computer is on battery, how a file or folder is opened, and what a program is called.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'windows_api.dart';

String homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;

/// Folder for the settings, the logs and (by default) the model program and weights.
Directory appDataDir() {
  final override = Platform.environment['GPULEND_DATA']; // for tests and portable use
  if (override != null && override.isNotEmpty) return Directory(override);
  if (Platform.isWindows) return Directory('${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}\\GpuLend');
  if (Platform.isMacOS) return Directory('${homeDir()}/Library/Application Support/GpuLend');
  return Directory('${Platform.environment['XDG_DATA_HOME'] ?? '${homeDir()}/.local/share'}/GpuLend');
}

/// Windows keeps secrets encrypted with DPAPI (this Windows user only). Linux and macOS have no such call without extra libraries,
/// so there the secret sits in the settings file, which is made readable by the current user only.
String? protectSecret(String text) => Platform.isWindows ? WindowsApi.protect(text) : 'plain:${base64.encode(utf8.encode(text))}';

String? unprotectSecret(String stored) {
  if (stored.startsWith('plain:')) return utf8.decode(base64.decode(stored.substring(6)));
  return Platform.isWindows ? WindowsApi.unprotect(stored) : null;
}

Future<void> restrictToOwner(File file) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', ['600', file.path]);
  } catch (_) {}
}

/// `sd-server` on Linux and macOS, `sd-server.exe` on Windows.
String exeName(String base) => Platform.isWindows ? '$base.exe' : base;

String computerName() => Platform.environment['COMPUTERNAME'] ?? Platform.localHostname;

Future<void> openFolder(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', [path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

Future<void> openFile(String path) async {
  if (Platform.isWindows) {
    await Process.run('notepad.exe', [path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-t', path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

Future<void> openUrl(String url) async {
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else {
    await Process.run('xdg-open', [url]);
  }
}

/// The tray icon file inside the installed app (an .ico on Windows, a PNG elsewhere).
String trayIconPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) return [exeDir, 'data', 'flutter_assets', 'assets', 'tray_icon.ico'].join(sep);
  if (Platform.isMacOS) return '$exeDir/../Frameworks/App.framework/Resources/flutter_assets/assets/icon.png';
  return [exeDir, 'data', 'flutter_assets', 'assets', 'icon.png'].join(sep);
}

/// Is this computer running on battery? Windows is answered at once; Linux and macOS are asked every 30 seconds in the background.
class PowerStatus {
  static bool _onBattery = false;
  static Timer? _timer;

  static bool get onBattery => Platform.isWindows ? WindowsApi.onBattery() : _onBattery;

  static void start() {
    if (Platform.isWindows || _timer != null) return;
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> _refresh() async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('pmset', ['-g', 'batt']);
        _onBattery = '${r.stdout}'.contains('Battery Power');
      } else if (Platform.isLinux) {
        var onMains = false, hasBattery = false;
        for (final e in Directory('/sys/class/power_supply').listSync()) {
          final type = File('${e.path}/type');
          if (!type.existsSync()) continue;
          final t = type.readAsStringSync().trim();
          if (t == 'Mains') {
            final online = File('${e.path}/online');
            if (online.existsSync() && online.readAsStringSync().trim() == '1') onMains = true;
          } else if (t == 'Battery') {
            hasBattery = true;
          }
        }
        _onBattery = hasBattery && !onMains;
      }
    } catch (_) {
      _onBattery = false;
    }
  }
}
