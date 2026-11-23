// The heart of the app: pairs with the server, keeps a local model backend running when it should, takes jobs from the server one at a
// time, hands each to the backend it names, posts the answers back, counts what was lent today, and keeps this PC's settings in step
// with the server (both ways).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'backends.dart';
import 'config_store.dart';
import 'local_api.dart';
import 'platform_utils.dart';
import 'server_client.dart';
import 'system_info.dart';

enum DeviceState { unpaired, revoked, offline, paused, startingModel, missingFiles, ready, working }

/// Runs one async job at a time, in the order they were asked for.
class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final done = Completer<void>();
    final before = _tail;
    _tail = done.future;
    return before.then((_) => fn()).whenComplete(done.complete);
  }
}

class JobRecord {
  JobRecord({required this.id, required this.backend, required this.path, required this.at, required this.millis, required this.status});
  final String id;
  final String backend;
  final String path;
  final DateTime at;
  final int millis;
  final int status;
  bool get ok => status >= 200 && status < 300;
}

/// One line of the "workloads" list: what a backend is and whether it can run.
class BackendStatus {
  BackendStatus({required this.id, required this.name, required this.enabled, required this.missing, required this.listening, required this.own});
  final String id;
  final String name;
  final bool enabled;
  final List<String> missing;
  final bool listening;
  final bool own;
  bool get available => enabled && (listening || missing.isEmpty);
}

/// What the pairing text from the server carries: the address, optionally a direct IP and a pinned certificate, and the code.
class PairingText {
  PairingText({required this.code, this.url = '', this.ip = '', this.fingerprint = ''});
  final String code;
  final String url;
  final String ip;
  final String fingerprint;

  /// `GLEND1.<base64url json>` from the server, or just the 8-letter code.
  static PairingText? parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('GLEND1.')) {
      try {
        final raw = t.substring(7);
        final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw)))) as Map<String, dynamic>;
        final code = (j['c'] ?? '') as String;
        if (code.isEmpty) return null;
        return PairingText(code: code, url: (j['u'] ?? '') as String, ip: (j['ip'] ?? '') as String, fingerprint: (j['fp'] ?? '') as String);
      } catch (_) {
        return null;
      }
    }
    return PairingText(code: t);
  }
}

class Engine extends ChangeNotifier {
  Engine({
    ConfigStore? store,
    this.version = '1.0.0',
    this.heartbeatEvery = const Duration(seconds: 10),
    this.superviseEvery = const Duration(seconds: 3),
    this.onAutostart,
    DateTime Function()? clock,
  })  : store = store ?? ConfigStore(),
        _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final String version;
  final Duration heartbeatEvery;
  final Duration superviseEvery;

  /// Called when the autostart setting changes (the shell registers or removes the Windows sign-in entry).
  final Future<void> Function(bool enabled)? onAutostart;
  final DateTime Function() _clock;

  late AppConfig config;
  late final LocalApi localApi = LocalApi(this);
  final _Mutex _turn = _Mutex(); // the card runs one thing at a time: a server job or a local request
  late ServerClient _client;
  final Map<String, BackendRunner> _runners = {};

  // what the screens show
  DeviceState state = DeviceState.unpaired;
  String detail = '';
  bool modelReady = false;
  bool modelExternal = false;
  ModelFiles? files;
  List<BackendStatus> backends = [];
  String? activeBackend;
  GpuInfo? gpu;

  /// Readings of the card every 2 seconds, the last 10 minutes (for the chart).
  final List<GpuSample> gpuHistory = [];
  DateTime? lastContact;
  String? serverError;
  String? notice;
  final List<JobRecord> recent = [];
  int jobsDone = 0;
  int jobsFailed = 0;
  int totalMillis = 0;
  int peakMillis = 0;

  bool _alive = false;
  bool _busy = false;
  bool _superviseBusy = false;
  Map<String, dynamic>? _pendingEdit;
  Timer? _superviseTimer;
  Timer? _heartbeatTimer;
  int _modelFailures = 0;
  DateTime _modelRetryAt = DateTime.fromMillisecondsSinceEpoch(0);

  void log(String line) {
    try {
      store.directory.createSync(recursive: true);
      final f = store.logFile;
      if (f.existsSync() && f.lengthSync() > 512 * 1024) f.writeAsStringSync('');
      f.writeAsStringSync('${_clock().toIso8601String()} $line\n', mode: FileMode.append);
    } catch (_) {
      // logging must never break the app
    }
  }

