// The app's conversation with the server (see PROTOCOL.md). The server is dialled over HTTPS only (plain http is allowed for localhost, for
// tests). When a direct IP is configured the app connects to that address but still speaks to the site's name (SNI and Host),
// and when a certificate fingerprint is pinned, only that certificate is trusted for the connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'config_store.dart';

class ServerReply {
  ServerReply(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  Map<String, dynamic> get json {
    try {
      final v = jsonDecode(utf8.decode(body));
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

class ServerUnreachable implements Exception {
  ServerUnreachable(this.message);
  final String message;
  @override
  String toString() => message;
}

class Job {
  Job(this.id, this.path, this.body, {this.backend = 'image'});
  final String id;
  final String path;

  /// Which kind of model the server wants (`image`, `llm`, ...); `image` when the server does not say.
  final String backend;
  final Uint8List body;
}

class ServerClient {
  ServerClient(this.config);

  final AppConfig config;
  HttpClient? _client;
  String _clientKey = '';

  static bool urlAllowed(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return false;
    if (u.scheme == 'https') return true;
    return u.scheme == 'http' && (u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '::1');
  }

  HttpClient _http() {
    final key = '${config.serverUrl}|${config.directIp}|${config.certSha256}';
    if (_client != null && key == _clientKey) return _client!;
    _client?.close(force: true);
    final pin = config.certSha256.toLowerCase().replaceAll(':', '');
    // with a pinned certificate no system root is trusted: the pin alone decides
    final context = pin.isNotEmpty ? SecurityContext(withTrustedRoots: false) : null;
    final client = HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'GpuLend';
    if (pin.isNotEmpty) {
      client.badCertificateCallback = (cert, host, port) => sha256.convert(cert.der).toString() == pin;
    }
    final ip = config.directIp.trim();
    if (ip.isNotEmpty) {
      client.connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(ip, uri.port);
    }
    _client = client;
    _clientKey = key;
    return client;
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  Future<ServerReply> _send(String method, String path, {Object? json, List<int>? bytes, Map<String, String>? headers, bool auth = true, Duration timeout = const Duration(seconds: 30)}) async {
    if (!urlAllowed(config.serverUrl)) throw ServerUnreachable('The server address must start with https://');
    final uri = Uri.parse(config.serverUrl.replaceAll(RegExp(r'/+$'), '') + path);
    try {
      final request = await _http().openUrl(method, uri).timeout(timeout);
      if (auth && config.token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.token}');
      headers?.forEach(request.headers.set);
      List<int>? payload = bytes;
      if (json != null) {
        payload = utf8.encode(jsonEncode(json));
        request.headers.contentType = ContentType.json;
      }
      if (payload != null) {
        request.contentLength = payload.length;
        request.add(payload);
      }
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
      }
      final map = <String, String>{};
      response.headers.forEach((name, values) => map[name.toLowerCase()] = values.join(','));
      return ServerReply(response.statusCode, map, builder.takeBytes());
    } on TimeoutException {
      throw ServerUnreachable('The server did not answer in time');
    } on HandshakeException catch (e) {
      throw ServerUnreachable('The server certificate was not accepted (${e.message})');
    } on SocketException catch (e) {
      throw ServerUnreachable('Cannot reach the server (${e.message})');
    } on HttpException catch (e) {
      throw ServerUnreachable('Connection problem (${e.message})');
    }
  }

  /// Exchanges the pairing code from the panel for the device token. Returns the reply body (token, worker_id, settings).
  Future<ServerReply> pair(String code, {required String name, required String version}) =>
      _send('POST', '/worker/pair', json: {'code': code, 'name': name, 'version': version}, auth: false);

  Future<ServerReply> heartbeat({
    required String version,
    required bool onBattery,
    required bool modelReady,
    List<String>? backends,
    Map<String, int>? usage,
    int? baseRev,
    Map<String, dynamic>? edit,
  }) =>
      _send(
        'POST',
        '/worker/heartbeat',
        json: {'version': version, 'on_battery': onBattery, 'model_ready': modelReady, 'backends': ?backends, 'usage': ?usage, 'base_rev': ?baseRev, 'edit': ?edit},
      );

  /// Holds for up to ~20 s on the server; null = nothing to do.
  Future<Job?> nextJob() async {
    final r = await _send('GET', '/worker/next', timeout: const Duration(seconds: 40));
    if (r.status == 204) return null;
    if (r.status == 401) throw const _Unauthorized();
    if (r.status != 200) throw ServerUnreachable('The server answered ${r.status}');
    final id = r.headers['x-lend-job'];
    final path = r.headers['x-lend-path'];
    if (id == null || path == null) throw ServerUnreachable('A job came without its details');
    return Job(id, path, r.body, backend: r.headers['x-lend-backend'] ?? 'image');
  }

  /// Returns the HTTP status the server answered (204 = accepted).
  Future<int> postResult(Job job, int status, List<int> body) async {
    final r = await _send('POST', '/worker/result/${job.id}', bytes: body, headers: {'x-lend-status': '$status'}, timeout: const Duration(seconds: 90));
    if (r.status == 401) throw const _Unauthorized();
    return r.status;
  }
}

class _Unauthorized implements Exception {
  const _Unauthorized();
}

/// Thrown by the client when the server no longer knows this device's token (revoked in the panel).
bool isUnauthorized(Object e) => e is _Unauthorized;
