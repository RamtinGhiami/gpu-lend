import 'dart:async';

import 'package:flutter/material.dart';

import '../core/backends.dart';
import '../core/engine.dart';
import '../core/platform_utils.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.engine});
  final Engine engine;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name = TextEditingController(text: widget.engine.config.settings.name);
  late final TextEditingController _bin = TextEditingController(text: widget.engine.config.binDir);
  late final TextEditingController _models = TextEditingController(text: widget.engine.config.modelsDir);
  late final TextEditingController _port = TextEditingController(text: '${widget.engine.config.modelPort}');
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _bin.dispose();
    _models.dispose();
    _port.dispose();
    super.dispose();
  }

  void _later(VoidCallback f) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), f);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.engine,
        builder: (context, _) {
          final e = widget.engine;
          final s = e.config.settings;
          final paired = e.config.paired;
          if (paired && _name.text != s.name && !FocusScope.of(context).hasFocus) _name.text = s.name;
          return SmoothList(padding: const EdgeInsets.fromLTRB(28, 8, 28, 28), children: [
            Padding(padding: const EdgeInsets.only(bottom: 18), child: Text('Settings', style: Theme.of(context).textTheme.headlineMedium)),
            if (!paired)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InfoCard(child: Row(children: [const Icon(Icons.info_outline_rounded, color: Palette.muted), const SizedBox(width: 12), Expanded(child: Text('These settings are shared with the panel once this PC is paired.', style: Theme.of(context).textTheme.bodySmall))])),
              ),
            InfoCard(
              title: 'Device',
              icon: Icons.laptop_rounded,
              trailing: paired ? const StatusPill('Synced with the panel', color: Palette.ok) : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _name,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Device name', counterText: ''),
                  onChanged: (v) => _later(() => e.edit({'name': v.trim().isEmpty ? 'My PC' : v.trim()})),
                ),
                const SizedBox(height: 18),
                ToggleTile(icon: Icons.power_settings_new_rounded, title: 'Lend this PC', subtitle: 'Off here or in the panel pauses lending', value: s.enabled, onChanged: (v) => e.edit({'enabled': v})),
                const SizedBox(height: 14),
                ToggleTile(icon: Icons.rocket_launch_rounded, title: 'Run at Windows sign-in', subtitle: 'Starts minimised in the tray', value: s.autostart, onChanged: (v) => e.edit({'autostart': v})),
              ]),
            ),
            const SizedBox(height: 16),
            InfoCard(
              title: 'Limits',
              icon: Icons.speed_rounded,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _vramSlider(context, s.maxVram, paired),
                const SizedBox(height: 18),
                Row(children: [
                  Text('Working hours (local time)', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  _hourPick(context, s.hourFrom, 0, 23, (v) => e.edit({'hour_from': v})),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('to')),
                  _hourPick(context, s.hourTo, 0, 24, (v) => e.edit({'hour_to': v})),
                ]),
                const SizedBox(height: 4),
                Text('0 to 24 means all day; 22 to 7 means overnight.', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 18),
                Text('Daily limit', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('How much this PC lends per day. Lending pauses when either limit is reached and resumes tomorrow. 0 means no limit.', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _limitField('Minutes of graphics time', s.dailyMinutes, (v) => e.edit({'daily_minutes': v}))),
                  const SizedBox(width: 14),
                  Expanded(child: _limitField('Number of jobs', s.dailyJobs, (v) => e.edit({'daily_jobs': v}))),
                ]),
                const SizedBox(height: 10),
                _todayBar(context),
                const SizedBox(height: 18),
                ToggleTile(icon: Icons.battery_charging_full_rounded, title: 'Only on mains power', subtitle: 'Pause while running on battery', value: s.acOnly, onChanged: (v) => e.edit({'ac_only': v})),
              ]),
            ),
            const SizedBox(height: 16),
            _workloads(context),
          ]);
        },
      );

  /// The most graphics memory this PC has, from the card itself (nvidia-smi); 24 GB when it cannot be read.
  double _cardGb() {
    final g = widget.engine.gpu;
    if (g == null || g.totalMb <= 0) return 24;
    return (g.totalMb / 1024 * 10).round() / 10;
  }

  /// How much of the card is lent: from 0 to everything the card has. 0 lends nothing.
  Widget _vramSlider(BuildContext context, double value, bool paired) {
    final e = widget.engine;
    final max = _cardGb();
    if (value > max) {
      // an older setting (or a larger card before): keep it inside what this card has
      WidgetsBinding.instance.addPostFrameCallback((_) => e.edit({'max_vram': max}));
    }
    final shown = value.clamp(0.0, max).toDouble();
    final suggested = ((max * 0.9) * 10).round() / 10;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Graphics memory to lend: ${shown.toStringAsFixed(1)} of ${max.toStringAsFixed(1)} GB', style: Theme.of(context).textTheme.titleMedium)),
        TextButton(onPressed: () => e.edit({'max_vram': max}), child: const Text('All')),
        TextButton(onPressed: () => e.edit({'max_vram': suggested}), child: Text('Suggested ${suggested.toStringAsFixed(1)}')),
      ]),
      Slider(
        value: shown,
        min: 0,
        max: max,
        divisions: (max * 10).round().clamp(1, 1000),
        label: '${shown.toStringAsFixed(1)} GB',
        onChanged: (v) => e.edit({'max_vram': double.parse(v.toStringAsFixed(1))}),
      ),
      Text(
        shown == 0
            ? 'Nothing is lent: this PC stays paused until you give it some memory.'
            : 'The image or language model is started with this ceiling (applied the next time it starts). The rest of the card stays yours.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }

  Widget _limitField(String label, int value, ValueChanged<int>? onChanged) {
    return TextFormField(
      key: ValueKey('$label-$value'),
      initialValue: value == 0 ? '' : '$value',
      enabled: onChanged != null,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, hintText: 'No limit'),
      onChanged: (v) => _later(() => onChanged?.call(int.tryParse(v.trim()) ?? 0)),
    );
  }

  Widget _todayBar(BuildContext context) {
    final e = widget.engine;
    final s = e.config.settings;
    Widget bar(String text, int used, int limit) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(limit > 0 ? '$text: $used of $limit today' : '$text: $used today (no limit)', style: Theme.of(context).textTheme.bodySmall),
            if (limit > 0) Padding(padding: const EdgeInsets.only(top: 4), child: MeterBar(fraction: used / limit, color: used >= limit ? Palette.warn : Palette.accent)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar('Graphics time (min)', e.usedMinutesToday, s.dailyMinutes), bar('Jobs', e.usedJobsToday, s.dailyJobs)]);
  }

  Widget _workloads(BuildContext context) {
    final e = widget.engine;
    final specsById = {for (final b in e.backends) b.id: b};
    Widget row(String id, String title, String subtitle, bool enabled, ValueChanged<bool> onToggle, {VoidCallback? onEdit, VoidCallback? onRemove}) {
      final b = specsById[id];
      final color = b == null ? Palette.muted : (b.listening ? Palette.ok : (b.missing.isEmpty ? Palette.muted : Palette.danger));
      final state = b == null ? '' : (b.listening ? 'Running' : (b.missing.isEmpty ? 'Ready to start' : 'Missing: ${b.missing.join(', ')}'));
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(Icons.circle, size: 10, color: enabled ? color : Palette.cardHigh),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              if (enabled && state.isNotEmpty) Text(state, style: TextStyle(fontSize: 12, color: color)),
            ]),
          ),
          if (onEdit != null) IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_rounded, size: 20, color: Palette.muted), tooltip: 'Edit'),
          if (onRemove != null) IconButton(onPressed: onRemove, icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Palette.muted), tooltip: 'Remove'),
          Switch(value: enabled, onChanged: onToggle),
        ]),
      );
    }

    return InfoCard(
      title: 'Workloads',
      icon: Icons.auto_awesome_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('What this PC can run for the server. Backends start when a job asks for them; only one is kept loaded at a time.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        row('image', 'Images', 'stable-diffusion.cpp (sd-server) on port ${e.config.modelPort}', e.config.imageEnabled, (v) => e.setLocal(imageEnabled: v)),
        Padding(
          padding: const EdgeInsets.only(left: 22, bottom: 6),
          child: Column(children: [
            TextField(controller: _bin, decoration: InputDecoration(labelText: 'Folder with ${exeName('sd-server')}', hintText: 'Default: the app\'s own folder'), onChanged: (v) => _later(() => e.setLocal(binDir: v.trim()))),
            const SizedBox(height: 10),
            TextField(controller: _models, decoration: const InputDecoration(labelText: 'Folder with the image model files', hintText: 'Default: the app\'s own folder'), onChanged: (v) => _later(() => e.setLocal(modelsDir: v.trim()))),
            const SizedBox(height: 10),
            TextField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Image model port on this PC'),
              keyboardType: TextInputType.number,
              onChanged: (v) => _later(() {
                final p = int.tryParse(v.trim());
                if (p != null && p > 1023 && p < 65536) e.setLocal(port: p);
              }),
            ),
            const SizedBox(height: 10),
            _files(context),
          ]),
        ),
        const Divider(height: 28),
        for (final p in e.config.extraBackends)
          row(p.id, p.name, '${p.kind == 'llama' ? 'llama.cpp' : 'Custom'} on port ${p.port} · answers ${p.allowedPaths.length} paths', p.enabled, (v) {
            p.enabled = v;
            e.saveBackend(p);
          }, onEdit: () => _editBackend(p), onRemove: () => e.removeBackend(p.id)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          OutlinedButton.icon(onPressed: () => _editBackend(BackendProfile.llama(), isNew: true), icon: const Icon(Icons.chat_rounded), label: const Text('Add a language model')),
          OutlinedButton.icon(onPressed: () => _editBackend(BackendProfile(id: '', name: '', kind: 'custom', port: 1236, args: const ['--port', '{port}']), isNew: true), icon: const Icon(Icons.add_rounded), label: const Text('Add another backend')),
          OutlinedButton.icon(onPressed: e.restartModel, icon: const Icon(Icons.restart_alt_rounded), label: const Text('Restart backends')),
        ]),
      ]),
    );
  }

  Future<void> _editBackend(BackendProfile profile, {bool isNew = false}) async {
    final saved = await showDialog<BackendProfile>(context: context, builder: (context) => _BackendDialog(profile: profile, isNew: isNew));
    if (saved == null || !mounted) return;
    final error = await widget.engine.saveBackend(saved);
    if (error != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), behavior: SnackBarBehavior.floating, backgroundColor: Palette.cardHigh));
  }

  Widget _hourPick(BuildContext context, int value, int min, int max, ValueChanged<int>? onChanged) => DropdownButtonHideUnderline(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: Palette.cardHigh, borderRadius: BorderRadius.circular(14)),
          child: DropdownButton<int>(
            value: value.clamp(min, max),
            dropdownColor: Palette.cardHigh,
            borderRadius: BorderRadius.circular(14),
            items: [for (var h = min; h <= max; h++) DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00'))],
            onChanged: onChanged == null ? null : (v) => v == null ? null : onChanged(v),
          ),
        ),
      );

  Widget _files(BuildContext context) {
    final f = widget.engine.files;
    if (f == null) return Text('Checking the files…', style: Theme.of(context).textTheme.bodySmall);
    Widget row(String name, String? path) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(path != null ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 16, color: path != null ? Palette.ok : Palette.danger),
            const SizedBox(width: 10),
            Expanded(child: Text(name, style: Theme.of(context).textTheme.bodyMedium)),
          ]),
        );
    return Column(children: [row(exeName('sd-server'), f.exe), row('z_image_turbo-Q4_K.gguf', f.diffusion), row('ae.safetensors', f.vae), row('Qwen3-4B-Instruct-2507-Q4_K_M.gguf', f.llm)]);
  }
}

