// What the app remembers on this PC, in config.json inside the data folder (%LOCALAPPDATA%\GpuLend on Windows, ~/.local/share/GpuLend
// on Linux, ~/Library/Application Support/GpuLend on macOS). The device token is stored encrypted with DPAPI on Windows (readable only by
// this Windows user on this machine) and in the owner-only settings file elsewhere; everything else is plain settings.
import 'dart:convert';
import 'dart:io';

import 'backends.dart';
import 'platform_utils.dart';

/// The settings the server also holds for this device. The server is the source of truth: it hands out a revision number and
/// the app adopts a newer one; an edit made here is sent with the revision it was based on.
class DeviceSettings {
  DeviceSettings({
    this.name = '',
    this.enabled = true,
    this.maxVram = 5.4,
    this.hourFrom = 0,
    this.hourTo = 24,
    this.acOnly = false,
    this.autostart = true,
    this.dailyMinutes = 0,
    this.dailyJobs = 0,
    this.rev = 0,
  });

  String name;
  bool enabled;
  double maxVram;
  int hourFrom;
  int hourTo;
  bool acOnly;
  bool autostart;

  /// How much this PC lends per day: minutes of graphics time and number of jobs. 0 = no limit. When either is reached lending pauses
  /// until the next day (the app counts them; the server shows them).
  int dailyMinutes;
  int dailyJobs;
  int rev;

  factory DeviceSettings.fromJson(Map<String, dynamic> j) => DeviceSettings(
        name: (j['name'] ?? '') as String,
        enabled: (j['enabled'] ?? true) as bool,
        maxVram: ((j['max_vram'] ?? 5.4) as num).toDouble(),
        hourFrom: ((j['hour_from'] ?? 0) as num).toInt(),
        hourTo: ((j['hour_to'] ?? 24) as num).toInt(),
        acOnly: (j['ac_only'] ?? false) as bool,
        autostart: (j['autostart'] ?? true) as bool,
        dailyMinutes: ((j['daily_minutes'] ?? 0) as num).toInt(),
        dailyJobs: ((j['daily_jobs'] ?? 0) as num).toInt(),
        rev: ((j['rev'] ?? 0) as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'enabled': enabled,
        'max_vram': maxVram,
        'hour_from': hourFrom,
        'hour_to': hourTo,
        'ac_only': acOnly,
        'autostart': autostart,
        'daily_minutes': dailyMinutes,
        'daily_jobs': dailyJobs,
        'rev': rev,
      };

  DeviceSettings copy() => DeviceSettings.fromJson(toJson());

  /// Is [hour] (0..23, local time on this PC) inside the working hours?
  bool inHours(int hour) {
    if (hourFrom == hourTo || (hourFrom == 0 && hourTo >= 24)) return true;
    if (hourFrom < hourTo) return hour >= hourFrom && hour < hourTo;
    return hour >= hourFrom || hour < hourTo;
  }
}

class AppConfig {
  AppConfig({
    this.serverUrl = '',
    this.directIp = '',
    this.certSha256 = '',
    this.token = '',
    this.workerId = 0,
    this.binDir = '',
    this.modelsDir = '',
    this.modelPort = 1234,
    this.localEnabled = true,
    this.lastSeenRev = 0,
    DeviceSettings? settings,
    List<String>? allowedPaths,
    this.imageEnabled = true,
    List<BackendProfile>? extraBackends,
    this.usageDay = '',
    this.usageMillis = 0,
    this.usageJobs = 0,
    Map<String, dynamic>? unpairedEdits,
    this.localApiEnabled = false,
    this.localApiPort = 8765,
    this.localApiLan = false,
    this.localApiKey = '',
  })  : settings = settings ?? DeviceSettings(),
        allowedPaths = allowedPaths ?? List.of(defaultAllowedPaths),
        extraBackends = extraBackends ?? [],
        unpairedEdits = unpairedEdits ?? {};

  /// The address of the server (https://…), the optional direct IP to dial instead of resolving it, and the
  /// pinned certificate (sha256, lowercase hex) to trust for that address.
  String serverUrl;
  String directIp;
  String certSha256;
  String token;
  int workerId;

  /// Where `sd-server.exe` and the model weights are; empty = the app's own folders.
  String binDir;
  String modelsDir;
  int modelPort;

  /// The "power" button of this PC: off means this PC lends nothing, whatever the panel says.
  bool localEnabled;
  int lastSeenRev;
  DeviceSettings settings;

  /// The request paths the server may have this PC forward to the local model. Anything else is refused, so a server can never
  /// reach other services on this machine. The defaults are stable-diffusion.cpp's sd-server; edit config.json to use another backend.
  List<String> allowedPaths;

  /// Is the picture backend (sd-server) offered? Other backends (a language model, anything else) are listed in [extraBackends].
  bool imageEnabled;
  List<BackendProfile> extraBackends;

