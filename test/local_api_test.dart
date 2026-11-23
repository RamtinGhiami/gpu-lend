// The standalone mode: the local API must refuse requests without the key and forward the others to a running backend.
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

Future<(int, String)> call(String method, int port, String path, {String? key, String body = ''}) async {
  final c = HttpClient();
  try {
    final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    if (key != null) req.headers.set('authorization', 'Bearer $key');
    if (method == 'POST') {
      req.headers.contentType = ContentType.json;
      req.write(body);
    }
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  } finally {
    c.close(force: true);
  }
}

void main() {
  test('local API: key required, requests forwarded to the backend', () async {
    final temp = Directory.systemTemp.createTempSync('gpulend-test');
    final seen = <String>[];
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); // stands in for sd-server
    backend.listen((r) async {
      seen.add('${r.method} ${r.uri.path} ${await utf8.decoder.bind(r).join()}');
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"data":[{"b64_json":"AAAA"}]}');
      await r.response.close();
    });
    final apiPort = await freePort();
    final store = ConfigStore(directory: temp);
    await store.save(AppConfig(modelPort: backend.port, localApiEnabled: true, localApiPort: apiPort, localApiKey: 'glend-test-key'));
    final engine = Engine(store: store);
    await engine.start();
    try {
      expect((await call('GET', apiPort, '/health')).$1, 401, reason: 'no key');
      expect((await call('GET', apiPort, '/health', key: 'wrong')).$1, 401, reason: 'wrong key');
      final health = await call('GET', apiPort, '/health', key: 'glend-test-key');
      expect(health.$1, 200);

      final img = await call('POST', apiPort, '/v1/images/generations', key: 'glend-test-key', body: '{"prompt":"a cat"}');
      expect(img.$1, 200);
      expect(img.$2, contains('b64_json'));
      // the engine also asks the backend if it is alive (GET), so only the POSTs are compared
      expect(seen.where((e) => e.startsWith('POST')).single, 'POST /v1/images/generations {"prompt":"a cat"}');

      expect((await call('POST', apiPort, '/v1/not-offered', key: 'glend-test-key', body: '{}')).$1, 404);
      expect(engine.jobsDone, 1);
    } finally {
      await engine.shutdown();
      await backend.close(force: true);
      try {
        temp.deleteSync(recursive: true); // Windows may still hold the log file
      } catch (_) {}
    }
  });
}