/// Edits one extra backend: a llama.cpp language model (program, model file, port) or a custom program (id, command line, port, paths).
class _BackendDialog extends StatefulWidget {
  const _BackendDialog({required this.profile, required this.isNew});
  final BackendProfile profile;
  final bool isNew;

  @override
  State<_BackendDialog> createState() => _BackendDialogState();
}

class _BackendDialogState extends State<_BackendDialog> {
  late final BackendProfile p = BackendProfile.fromJson(widget.profile.toJson());
  late final _id = TextEditingController(text: p.id);
  late final _name = TextEditingController(text: p.name);
  late final _exe = TextEditingController(text: p.exe);
  late final _model = TextEditingController(text: p.modelFile);
  late final _port = TextEditingController(text: '${p.port}');
  late final _args = TextEditingController(text: p.args.join(' '));
  late final _health = TextEditingController(text: p.healthPath);
  late final _paths = TextEditingController(text: p.allowedPaths.join('\n'));
  String? _error;

  bool get _llama => p.kind == 'llama';

  @override
  void dispose() {
    for (final c in [_id, _name, _exe, _model, _port, _args, _health, _paths]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_port.text.trim());
    if (port == null) return setState(() => _error = 'The port must be a number.');
    p
      ..exe = _exe.text.trim()
      ..port = port;
    if (_llama) {
      p.modelFile = _model.text.trim();
    } else {
      p
        ..id = _id.text.trim()
        ..name = _name.text.trim().isEmpty ? _id.text.trim() : _name.text.trim()
        ..args = _args.text.trim().split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList()
        ..healthPath = _health.text.trim().isEmpty ? '/' : _health.text.trim()
        ..allowedPaths = _paths.text.split(RegExp(r'[\s,]+')).where((a) => a.startsWith('/')).toList();
      if (p.allowedPaths.isEmpty) return setState(() => _error = 'List at least one request path the server may call, for example /v1/chat/completions.');
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: Palette.card,
        title: Text(_llama ? 'Language model (llama.cpp)' : 'Backend'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!_llama) ...[
                TextField(controller: _id, enabled: widget.isNew, decoration: const InputDecoration(labelText: 'Id the server asks for', hintText: 'for example llm, speech, video')),
                const SizedBox(height: 12),
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 12),
              ],
              TextField(controller: _exe, decoration: InputDecoration(labelText: _llama ? 'Path to ${exeName('llama-server')}' : 'Path to the program')),
              const SizedBox(height: 12),
              if (_llama) ...[
                TextField(controller: _model, decoration: const InputDecoration(labelText: 'Path to the model file (.gguf)')),
                const SizedBox(height: 12),
              ] else ...[
                TextField(controller: _args, decoration: const InputDecoration(labelText: 'Arguments', hintText: '--port {port} -m {model}')),
                const SizedBox(height: 12),
                TextField(controller: _health, decoration: const InputDecoration(labelText: 'Health path')),
                const SizedBox(height: 12),
                TextField(controller: _paths, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Request paths the server may call (one per line)')),
                const SizedBox(height: 12),
              ],
              TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Local port')),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Palette.danger))),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: _save, child: const Text('Save'))],
      );
}
