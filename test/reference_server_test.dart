// The app against the reference server in reference-server/server.py (needs Python 3; skipped when it is not found).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpu_lend/core/config_store.dart';
import 'package:gpu_lend/core/engine.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<String?> findPython() async {
  for (final name in Platform.isWindows ? ['python', 'py'] : ['python3', 'python']) {
    try {
      final r = await Process.run(name, ['--version']);
      if (r.exitCode == 0) return name;
    } catch (_) {}
  }
  return null;
}

void main() {
  test('pair with the reference server, take a job, post the answer', () async {
    final python = await findPython();
    if (python == null) {
      markTestSkipped('Python 3 not found');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('gpulend-ref');
    final serverPort = await freePort();
    final server = await Process.start(python, ['reference-server/server.py', '--port', '$serverPort']);
    final lines = server.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    String? adminKey, pairing;
    await for (final line in lines.timeout(const Duration(seconds: 15))) {
      if (line.startsWith('admin key')) adminKey = line.split(':').last.trim();
      if (line.startsWith('pairing')) {
        pairing = line.substring(line.indexOf(':') + 1).trim();
        break;
      }
    }
    expect(adminKey, isNotNull);
    expect(pairing, startsWith('GLEND1.'));

    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); // stands in for sd-server
    backend.listen((r) async {
      final body = await utf8.decoder.bind(r).join();
      r.response.headers.contentType = ContentType.json;
      r.response.write(r.method == 'POST' ? '{"echo":${jsonEncode(body)}}' : '{}');
      await r.response.close();
    });
    final store = ConfigStore(directory: temp);
    await store.save(AppConfig(modelPort: backend.port));
    final engine = Engine(store: store, heartbeatEvery: const Duration(seconds: 1));
    await engine.start();
    try {
      final error = await engine.pair(pairing!, serverUrl: 'http://127.0.0.1:$serverPort');
      expect(error, isNull);
      expect(engine.config.paired, isTrue);

      final c = HttpClient();
      final req = await c.postUrl(Uri.parse('http://127.0.0.1:$serverPort/submit'));
      req.headers.set('X-Admin-Key', adminKey!);
      req.write(jsonEncode({'backend': 'image', 'path': '/v1/images/generations', 'body': {'prompt': 'a cat'}}));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final text = await res.transform(utf8.decoder).join();
      c.close(force: true);
      expect(res.statusCode, 200, reason: text);
      expect(text, contains('a cat'));
      expect(engine.jobsDone, 1);
    } finally {
      await engine.shutdown();
      server.kill();
      await backend.close(force: true);
      try {
        temp.deleteSync(recursive: true); // Windows may still hold the log file
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
