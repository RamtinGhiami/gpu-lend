import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/engine.dart';
import 'dashboard_page.dart';
import 'server_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'tools_page.dart';

/// The window: a title bar that can be dragged, the left rail with the pages, and the page itself.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.engine});
  final Engine engine;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _page = 0;

  static const _items = [
    (Icons.home_rounded, 'Home'),
    (Icons.hub_rounded, 'Server'),
    (Icons.tune_rounded, 'Settings'),
    (Icons.handyman_rounded, 'Tools'),
  ];

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_notice);
  }

  @override
  void dispose() {
    widget.engine.removeListener(_notice);
    super.dispose();
  }

  void _notice() {
    final text = widget.engine.notice;
    if (text == null || !mounted) return;
    widget.engine.notice = null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text, style: const TextStyle(color: Palette.text, fontSize: 13, height: 1.35)),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(84, 0, 14, 14),
      duration: const Duration(seconds: 6),
      backgroundColor: Palette.cardHigh,
      showCloseIcon: true,
      closeIconColor: Palette.muted,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Palette.accent, width: 1)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(engine: widget.engine, goTo: (i) => setState(() => _page = i)),
      ServerPage(engine: widget.engine),
      SettingsPage(engine: widget.engine),
      ToolsPage(engine: widget.engine),
    ];
    return Scaffold(
      body: Column(children: [
        const _TitleBar(),
        Expanded(
          child: Row(children: [
            _Rail(selected: _page, items: _items, onSelect: (i) => setState(() => _page = i)),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                child: KeyedSubtree(key: ValueKey(_page), child: pages[_page]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 32,
        child: Row(children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _caption(Icons.remove_rounded, () => windowManager.minimize(), 'Minimize'),
          _caption(Icons.close_rounded, () => windowManager.hide(), 'Close to the tray', hover: Palette.danger),
        ]),
      );

  Widget _caption(IconData icon, VoidCallback onTap, String tip, {Color? hover}) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          hoverColor: hover?.withValues(alpha: 0.85) ?? Palette.cardHigh,
          child: SizedBox(width: 44, height: 32, child: Icon(icon, size: 16, color: Palette.text)),
        ),
      );
}

class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.items, required this.onSelect});
  final int selected;
  final List<(IconData, String)> items;
  final ValueChanged<int> onSelect;

  // Settings sits at the bottom of the rail, the rest at the top
  static const _bottom = 2;

  Widget _item(int i) {
    final on = i == selected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: on ? Palette.cardHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: Palette.cardHigh.withValues(alpha: 0.6),
          onTap: () => onSelect(i),
          child: Stack(alignment: Alignment.centerLeft, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(left: 1),
              width: 3,
              height: on ? 24 : 0,
              decoration: BoxDecoration(color: Palette.accent, borderRadius: BorderRadius.circular(2)),
            ),
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(items[i].$1, size: 24, color: on ? Palette.accent : Palette.muted),
                  const SizedBox(height: 4),
                  Text(items[i].$2, style: TextStyle(fontSize: 11, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? Palette.text : Palette.muted), overflow: TextOverflow.ellipsis),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
        width: 76,
        color: Palette.rail,
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < items.length; i++)
            if (i != _bottom) _item(i),
          const Spacer(),
          _item(_bottom),
        ]),
      );
}