  /// What was lent today (the day as yyyy-mm-dd on this PC), so a daily limit survives restarts.
  String usageDay;
  int usageMillis;
  int usageJobs;

  /// Settings changed on this PC before it was paired; they are sent to the server when pairing succeeds.
  Map<String, dynamic> unpairedEdits;

  /// Standalone mode: an OpenAI-style API on this PC (or this network) served by the local backends, protected by [localApiKey].
  bool localApiEnabled;
  int localApiPort;
  bool localApiLan;
  String localApiKey;
  static const defaultAllowedPaths = ['/v1/images/generations', '/sdapi/v1/img2img'];

  bool get paired => token.isNotEmpty && serverUrl.isNotEmpty;
}

class ConfigStore {
  ConfigStore({Directory? directory}) : directory = directory ?? _defaultDirectory();

  final Directory directory;

  static Directory _defaultDirectory() => appDataDir();

  File get _file => File('${directory.path}${Platform.pathSeparator}config.json');
  File get logFile => File('${directory.path}${Platform.pathSeparator}app.log');

  Future<AppConfig> load() async {
    try {
      if (!await _file.exists()) return AppConfig();
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      String token = '';
      final protectedToken = (j['token_protected'] ?? '') as String;
      if (protectedToken.isNotEmpty) {
        token = unprotectSecret(protectedToken) ?? '';
      } else if ((j['token_plain'] ?? '') is String) {
        token = (j['token_plain'] ?? '') as String;
      }
      return AppConfig(
        serverUrl: (j['server_url'] ?? '') as String,
        directIp: (j['direct_ip'] ?? '') as String,
        certSha256: (j['cert_sha256'] ?? '') as String,
        token: token,
        workerId: ((j['worker_id'] ?? 0) as num).toInt(),
        binDir: (j['bin_dir'] ?? '') as String,
        modelsDir: (j['models_dir'] ?? '') as String,
        modelPort: ((j['model_port'] ?? 1234) as num).toInt(),
        localEnabled: (j['local_enabled'] ?? true) as bool,
        lastSeenRev: ((j['last_seen_rev'] ?? 0) as num).toInt(),
        allowedPaths: ((j['allowed_paths'] ?? AppConfig.defaultAllowedPaths) as List).whereType<String>().toList(),
        imageEnabled: (j['image_enabled'] ?? true) as bool,
        extraBackends: ((j['extra_backends'] ?? const <dynamic>[]) as List).whereType<Map<String, dynamic>>().map(BackendProfile.fromJson).where((b) => BackendProfile.validId(b.id)).toList(),
        usageDay: (j['usage_day'] ?? '') as String,
        usageMillis: ((j['usage_millis'] ?? 0) as num).toInt(),
        usageJobs: ((j['usage_jobs'] ?? 0) as num).toInt(),
        unpairedEdits: Map<String, dynamic>.from((j['unpaired_edits'] ?? const <String, dynamic>{}) as Map),
        localApiEnabled: (j['local_api_enabled'] ?? false) as bool,
        localApiPort: ((j['local_api_port'] ?? 8765) as num).toInt(),
        localApiLan: (j['local_api_lan'] ?? false) as bool,
        localApiKey: (j['local_api_key'] ?? '') as String,
        settings: DeviceSettings.fromJson((j['settings'] ?? <String, dynamic>{}) as Map<String, dynamic>),
      );
    } catch (_) {
      return AppConfig();
    }
  }

  Future<void> save(AppConfig c) async {
    await directory.create(recursive: true);
    final protectedToken = c.token.isEmpty ? '' : protectSecret(c.token);
    final j = <String, dynamic>{
      'server_url': c.serverUrl,
      'direct_ip': c.directIp,
      'cert_sha256': c.certSha256,
      if (protectedToken != null) 'token_protected': protectedToken else 'token_plain': c.token,
      'worker_id': c.workerId,
      'bin_dir': c.binDir,
      'models_dir': c.modelsDir,
      'model_port': c.modelPort,
      'local_enabled': c.localEnabled,
      'last_seen_rev': c.lastSeenRev,
      'allowed_paths': c.allowedPaths,
      'image_enabled': c.imageEnabled,
      'extra_backends': c.extraBackends.map((b) => b.toJson()).toList(),
      'usage_day': c.usageDay,
      'usage_millis': c.usageMillis,
      'usage_jobs': c.usageJobs,
      'unpaired_edits': c.unpairedEdits,
      'local_api_enabled': c.localApiEnabled,
      'local_api_port': c.localApiPort,
      'local_api_lan': c.localApiLan,
      'local_api_key': c.localApiKey,
      'settings': c.settings.toJson(),
    };
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
    await tmp.rename(_file.path);
    await restrictToOwner(_file); // Linux/macOS: the file holds the token and the API key
  }
}
