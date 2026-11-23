import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import 'gpu_chart.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Availability { always, night, mains }

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.engine, required this.goTo});
  final Engine engine;
  final ValueChanged<int> goTo;

  static (String, Color) describe(Engine e) {
    switch (e.state) {
      case DeviceState.unpaired:
        return ('Standalone', Palette.muted);
      case DeviceState.revoked:
        return ('Removed from the panel', Palette.danger);
      case DeviceState.offline:
        return ('Server unreachable', Palette.warn);
      case DeviceState.paused:
        return ('Paused', Palette.warn);
      case DeviceState.startingModel:
        return ('Loading the model…', Palette.accent);
      case DeviceState.missingFiles:
        return ('Model files missing', Palette.danger);
      case DeviceState.ready:
        return ('Ready', Palette.ok);
      case DeviceState.working:
        return ('Working', Palette.accent);
    }
  }

  _Availability _mode(Engine e) {
    final s = e.config.settings;
    if (s.acOnly) return _Availability.mains;
    if (!(s.hourFrom == 0 && s.hourTo >= 24)) return _Availability.night;
    return _Availability.always;
  }

  void _setMode(_Availability m) {
    switch (m) {
      case _Availability.always:
        engine.edit({'hour_from': 0, 'hour_to': 24, 'ac_only': false});
      case _Availability.night:
        engine.edit({'hour_from': 22, 'hour_to': 7, 'ac_only': false});
      case _Availability.mains:
        engine.edit({'hour_from': 0, 'hour_to': 24, 'ac_only': true});
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: engine,
        builder: (context, _) {
          Widget gap(Widget w) => Padding(padding: const EdgeInsets.only(bottom: 10), child: w);
          Widget pair(Widget l, Widget r) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: l), const SizedBox(width: 10), Expanded(child: r)])),
              );
          return SmoothList(padding: const EdgeInsets.fromLTRB(12, 4, 12, 14), children: [
            gap(_statusCard(context)),
            gap(_localApiCard(context)),
            pair(_jobsCard(context), _timeCard(context)),
            gap(_availabilityCard(context)),
            pair(_gpuCard(context), _serverCard(context)),
            gap(_chartCard(context)),
            pair(_signInCard(context), _batteryCard(context)),
            gap(_modelCard(context)),
            _recentCard(context),
          ]);
        },
      );

  // ---------------------------------------------------------------------------------------------------- cards

  Widget _statusCard(BuildContext context) {
    final (label, color) = describe(engine);
    final s = engine.config.settings;
    final busy = engine.state == DeviceState.working || engine.state == DeviceState.startingModel;
    final on = engine.config.localEnabled && engine.config.paired;
    return InfoCard(
      title: 'Status',
      icon: Icons.bolt_rounded,
      trailing: StatusPill(label, color: color),
      backdrop: Blob(color: color.withValues(alpha: 0.16), size: 200),
      child: SizedBox(
          height: 92,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(engine.config.paired ? (s.name.isEmpty ? 'This PC' : s.name) : 'Standalone', style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Text(_statusLine(), style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                if (!engine.config.paired) FilledButton(onPressed: () => goTo(1), child: const Text('Pair with a server')),
              ]),
            ),
            if (engine.config.paired) PowerButton(size: 72, on: on, busy: busy, onPressed: () => engine.setLocalEnabled(!engine.config.localEnabled)),
          ]),
        ),
    );
  }

  Widget _localApiCard(BuildContext context) {
    final c = engine.config;
    final api = engine.localApi;
    final text = Theme.of(context).textTheme;
    Widget copyRow(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            SizedBox(width: 62, child: Text(label, style: text.bodySmall)),
            Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12.5, fontFamily: 'Consolas'), maxLines: 1)),
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded, size: 16, color: Palette.muted),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
          ]),
        );
    return InfoCard(
      title: 'Local API',
      icon: Icons.api_rounded,
      trailing: StatusPill(api.running ? 'On' : 'Off', color: api.running ? Palette.ok : Palette.muted),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ToggleTile(
          title: 'Serve the models to my programs',
          subtitle: 'OpenAI-style API, no server needed',
          value: c.localApiEnabled,
          onChanged: (v) => engine.setLocalApi(enabled: v),
        ),
        if (api.error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(api.error!, style: const TextStyle(color: Palette.danger, fontSize: 12.5))),
        if (c.localApiEnabled) ...[
          copyRow('Address', api.baseUrl),
          copyRow('API key', c.localApiKey),
          const SizedBox(height: 4),
          ToggleTile(
            title: 'Allow other devices on my network',
            subtitle: c.localApiLan ? 'Reachable on port ${c.localApiPort} from your network' : 'Only this PC can connect',
            value: c.localApiLan,
            onChanged: (v) => engine.setLocalApi(lan: v),
          ),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: engine.regenerateLocalApiKey, child: const Text('New API key'))),
        ],
      ]),
    );
  }

  String _statusLine() {
    switch (engine.state) {
      case DeviceState.unpaired:
        return 'Not connected to a server. Use the local API below, or pair with a server to lend the card.';
      case DeviceState.revoked:
        return 'The administrator removed this device. Pair again with a new code.';
      case DeviceState.offline:
        return engine.serverError ?? 'The server cannot be reached.';
      case DeviceState.paused:
        return engine.detail.isEmpty ? 'Lending is paused.' : engine.detail;
      case DeviceState.startingModel:
        return 'Starting the image model on the graphics card.';
      case DeviceState.missingFiles:
        return engine.detail;
      case DeviceState.ready:
        return 'Waiting for the next picture. Press the button to pause.';
      case DeviceState.working:
        return 'Drawing a picture for a designer.';
    }
  }

  Widget _jobsCard(BuildContext context) => InfoCard(
        title: 'Jobs done',
        icon: Icons.task_alt_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${engine.jobsDone}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          Text('failed ${engine.jobsFailed}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(_todayLine(), style: Theme.of(context).textTheme.bodySmall),
        ]),
      );

  String _todayLine() {
    final s = engine.config.settings;
    final minutes = s.dailyMinutes > 0 ? '${engine.usedMinutesToday} of ${s.dailyMinutes} min' : '${engine.usedMinutesToday} min';
    final jobs = s.dailyJobs > 0 ? '${engine.usedJobsToday} of ${s.dailyJobs} jobs' : '${engine.usedJobsToday} jobs';
    return 'Today: $minutes · $jobs';
  }

  Widget _timeCard(BuildContext context) => InfoCard(
        title: 'Average time',
        icon: Icons.timer_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(engine.jobsDone == 0 ? '—' : formatDuration(engine.averageJob), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          Text(engine.peakMillis == 0 ? 'slowest —' : 'slowest ${formatDuration(Duration(milliseconds: engine.peakMillis))}', style: Theme.of(context).textTheme.bodySmall),
        ]),
      );

  Widget _availabilityCard(BuildContext context) {
    final s = engine.config.settings;
    final detail = switch (_mode(engine)) {
      _Availability.always => 'Lends the graphics card at any hour.',
      _Availability.night => 'Only from ${s.hourFrom}:00 to ${s.hourTo}:00 (local time).',
      _Availability.mains => 'Only while the laptop is plugged in.',
    };
    return InfoCard(
      title: 'When to lend',
      icon: Icons.schedule_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Segmented<_Availability>(
          value: _mode(engine),
          options: const [
            (_Availability.always, 'Always', Icons.all_inclusive_rounded),
            (_Availability.night, 'At night', Icons.nightlight_round),
            (_Availability.mains, 'On mains only', Icons.power_rounded),
          ],
          onChanged: _setMode,
        ),
        const SizedBox(height: 8),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  Widget _signInCard(BuildContext context) => InfoCard(
        child: ToggleTile(
          compact: true,
          icon: Icons.rocket_launch_rounded,
          title: 'Run at sign-in',
          subtitle: 'Starts with Windows',
          value: engine.config.settings.autostart,
          onChanged: (v) => engine.edit({'autostart': v}),
        ),
      );

  Widget _batteryCard(BuildContext context) => InfoCard(
        child: ToggleTile(
          compact: true,
          icon: Icons.battery_charging_full_rounded,
          title: 'Pause on battery',
          subtitle: 'Mains only',
          value: engine.config.settings.acOnly,
          onChanged: (v) => engine.edit({'ac_only': v}),
        ),
      );

  Widget _gpuCard(BuildContext context) {
    final g = engine.gpu;
    return InfoCard(
      title: 'Graphics card',
      icon: Icons.memory_rounded,
      child: g == null
          ? Text('No NVIDIA card found', style: Theme.of(context).textTheme.bodySmall)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(g.name.replaceAll('NVIDIA GeForce ', ''), style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              MeterBar(fraction: g.fraction, color: g.fraction > 0.9 ? Palette.warn : Palette.accent),
              const SizedBox(height: 8),
              Text('${(g.usedMb / 1024).toStringAsFixed(1)} / ${(g.totalMb / 1024).toStringAsFixed(1)} GB',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
    );
  }

  Widget _serverCard(BuildContext context) {
    final uri = Uri.tryParse(engine.config.serverUrl);
    return InfoCard(
      title: 'Server',
      icon: Icons.cloud_rounded,
      onTap: () => goTo(1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(engine.config.paired ? (uri?.host ?? engine.config.serverUrl) : 'Not paired', style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        Text(engine.config.paired ? 'Last contact ${formatAgo(engine.lastContact, DateTime.now())}' : 'Pair to start', style: Theme.of(context).textTheme.bodySmall),
        if (engine.config.directIp.isNotEmpty) Text('Direct to ${engine.config.directIp}', style: Theme.of(context).textTheme.bodySmall),
        if (engine.config.certSha256.isNotEmpty) Text('Certificate pinned', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  Widget _modelCard(BuildContext context) => InfoCard(
        title: 'Workloads',
        icon: Icons.auto_awesome_rounded,
        onTap: () => goTo(2),
        child: engine.backends.isEmpty
            ? Text('Checking…', style: Theme.of(context).textTheme.bodySmall)
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final b in engine.backends)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Icon(Icons.circle, size: 10, color: !b.enabled ? Palette.cardHigh : (b.listening ? Palette.ok : (b.missing.isEmpty ? Palette.muted : Palette.danger))),
                      const SizedBox(width: 10),
                      Expanded(child: Text(b.name, style: Theme.of(context).textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
                      Text(!b.enabled ? 'off' : (b.listening ? (engine.activeBackend == b.id ? 'loaded' : 'running') : (b.missing.isEmpty ? 'ready' : 'missing')), style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
              ]),
      );

  Widget _chartCard(BuildContext context) {
    final g = engine.gpu;
    final cap = engine.config.settings.maxVram;
    final totalGb = g == null || g.totalMb == 0 ? null : g.totalMb / 1024;
    final limitPercent = totalGb == null ? null : (cap / totalGb * 100).clamp(0.0, 100.0).toDouble();
    return InfoCard(
      title: 'GPU usage',
      icon: Icons.show_chart_rounded,
            child: engine.gpuHistory.isEmpty
          ? Padding(padding: const EdgeInsets.symmetric(vertical: 28), child: Center(child: Text(g == null ? 'No NVIDIA graphics card was found.' : 'Collecting readings…', style: Theme.of(context).textTheme.bodySmall)))
          : GpuChart(
              height: 110,
              samples: List.of(engine.gpuHistory),
              limitPercent: limitPercent,
              limitLabel: limitPercent == null ? '' : '${cap.toStringAsFixed(1)} GB (${limitPercent.round()}%)',
            ),
    );
  }

  Widget _recentCard(BuildContext context) => InfoCard(
        title: 'Recent jobs',
        icon: Icons.history_rounded,
        child: engine.recent.isEmpty
            ? Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('Nothing yet. Jobs done for the server appear here.', style: Theme.of(context).textTheme.bodySmall)))
            : Column(children: [
                for (final j in engine.recent.take(4))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Icon(j.ok ? Icons.check_circle_rounded : Icons.error_rounded, size: 18, color: j.ok ? Palette.ok : Palette.danger),
                      const SizedBox(width: 12),
                      SizedBox(width: 70, child: Text('${j.at.hour.toString().padLeft(2, '0')}:${j.at.minute.toString().padLeft(2, '0')}:${j.at.second.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.bodySmall)),
                      Expanded(child: Text(j.backend == 'image' ? (j.path == '/sdapi/v1/img2img' ? 'Redraw a picture' : 'New picture') : '${j.backend} request', style: Theme.of(context).textTheme.bodyMedium)),
                      Text(formatDuration(Duration(milliseconds: j.millis)), style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
              ]),
      );
}
