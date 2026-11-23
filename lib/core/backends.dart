// What this PC can run for the server. A backend is a local program that serves a model on 127.0.0.1 (stable-diffusion.cpp's sd-server for
// pictures, llama.cpp's llama-server for language models, or any program you describe). The server asks for a backend by id in each
// job; the app starts it on demand and forwards the request. Only one backend is kept running at a time by default, so a small graphics
// card is never asked to hold two models.
import 'dart:async';
import 'dart:io';

import 'config_store.dart';
import 'platform_utils.dart';

/// Where a backend gets its command line from.
abstract class BackendSpec {
  String get id;
  String get name;
  int get port;
  String get healthPath;
  List<String> get allowedPaths;
  bool get enabled;

  /// Files (or programs) that are missing; empty = can be started.
  Future<List<String>> missing();

  /// The program, its arguments and its working folder; null when something is missing.
  Future<(String, List<String>, String)?> command(double maxVram);
}

/// stable-diffusion.cpp's sd-server with the Z-Image Turbo files (the first backend, id `image`).
class ImageSpec implements BackendSpec {
  ImageSpec(this.config, this.dataDirectory);
  final AppConfig config;
  final Directory dataDirectory;

  @override
  String get id => 'image';
  @override
  String get name => 'Images (stable-diffusion.cpp)';
  @override
  int get port => config.modelPort;
  @override
  String get healthPath => '/';
  @override
  List<String> get allowedPaths => config.allowedPaths;
  @override
  bool get enabled => config.imageEnabled;

  String get binDirectory => config.binDir.isNotEmpty ? config.binDir : '${dataDirectory.path}${Platform.pathSeparator}bin';
  String get modelsDirectory => config.modelsDir.isNotEmpty ? config.modelsDir : '${dataDirectory.path}${Platform.pathSeparator}models';

  Future<ModelFiles> locate() async {
    final exe = File('$binDirectory${Platform.pathSeparator}${exeName('sd-server')}');
    final found = <String, String>{};
    const wanted = {'z_image_turbo-Q4_K.gguf', 'ae.safetensors', 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf'};
    final dir = Directory(modelsDirectory);
    if (await dir.exists()) {
      try {
        await for (final entity in dir.list(recursive: true, followLinks: true)) {
          if (entity is! File) continue;
          final file = entity.uri.pathSegments.last;
          if (wanted.contains(file) && !found.containsKey(file)) found[file] = entity.path;
        }
      } on FileSystemException {
        // an unreadable sub-folder: what was found so far is used
      }
    }
    return ModelFiles(
      exe: await exe.exists() ? exe.path : null,
      diffusion: found['z_image_turbo-Q4_K.gguf'],
      vae: found['ae.safetensors'],
      llm: found['Qwen3-4B-Instruct-2507-Q4_K_M.gguf'],
    );
  }

  @override
  Future<List<String>> missing() async => (await locate()).missing;

  @override
  Future<(String, List<String>, String)?> command(double maxVram) async {
    final f = await locate();
    if (!f.complete) return null;
    return (
      f.exe!,
      [
        '--diffusion-model', f.diffusion!,
        '--vae', f.vae!,
        '--llm', f.llm!,
        '--cfg-scale', '1.0',
        '--sampling-method', 'euler',
        '--steps', '8',
        '--seed', '-1',
        '--backend', 'te=cpu',
        if (maxVram > 0) ...['--max-vram', maxVram.toStringAsFixed(1)],
        '--listen-ip', '127.0.0.1',
        '--listen-port', '$port',
      ],
      binDirectory,
    );
  }
}

class ModelFiles {
  ModelFiles({this.exe, this.diffusion, this.vae, this.llm});
  final String? exe;
  final String? diffusion;
  final String? vae;
  final String? llm;

  List<String> get missing => [
        if (exe == null) exeName('sd-server'),
        if (diffusion == null) 'z_image_turbo-Q4_K.gguf',
        if (vae == null) 'ae.safetensors',
        if (llm == null) 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
      ];
  bool get complete => missing.isEmpty;
}

/// A backend described in config.json: a language model (`llm`, llama.cpp's llama-server) or any program (`custom`).
class BackendProfile {
  BackendProfile({
    required this.id,
    required this.name,
    this.kind = 'custom',
    this.enabled = true,
    this.exe = '',
    this.args = const [],
    this.port = 0,
    this.healthPath = '/',
    this.allowedPaths = const [],
    this.modelFile = '',
  });

  String id;
  String name;
  String kind; // 'llama' | 'custom'
  bool enabled;
  String exe;

  /// Arguments; `{port}`, `{model}` and `{maxVram}` are replaced when it starts.
  List<String> args;
  int port;
  String healthPath;
  List<String> allowedPaths;

  /// For llama.cpp: the .gguf file to load.
  String modelFile;