  /// The hour of day on this PC, which is what the working hours mean.
  int get localHour => _clock().hour;

  Duration get averageJob => jobsDone == 0 ? Duration.zero : Duration(milliseconds: totalMillis ~/ jobsDone);

  // ------------------------------------------------------------------------------------------------------------ backends

  ImageSpec get imageSpec => ImageSpec(config, store.directory);

  /// Every backend this PC knows about: the picture backend first, then the ones from config.json.
  List<BackendSpec> allSpecs() => [imageSpec, for (final p in config.extraBackends) ProfileSpec(p)];

  BackendRunner _runnerFor(BackendSpec spec) {
    final r = _runners.putIfAbsent(spec.id, () => BackendRunner(spec: spec, dataDirectory: store.directory, log: log));
    r.spec = spec;
    return r;
  }

  List<String> get availableBackendIds => backends.where((b) => b.available).map((b) => b.id).toList();

  Future<void> _refreshBackends() async {
    final out = <BackendStatus>[];
    for (final spec in allSpecs()) {
      final runner = _runnerFor(spec);
      final listening = await runner.listening();
      out.add(BackendStatus(id: spec.id, name: spec.name, enabled: spec.enabled, missing: await spec.missing(), listening: listening, own: runner.ownProcessAlive));
    }
    backends = out;
    files = await imageSpec.locate();
  }

  // ------------------------------------------------------------------------------------------------------------ lifecycle

  Future<void> start() async {
    config = await store.load();
    _client = ServerClient(config);
    _alive = true;
    PowerStatus.start();
    log('app started (v$version, paired: ${config.paired})');
    _rollDay();
    _refreshState();
    _superviseTimer = Timer.periodic(superviseEvery, (_) => unawaited(_supervise()));
    _heartbeatTimer = Timer.periodic(heartbeatEvery, (_) => unawaited(_heartbeat()));
    unawaited(_supervise());
    unawaited(_heartbeat());
    unawaited(_jobLoop());
    unawaited(_gpuLoop());
    await localApi.apply();
  }

  Future<void> shutdown() async {
    _alive = false;
    _superviseTimer?.cancel();
    _heartbeatTimer?.cancel();
    await localApi.stop();
    PowerStatus.stop();
    for (final r in _runners.values) {
      await r.stop();
    }
    _client.close();
  }

  // ------------------------------------------------------------------------------------------------------------- pairing

  /// Pairs this PC with the server. [serverUrl] is needed only when the text is a bare code.
  Future<String?> pair(String text, {String serverUrl = ''}) async {
    final p = PairingText.parse(text);
    if (p == null) return 'Paste the pairing text (or the 8-letter code) from the server.';
    final url = (p.url.isNotEmpty ? p.url : serverUrl).trim().replaceAll(RegExp(r'/+$'), '');
    if (!ServerClient.urlAllowed(url)) return 'Enter the server address (https://…).';
    final trial = AppConfig(serverUrl: url, directIp: p.ip, certSha256: p.fingerprint);
    final client = ServerClient(trial);
    try {
      final name = computerName();
      final r = await client.pair(p.code, name: name, version: version);
      if (r.status != 200) {
        return (r.json['error'] ?? 'The code was not accepted.') as String;
      }
      final j = r.json;
      config
        ..serverUrl = url
        ..directIp = p.ip
        ..certSha256 = p.fingerprint
        ..token = (j['token'] ?? '') as String
        ..workerId = ((j['worker_id'] ?? 0) as num).toInt()
        ..localEnabled = true
        ..settings = DeviceSettings.fromJson((j['settings'] ?? <String, dynamic>{}) as Map<String, dynamic>);
      // what the user chose before pairing wins over the server's defaults for a new device; it is sent with the first heartbeat
      final earlier = Map<String, dynamic>.from(config.unpairedEdits);
      config.unpairedEdits = {};
      if (earlier.isNotEmpty) {
        _applyChanges(earlier);
        _pendingEdit = {...?_pendingEdit, ...earlier};
      }
      await store.save(config);
      _client.close();
      _client = ServerClient(config);
      serverError = null;
      log('paired as worker ${config.workerId}');
      await _applyAutostart();
      _refreshState();
      unawaited(_heartbeat());
      return null;
    } on ServerUnreachable catch (e) {
      return e.message;
    } finally {
      client.close();
    }
  }

  /// Forgets the server on this PC (the device stays in the server's list until it is revoked there).
  Future<void> unpair() async {
    await _stopAll();
    config
      ..token = ''
      ..workerId = 0;
    await store.save(config);
    state = DeviceState.unpaired;
    modelReady = false;
    notifyListeners();
  }

