import 'dart:io';

import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/platform_utils.dart';
import 'theme.dart';
import 'widgets.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key, required this.engine});
  final Engine engine;

  Future<void> _open(String path) => openFolder(path);

  Future<void> _openFile(String path) => openFile(path);

  @override
  Widget build(BuildContext context) {
    Widget tool(IconData icon, String title, String subtitle, VoidCallback onTap) => InfoCard(
          onTap: onTap,
          child: Row(children: [
            Container(width: 46, height: 46, decoration: BoxDecoration(color: Palette.cardHigh, borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: Palette.accent)),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.titleMedium), Text(subtitle, style: Theme.of(context).textTheme.bodySmall)])),
            const Icon(Icons.chevron_right_rounded, color: Palette.muted),
          ]),
        );
    final dir = engine.store.directory.path;
    return SmoothList(padding: const EdgeInsets.fromLTRB(28, 8, 28, 28), children: [
      Padding(padding: const EdgeInsets.only(bottom: 18), child: Text('Tools', style: Theme.of(context).textTheme.headlineMedium)),
      tool(Icons.folder_open_rounded, 'Open the data folder', dir, () => _open(dir)),
      const SizedBox(height: 12),
      tool(Icons.article_rounded, 'App log', 'What the app did and any problems', () => _openFile(engine.store.logFile.path)),
      const SizedBox(height: 12),
      tool(Icons.terminal_rounded, 'Model log', 'Output of the image model (sd-server)', () => _openFile('$dir${Platform.pathSeparator}model.log')),
      const SizedBox(height: 12),
      tool(Icons.restart_alt_rounded, 'Restart the image model', 'Stops and starts it again', engine.restartModel),
      const SizedBox(height: 20),
      InfoCard(
        title: 'About',
        icon: Icons.info_outline_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('GPU Lend ${engine.version}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Runs AI models on this PC\'s graphics card and either serves them to your own programs (the local API) or lends them to a server you run (the app dials out, so no port needs to be opened).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    ]);
  }
}
