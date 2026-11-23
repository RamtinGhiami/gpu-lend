import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'engine.dart';

/// Looks for a newer release on GitHub. On Windows a newer installer whose SHA-256 matches the one GitHub lists for the file runs
/// silently and replaces this app, which then starts again. On Linux and macOS the app only tells you that a new version exists.
class Updater {
  Updater(this.engine, {this.repo = 'RamtinGhiami/gpu-lend'});
  final Engine engine;
  final String repo;
  Timer? _timer;
  bool _busy = false;
  String _told = '';

  void start() {
    _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
    Timer(const Duration(minutes: 2), check);
  }

  void stop() => _timer?.cancel();

  static bool newer(String remote, String local) {
    List<int> parts(String v) => v.split('.').map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
    final a = parts(remote), b = parts(local);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await http.get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'), headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final tag = ((j['tag_name'] ?? '') as String).replaceFirst(RegExp('^v'), '');
      if (tag.isEmpty || !newer(tag, engine.version)) return;
      final page = (j['html_url'] ?? 'https://github.com/$repo/releases/latest') as String;
      final assets = ((j['assets'] ?? const <dynamic>[]) as List).whereType<Map<String, dynamic>>().toList();
      final setup = assets.where((a) {
        final name = (a['name'] ?? '') as String;
        return name.contains('Setup') && name.endsWith('.exe');
      }).firstOrNull;
      final digest = ((setup?['digest'] ?? '') as String).replaceFirst('sha256:', '').toLowerCase();
      if (!Platform.isWindows || setup == null || digest.length != 64) {
        if (_told != tag) {
          _told = tag;
          engine.notice = 'GPU Lend $tag is available: $page';
          engine.refresh();
        }
        return;
      }
      engine.log('update $tag found, downloading');
      final data = await http.get(Uri.parse(setup['browser_download_url'] as String)).timeout(const Duration(minutes: 5));
      if (data.statusCode != 200) return;
      if (sha256.convert(data.bodyBytes).toString() != digest) {
        engine.log('update $tag rejected: hash mismatch');
        return;
      }
      final file = File('${Directory.systemTemp.path}\\GpuLend-Setup-$tag.exe');
      await file.writeAsBytes(data.bodyBytes);
      engine.log('installing update $tag');
      await Process.start(file.path, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'], mode: ProcessStartMode.detached);
    } catch (e) {
      engine.log('update check failed: $e');
    } finally {
      _busy = false;
    }
  }
}
