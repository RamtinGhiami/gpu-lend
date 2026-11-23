// The standalone mode: GPU Lend can serve its models to programs on this PC (or, if you allow it, on your network) without any
// server. It is an OpenAI-style HTTP API: POST /v1/chat/completions, /v1/completions, /v1/embeddings and /v1/images/generations
// (whatever the enabled backends allow), plus GET /health and GET /v1/models. Every request needs the API key shown in the app, so
// a web page in your browser cannot use your graphics card.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'engine.dart';

class LocalApiError implements Exception {
  LocalApiError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class LocalApi {
  LocalApi(this.engine);
  final Engine engine;
  HttpServer? _server;
  String? error;
  int? _boundPort;
  bool? _boundLan;

  bool get running => _server != null;
  int get port => _boundPort ?? engine.config.localApiPort;

  /// The address programs should use.
  String get baseUrl => 'http://127.0.0.1:$port/v1';

  /// Starts, stops or restarts the server so it matches the settings.
  Future<void> apply() async {
    final c = engine.config;
    if (!c.localApiEnabled) {
      await stop();
      return;
    }
    if (_server != null && _boundPort == c.localApiPort && _boundLan == c.localApiLan) return;
    await stop();
    try {
      _server = await HttpServer.bind(c.localApiLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, c.localApiPort);
      _boundPort = c.localApiPort;
      _boundLan = c.localApiLan;
      error = null;
      _server!.listen(_handle, onError: (_) {});
      engine.log('local API listening on ${c.localApiLan ? 'all addresses' : '127.0.0.1'}:${c.localApiPort}');
    } on SocketException catch (e) {
      error = 'Port ${c.localApiPort} is not available (${e.osError?.message ?? e.message})';
      engine.log('local API: $error');
    }
    engine.refresh();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _boundPort = null;
  }

  static bool _sameKey(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  void _json(HttpResponse r, int status, Object body) {
    r.statusCode = status;
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    r.close();
  }

  Future<void> _handle(HttpRequest r) async {
    try {
      final key = engine.config.localApiKey;
      final auth = r.headers.value('authorization') ?? '';
      if (key.isEmpty || !auth.startsWith('Bearer ') || !_sameKey(auth.substring(7).trim(), key)) {
        return _json(r.response, 401, {'error': {'message': 'Missing or wrong API key. Copy it from the GPU Lend app.', 'type': 'invalid_api_key'}});
      }
      final path = r.uri.path;
      if (r.method == 'GET' && path == '/health') {
        return _json(r.response, 200, {'status': 'ok', 'version': engine.version, 'backends': engine.availableBackendIds});
      }
      if (r.method == 'GET' && path == '/v1/models') {
        return _json(r.response, 200, {
          'object': 'list',
          'data': [for (final id in engine.availableBackendIds) {'id': id, 'object': 'model', 'owned_by': 'gpu-lend'}],
        });
      }
      if (r.method != 'POST') return _json(r.response, 404, {'error': {'message': 'Not found'}});

      final body = BytesBuilder(copy: false);
      var size = 0;
      await for (final chunk in r) {
        size += chunk.length;
        if (size > 64 * 1024 * 1024) return _json(r.response, 413, {'error': {'message': 'Request too large'}});
        body.add(chunk);
      }
      final bytes = body.takeBytes();
      await engine.useBackend(path, r.headers.value('x-lend-backend'), (port) async {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        try {
          final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
          req.headers.contentType = ContentType.json;
          req.contentLength = bytes.length;
          req.add(bytes);
          final res = await req.close();
          r.response.statusCode = res.statusCode;
          final type = res.headers.contentType;
          if (type != null) r.response.headers.contentType = type;
          // streamed answers (stream: true) are passed on as they arrive
          await r.response.addStream(res);
          await r.response.close();
        } finally {
          client.close(force: true);
        }
      });
    } on LocalApiError catch (e) {
      try {
        _json(r.response, e.status, {'error': {'message': e.message}});
      } catch (_) {}
    } catch (e) {
      engine.log('local API request failed: $e');
      try {
        _json(r.response, 502, {'error': {'message': 'The model did not answer'}});
      } catch (_) {}
    }
  }
}