  Future<void> _stopAll() async {
    for (final r in _runners.values) {
      await r.stop();
    }
  }

  // ------------------------------------------------------------------------------------------------------------ settings

  /// The "power" button on this PC.
  Future<void> setLocalEnabled(bool on) async {
    config.localEnabled = on;
    await store.save(config);
    _refreshState();
    unawaited(_supervise());
  }

  void _applyChanges(Map<String, dynamic> changes) {
    final s = config.settings;
    changes.forEach((k, v) {
      switch (k) {
        case 'name':
          s.name = v as String;
        case 'enabled':
          s.enabled = v as bool;
        case 'max_vram':
          s.maxVram = (v as num).toDouble();
        case 'hour_from':
          s.hourFrom = v as int;
        case 'hour_to':
          s.hourTo = v as int;
        case 'ac_only':
          s.acOnly = v as bool;
        case 'autostart':
          s.autostart = v as bool;
        case 'daily_minutes':
          s.dailyMinutes = v as int;
        case 'daily_jobs':
          s.dailyJobs = v as int;
      }
    });
  }

  /// An edit made here: shown at once, sent with the next heartbeat on top of the revision the app last saw. Before pairing it is only
  /// kept on this PC and handed to the server when pairing succeeds.
  Future<void> edit(Map<String, dynamic> changes) async {
    _applyChanges(changes);
    if (config.paired) {
      _pendingEdit = {...?_pendingEdit, ...changes};
    } else {
      config.unpairedEdits = {...config.unpairedEdits, ...changes};
    }
    await store.save(config);
    notifyListeners();
    if (changes.containsKey('autostart') && config.paired) await _applyAutostart();
    unawaited(_supervise());
    unawaited(_heartbeat());
  }

  /// Local choices that are not shared with the server: folders, the image port, which backends are on, extra backends.
  Future<void> setLocal({String? binDir, String? modelsDir, int? port, bool? imageEnabled}) async {
    if (binDir != null) config.binDir = binDir;
    if (modelsDir != null) config.modelsDir = modelsDir;
    if (port != null) config.modelPort = port;
    if (imageEnabled != null) config.imageEnabled = imageEnabled;
    await store.save(config);
    await _refreshBackends();
    notifyListeners();
  }

  /// Adds or replaces an extra backend (a language model, anything else). Returns an error text, or null.
  Future<String?> saveBackend(BackendProfile profile) async {
    if (!BackendProfile.validId(profile.id) || profile.id == 'image') return 'The id must be 1 to 24 characters: a-z, 0-9, - or _ (and not "image").';
    if (profile.port < 1024 || profile.port > 65535) return 'Choose a port between 1024 and 65535.';
    if (profile.port == config.modelPort || config.extraBackends.any((b) => b.id != profile.id && b.port == profile.port)) return 'That port is used by another backend.';
    final i = config.extraBackends.indexWhere((b) => b.id == profile.id);
    if (i >= 0) {
      config.extraBackends[i] = profile;
    } else {
      config.extraBackends.add(profile);
    }
    await store.save(config);
    await _refreshBackends();
    notifyListeners();
    unawaited(_heartbeat());
    return null;
  }

  Future<void> removeBackend(String id) async {
    await _runners[id]?.stop();
    _runners.remove(id);
    config.extraBackends.removeWhere((b) => b.id == id);
    await store.save(config);
    await _refreshBackends();
    notifyListeners();
    unawaited(_heartbeat());
  }

  Future<void> restartModel() async {
    await _stopAll();
    _modelFailures = 0;
    _modelRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(_supervise());
  }

  Future<void> _applyAutostart() async {
    try {
      await onAutostart?.call(config.settings.autostart && config.paired);
    } catch (e) {
      log('autostart: $e');
    }
  }

  // --------------------------------------------------------------------------------------------------------------- limits