  /// The language-model preset: llama.cpp's llama-server on port 1235.
  factory BackendProfile.llama({String exe = '', String modelFile = ''}) => BackendProfile(
        id: 'llm',
        name: 'Language model (llama.cpp)',
        kind: 'llama',
        exe: exe,
        modelFile: modelFile,
        port: 1235,
        healthPath: '/health',
        args: const ['-m', '{model}', '--host', '127.0.0.1', '--port', '{port}', '-ngl', '99', '-c', '8192'],
        allowedPaths: const ['/v1/chat/completions', '/v1/completions', '/v1/embeddings', '/completion', '/tokenize', '/detokenize'],
      );

  factory BackendProfile.fromJson(Map<String, dynamic> j) => BackendProfile(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        kind: (j['kind'] ?? 'custom') as String,
        enabled: (j['enabled'] ?? true) as bool,
        exe: (j['exe'] ?? '') as String,
        args: ((j['args'] ?? const <dynamic>[]) as List).whereType<String>().toList(),
        port: ((j['port'] ?? 0) as num).toInt(),
        healthPath: (j['health_path'] ?? '/') as String,
        allowedPaths: ((j['allowed_paths'] ?? const <dynamic>[]) as List).whereType<String>().toList(),
        modelFile: (j['model_file'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'enabled': enabled,
        'exe': exe,
        'args': args,
        'port': port,
        'health_path': healthPath,
        'allowed_paths': allowedPaths,
        'model_file': modelFile,
      };

  /// Ids are what the server asks for: lowercase letters, digits, `_` and `-`.
  static bool validId(String id) => RegExp(r'^[a-z0-9_-]{1,24}$').hasMatch(id);
}

class ProfileSpec implements BackendSpec {
  ProfileSpec(this.profile);
  final BackendProfile profile;

  @override
  String get id => profile.id;
  @override
  String get name => profile.name;
  @override
  int get port => profile.port;
  @override
  String get healthPath => profile.healthPath;
  @override
  List<String> get allowedPaths => profile.allowedPaths;
  @override
  bool get enabled => profile.enabled;

  @override
  Future<List<String>> missing() async => [
        if (profile.exe.isEmpty || !await File(profile.exe).exists()) profile.exe.isEmpty ? 'program' : profile.exe.split(Platform.pathSeparator).last,
        if (profile.args.any((a) => a.contains('{model}')) && (profile.modelFile.isEmpty || !await File(profile.modelFile).exists())) 'model file',
      ];

  @override
  Future<(String, List<String>, String)?> command(double maxVram) async {
    if ((await missing()).isNotEmpty) return null;
    final args = [
      for (final a in profile.args) a.replaceAll('{port}', '${profile.port}').replaceAll('{model}', profile.modelFile).replaceAll('{maxVram}', maxVram.toStringAsFixed(1)),
    ];
    return (profile.exe, args, File(profile.exe).parent.path);
  }
}

/// Runs one backend's program, watches it, stops it. An answering port that this app did not start is used as it is ("external").
class BackendRunner {
  BackendRunner({required this.spec, required this.dataDirectory, this.log});

  BackendSpec spec;
  final Directory dataDirectory;
  final void Function(String line)? log;

  Process? _process;
  int _exitCode = 0;
  bool _stopRequested = false;
  DateTime? startedAt;

  bool get ownProcessAlive => _process != null;
  int get lastExitCode => _exitCode;

  /// Is the backend ready to take a job? The port must answer its health path with 200: llama-server opens its port while the model
  /// is still loading and answers 503 until it is ready, so an open port alone is not enough.
  Future<bool> listening() async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 400);
    try {
      final path = spec.healthPath.isEmpty ? '/' : spec.healthPath;
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:${spec.port}$path')).timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Starts the program with the given VRAM ceiling. Returns an error text, or null when it was started.
  Future<String?> start(double maxVram) async {
    if (_process != null) return null;
    final command = await spec.command(maxVram);
    if (command == null) return 'Missing: ${(await spec.missing()).join(', ')}';
    await dataDirectory.create(recursive: true);
    final out = File('${dataDirectory.path}${Platform.pathSeparator}model-${spec.id}.log');
    final sink = out.openWrite(mode: FileMode.writeOnlyAppend);
    try {
      final process = await Process.start(command.$1, command.$2, workingDirectory: command.$3, runInShell: false);
      _process = process;
      startedAt = DateTime.now();
      log?.call('${spec.id} started (pid ${process.pid}, max VRAM $maxVram)');
      unawaited(process.stdout.listen(sink.add).asFuture<void>().catchError((_) {}));
      unawaited(process.stderr.listen(sink.add).asFuture<void>().catchError((_) {}));
      unawaited(process.exitCode.then((code) async {
        _exitCode = code;
        _process = null;
        log?.call(_stopRequested ? '${spec.id} stopped by the app' : '${spec.id} exited with code $code');
        _stopRequested = false;
        await sink.flush();
        await sink.close();
      }));
      return null;
    } on ProcessException catch (e) {
      await sink.close();
      return 'Could not start ${spec.name}: ${e.message}';
    }
  }

  /// Stops the process this app started (an external one is left alone).
  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _stopRequested = true;
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }
}
