import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import 'theme.dart';
import 'widgets.dart';

class ServerPage extends StatefulWidget {
  const ServerPage({super.key, required this.engine});
  final Engine engine;

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  final _text = TextEditingController();
  final _url = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _text.text = data!.text!.trim());
  }

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final e = await widget.engine.pair(_text.text, serverUrl: _url.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e;
      if (e == null) _text.clear();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.engine,
        builder: (context, _) {
          final c = widget.engine.config;
          return SmoothList(padding: const EdgeInsets.fromLTRB(28, 8, 28, 28), children: [
            Padding(padding: const EdgeInsets.only(bottom: 18), child: Text('Server', style: Theme.of(context).textTheme.headlineMedium)),
            if (c.paired) _pairedCard(context) else _pairCard(context),
          ]);
        },
      );

  Widget _pairCard(BuildContext context) => InfoCard(
        title: 'Pair with the server',
        icon: Icons.link_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'In the admin panel of your server add a device and paste the pairing text here. The code is valid for 15 minutes and works once.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Pairing text or 8-letter code',
              suffixIcon: IconButton(icon: const Icon(Icons.content_paste_rounded), tooltip: 'Paste', onPressed: _paste),
            ),
          ),
          const SizedBox(height: 12),
          TextField(controller: _url, decoration: const InputDecoration(labelText: 'Server address (only when you typed a bare code)', hintText: 'https://your-server.example')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [const Icon(Icons.error_outline_rounded, color: Palette.danger, size: 18), const SizedBox(width: 8), Expanded(child: Text(_error!, style: const TextStyle(color: Palette.danger)))]),
            ),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: _busy ? null : _pair, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link_rounded), label: const Text('Pair')),
        ]),
      );

  Widget _pairedCard(BuildContext context) {
    final e = widget.engine;
    final c = e.config;
    final (label, color) = (e.state == DeviceState.offline) ? ('Server unreachable', Palette.warn) : ('Connected', Palette.ok);
    Widget line(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 150, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
            Expanded(child: SelectableText(v, style: Theme.of(context).textTheme.bodyMedium)),
          ]),
        );
    return Column(children: [
      InfoCard(
        title: 'This device',
        icon: Icons.devices_rounded,
        trailing: StatusPill(label, color: color),
        child: Column(children: [
          line('Name', c.settings.name),
          line('Address', c.serverUrl),
          if (c.directIp.isNotEmpty) line('Direct IP', c.directIp),
          if (c.certSha256.isNotEmpty) line('Pinned certificate', c.certSha256.length > 24 ? '${c.certSha256.substring(0, 24)}…' : c.certSha256),
          line('Device id', '${c.workerId}'),
          line('Last contact', formatAgo(e.lastContact, DateTime.now())),
          if (e.serverError != null && e.serverError != 'revoked') line('Problem', e.serverError!),
        ]),
      ),
      const SizedBox(height: 16),
      InfoCard(
        title: 'Disconnect',
        icon: Icons.link_off_rounded,
        child: Row(children: [
          Expanded(child: Text('Forget the server on this PC. The device stays in the panel until the administrator removes it.', style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(width: 16),
          OutlinedButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: Palette.card,
                  title: const Text('Disconnect this PC?'),
                  content: const Text('It will stop lending its graphics card until it is paired again.'),
                  actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect'))],
                ),
              );
              if (ok == true) await e.unpair();
            },
            child: const Text('Disconnect'),
          ),
        ]),
      ),
    ]);
  }
}