  String _today() {
    final d = _clock();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// A new day starts the counters again.
  void _rollDay() {
    final today = _today();
    if (config.usageDay != today) {
      config
        ..usageDay = today
        ..usageMillis = 0
        ..usageJobs = 0;
    }
  }

  int get usedMinutesToday {
    _rollDay();
    return (config.usageMillis / 60000).round();
  }

  int get usedJobsToday {
    _rollDay();
    return config.usageJobs;
  }

  String? pauseReason() {
    if (!config.paired) return null;
    final s = config.settings;
    if (!config.localEnabled) return 'Stopped on this PC';
    if (s.maxVram <= 0) return 'Graphics memory to lend is 0';
    if (!s.enabled) return 'Switched off from the server';
    if (!s.inHours(localHour)) return 'Outside working hours (${s.hourFrom}:00 to ${s.hourTo}:00)';
    if (s.acOnly && PowerStatus.onBattery) return 'Running on battery';
    _rollDay();
    if (s.dailyMinutes > 0 && config.usageMillis >= s.dailyMinutes * 60000) return 'Daily limit reached (${s.dailyMinutes} min). Back tomorrow';
    if (s.dailyJobs > 0 && config.usageJobs >= s.dailyJobs) return 'Daily limit reached (${s.dailyJobs} jobs). Back tomorrow';
    return null;
  }

  // --------------------------------------------------------------------------------------------------------------- loops

  /// The backend kept warm: the one last used if it can run, otherwise the first that can.
  BackendStatus? _warm() {
    final ok = backends.where((b) => b.available).toList();
    if (ok.isEmpty) return null;
    return ok.firstWhere((b) => b.id == activeBackend, orElse: () => ok.first);
  }

  Future<void> _supervise() async {
    if (!_alive || _superviseBusy) return;
    _superviseBusy = true; // one pass at a time
    try {
      if (!config.paired) {
        modelReady = false;
        _refreshState();
        return;
      }
      await _refreshBackends();
      if (_busy) {
        // never touch a backend while it is drawing; only the picture of the situation is refreshed
        _refreshState();
        return;
      }
      final reason = pauseReason();
      if (reason != null) {
        // lend nothing: free the graphics card
        for (final r in _runners.values) {
          if (r.ownProcessAlive) await r.stop();
        }
        modelReady = false;
        modelExternal = false;
        detail = reason;
        _refreshState(paused: true);
        return;
      }
      final warm = _warm();
      if (warm == null) {
        modelReady = false;
        final names = backends.where((b) => b.enabled).expand((b) => b.missing).toSet();
        detail = names.isEmpty ? 'No backend is switched on' : 'Missing: ${names.join(', ')}';
        _refreshState(missing: true);
        return;
      }
      final runner = _runners[warm.id]!;
      // only the warm backend stays running: another one of ours is stopped to free the card
      for (final entry in _runners.entries) {
        if (entry.key != warm.id && entry.value.ownProcessAlive) await entry.value.stop();
      }
      modelExternal = warm.listening && !runner.ownProcessAlive;
      if (!warm.listening && !runner.ownProcessAlive && !_clock().isBefore(_modelRetryAt)) {
        final error = await runner.start(config.settings.maxVram);
        if (error != null) {
          detail = error;
          _modelFailures++;
        } else if (runner.lastExitCode != 0) {
          _modelFailures++;
        }
        // after repeated quick failures wait a minute before the next try
        if (_modelFailures >= 3) _modelRetryAt = _clock().add(const Duration(minutes: 1));
      }
      modelReady = await runner.listening();
      if (modelReady) {
        _modelFailures = 0;
        activeBackend = warm.id;
      }
      detail = '';
      _refreshState();
    } finally {
      _superviseBusy = false;
    }
  }

  /// Can the server give this device jobs? (Backends start on demand, so a backend that is not loaded yet does not count against it.)
  bool get acceptingJobs => config.paired && pauseReason() == null && availableBackendIds.isNotEmpty && _modelFailures < 3;

  void _refreshState({bool paused = false, bool missing = false}) {
    if (!config.paired) {
      state = serverError == 'revoked' ? DeviceState.revoked : DeviceState.unpaired;
    } else if (serverError != null && serverError != 'revoked' && lastContact != null && _clock().difference(lastContact!) > const Duration(seconds: 40)) {
      state = DeviceState.offline;
    } else if (paused || pauseReason() != null) {
      state = DeviceState.paused;
    } else if (missing) {
      state = DeviceState.missingFiles;
    } else if (_busy) {
      state = DeviceState.working;
    } else if (modelReady) {
      state = DeviceState.ready;
    } else {
      state = DeviceState.startingModel;
    }
    notifyListeners();
  }

  Future<void> _heartbeat() async {
    if (!_alive || !config.paired) return;
    try {
      final edit = _pendingEdit;
      final r = await _client.heartbeat(
        version: version,
        onBattery: PowerStatus.onBattery,
        modelReady: acceptingJobs,
        backends: availableBackendIds,
        usage: {'minutes': usedMinutesToday, 'jobs': usedJobsToday},
        baseRev: edit == null ? null : config.settings.rev,
        edit: edit,
      );
      if (r.status == 401) {
        log('the server no longer knows this device (revoked)');
        config.token = '';
        await store.save(config);
        serverError = 'revoked';
        await _stopAll();
        _refreshState();
        return;
      }
      if (r.status != 200) throw ServerUnreachable('The server answered ${r.status}');
      lastContact = _clock();
      serverError = null;
      final incoming = DeviceSettings.fromJson((r.json['settings'] ?? <String, dynamic>{}) as Map<String, dynamic>);
      if (edit != null) {
        // the edit was either taken (the revision moved on from ours) or ignored because the server changed something first
        final taken = incoming.rev > config.settings.rev && _matches(incoming, edit);
        _pendingEdit = null;
        if (!taken) notice = 'The settings were changed on the server at the same time; the server\'s values were kept.';
      }
      if (incoming.rev != config.settings.rev || edit != null) {
        final autostartChanged = incoming.autostart != config.settings.autostart;
        config.settings = incoming;
        await store.save(config);
        if (autostartChanged) await _applyAutostart();
        unawaited(_supervise());
      }
      _refreshState();
    } on ServerUnreachable catch (e) {
      serverError = e.message;
      _refreshState();
    } catch (e) {
      serverError = '$e';
      _refreshState();
    }
  }

  bool _matches(DeviceSettings s, Map<String, dynamic> edit) {
    final j = s.toJson();
    return edit.entries.every((e) => j[e.key] == e.value || (j[e.key] is num && e.value is num && (j[e.key] as num).toDouble() == (e.value as num).toDouble()));
  }

  Future<void> _gpuLoop() async {
    while (_alive) {
      gpu = await SystemInfo.gpu();
      final g = gpu;
      if (g != null) {
        gpuHistory.add(GpuSample(_clock(), g.utilization, g.usedMb, g.totalMb));
        if (gpuHistory.length > 300) gpuHistory.removeRange(0, gpuHistory.length - 300);
      }
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _jobLoop() async {
    var backoff = 1;
    while (_alive) {
      if (!config.paired || pauseReason() != null || _busy || availableBackendIds.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        continue;
      }
      try {
        final job = await _client.nextJob();
        backoff = 1;
        if (job == null) continue;
        await _runJob(job);
      } on ServerUnreachable catch (e) {
        serverError = e.message;
        _refreshState();
        await Future<void>.delayed(Duration(seconds: backoff));
        backoff = (backoff * 2).clamp(1, 30);
      } catch (e) {
        if (isUnauthorized(e)) {
          await _heartbeat();
        } else {
          log('job loop: $e');
        }
        await Future<void>.delayed(Duration(seconds: backoff));
        backoff = (backoff * 2).clamp(1, 30);
      }
    }
  }

  BackendSpec? _specFor(Job job) {
    final specs = allSpecs().where((s) => s.enabled).toList();
    for (final s in specs) {
      if (s.id == job.backend) return s;
    }
    return null;
  }

  /// Makes sure the backend a job names is running (stopping our other backend first when the card is shared). Returns an error text.
  Future<String?> _ensure(BackendSpec spec) async {
    final runner = _runnerFor(spec);
    // the card is shared: whatever else this app started is stopped first, even when the wanted backend is already answering
    for (final entry in _runners.entries) {
      if (entry.key != spec.id && entry.value.ownProcessAlive) await entry.value.stop();
    }
    if (await runner.listening()) {
      activeBackend = spec.id;
      return null;
    }
    final error = await runner.start(config.settings.maxVram);
    if (error != null) return error;
    final end = _clock().add(const Duration(seconds: 240));
    while (_clock().isBefore(end)) {
      if (await runner.listening()) {
        activeBackend = spec.id;
        return null;
      }
      if (!runner.ownProcessAlive) return '${spec.name} stopped while loading (code ${runner.lastExitCode})';
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return '${spec.name} did not become ready in time';
  }

  Future<void> _runJob(Job job) => _turn.run(() => _runJobLocked(job));

  Future<void> _runJobLocked(Job job) async {
    _busy = true;
    _refreshState();
    final watch = Stopwatch()..start();
    var status = 503;
    List<int> body = utf8.encode('{"error":"the device could not run the job"}');
    try {
      final spec = _specFor(job);
      if (spec == null) {
        status = 503;
        body = utf8.encode('{"error":"this device does not offer the backend ${job.backend.replaceAll(RegExp(r'[^a-z0-9_-]'), '')}"}');
      } else if (!spec.allowedPaths.contains(job.path)) {
        status = 400;
        body = utf8.encode('{"error":"path not allowed"}');
      } else {
        final error = await _ensure(spec);
        if (error != null) {
          log('job ${job.id}: $error');
          body = utf8.encode(jsonEncode({'error': error}));
        } else {
          final r = await _local(spec.port, job.path, job.body);
          status = r.$1;
          body = r.$2;
        }
      }
    } catch (e) {
      log('job ${job.id} failed: $e');
    }
    watch.stop();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final code = await _client.postResult(job, status, body);
        if (code == 413 || code == 400 || code == 403) {
          log('the server refused the result of job ${job.id} (HTTP $code)');
          break;
        }
        if (code >= 500) throw 'HTTP $code';
        break;
      } catch (e) {
        if (attempt == 2) log('could not post the result of job ${job.id}: $e');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    final ok = status >= 200 && status < 300;
    if (ok) {
      jobsDone++;
      totalMillis += watch.elapsedMilliseconds;
      if (watch.elapsedMilliseconds > peakMillis) peakMillis = watch.elapsedMilliseconds;
    } else {
      jobsFailed++;
    }
    // what was lent counts towards today's limit, whether the job worked or not (the card was used)
    _rollDay();
    config.usageMillis += watch.elapsedMilliseconds;
    config.usageJobs++;
    await store.save(config);
    recent.insert(0, JobRecord(id: job.id, backend: job.backend, path: job.path, at: _clock(), millis: watch.elapsedMilliseconds, status: status));
    if (recent.length > 30) recent.removeLast();
    _busy = false;
    _refreshState();
    unawaited(_heartbeat());
  }

  /// For the local API: waits for the card to be free, makes sure the backend that offers [path] is running (stopping another one
  /// first), then calls [use] with its port. [backendId] picks a backend when several offer the same path.
  Future<void> useBackend(String path, String? backendId, Future<void> Function(int port) use) async {
    final specs = allSpecs().where((s) => s.enabled && s.allowedPaths.contains(path) && (backendId == null || s.id == backendId)).toList();
    if (specs.isEmpty) throw LocalApiError(404, 'No enabled backend offers $path');
    final spec = specs.first;
    await _turn.run(() async {
      _busy = true;
      _refreshState();
      final watch = Stopwatch()..start();
      var status = 200;
      try {
        final error = await _ensure(spec);
        if (error != null) {
          status = 503;
          throw LocalApiError(503, error);
        }
        await use(spec.port);
      } catch (e) {
        status = e is LocalApiError ? e.status : 502;
        rethrow;
      } finally {
        watch.stop();
        recent.insert(0, JobRecord(id: 'local', backend: spec.id, path: path, at: _clock(), millis: watch.elapsedMilliseconds, status: status));
        if (recent.length > 30) recent.removeLast();
        if (status >= 200 && status < 300) {
          jobsDone++;
          totalMillis += watch.elapsedMilliseconds;
          if (watch.elapsedMilliseconds > peakMillis) peakMillis = watch.elapsedMilliseconds;
        } else {
          jobsFailed++;
        }
        _busy = false;
        _refreshState();
      }
    });
  }

  /// Tells the screens something changed.
  void refresh() => notifyListeners();

  /// Turns the local API on or off and changes its port or network reach. A key is made the first time it is needed.
  Future<void> setLocalApi({bool? enabled, int? port, bool? lan}) async {
    if (enabled != null) config.localApiEnabled = enabled;
    if (port != null && port >= 1024 && port <= 65535) config.localApiPort = port;
    if (lan != null) config.localApiLan = lan;
    if (config.localApiKey.isEmpty) config.localApiKey = _newKey();
    await store.save(config);
    await localApi.apply();
    notifyListeners();
  }

  Future<void> regenerateLocalApiKey() async {
    config.localApiKey = _newKey();
    await store.save(config);
    notifyListeners();
  }

  static String _newKey() {
    final r = Random.secure();
    return 'glend-${List.generate(24, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<(int, List<int>)> _local(int port, String path, Uint8List body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path')).timeout(const Duration(seconds: 10));
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(const Duration(seconds: 140));
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 140))) {
        out.add(chunk);
      }
      return (response.statusCode, out.takeBytes());
    } finally {
      client.close(force: true);
    }
  }
}
