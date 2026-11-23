import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// A rounded card with a small header (icon and title) like the dashboard tiles of a modern desktop app.
class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.child, this.title, this.icon, this.trailing, this.onTap, this.padding = const EdgeInsets.all(14), this.background, this.backdrop});

  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final Color? background;

  /// Drawn behind everything, top right, and cut only by the card's own rounded edge (a soft glow, for example).
  final Widget? backdrop;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                if (icon != null) ...[Icon(icon, size: 16, color: Palette.muted), const SizedBox(width: 8)],
                Expanded(child: Text(title!, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Palette.muted, fontWeight: FontWeight.w600))),
                ?trailing,
                if (onTap != null && trailing == null) const Icon(Icons.chevron_right_rounded, size: 20, color: Palette.muted),
              ]),
            ),
          child,
        ],
      ),
    );
    return Material(
      color: background ?? Palette.card,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Stack(clipBehavior: Clip.none, children: [
        if (backdrop != null) Positioned(right: -50, top: -70, child: IgnorePointer(child: backdrop!)),
        onTap == null ? content : InkWell(onTap: onTap, child: content),
      ]),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.color = Palette.muted});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
      );
}

/// The big round button of the status card: a soft glow while the device is ready, a slow pulse while it works.
class PowerButton extends StatefulWidget {
  const PowerButton({super.key, required this.on, required this.busy, required this.onPressed, this.size = 112});
  final bool on;
  final bool busy;
  final VoidCallback onPressed;
  final double size;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.on ? Palette.accent : Palette.cardHigh;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final glow = widget.on ? (widget.busy ? 0.25 + 0.35 * _pulse.value : 0.30) : 0.0;
        return GestureDetector(
          onTap: widget.onPressed,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [if (glow > 0) BoxShadow(color: Palette.accent.withValues(alpha: glow), blurRadius: 36, spreadRadius: 4)],
              ),
              child: Icon(widget.on ? Icons.pause_rounded : Icons.play_arrow_rounded, size: widget.size * 0.5, color: widget.on ? Colors.white : Palette.muted),
            ),
          ),
        );
      },
    );
  }
}

/// A row of pill-shaped choices (like an "outbound mode" selector).
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, String, IconData)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final o in options)
            ChoiceChip(
              selected: o.$1 == value,
              onSelected: (_) => onChanged(o.$1),
              avatar: Icon(o.$3, size: 18, color: o.$1 == value ? Colors.white : Palette.muted),
              label: Text(o.$2),
              labelStyle: TextStyle(fontWeight: FontWeight.w600, color: o.$1 == value ? Colors.white : Palette.muted),
              backgroundColor: Palette.cardHigh,
              selectedColor: Palette.accent,
              side: BorderSide.none,
              showCheckmark: false,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
        ],
      );
}

/// A label with a short explanation and a switch, for the settings lists.
class ToggleTile extends StatelessWidget {
  const ToggleTile({super.key, required this.title, this.subtitle, required this.value, required this.onChanged, this.icon, this.compact = false});
  /// Stacked (icon and switch on one line, the words under them) for a narrow card.
  final bool compact;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) Icon(icon, size: 22, color: value ? Palette.accent : Palette.muted),
          const Spacer(),
          Transform.scale(scale: 0.85, alignment: Alignment.centerRight, child: Switch(value: value, onChanged: onChanged)),
        ]),
        const SizedBox(height: 2),
        Text(title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      ]);
    }
    return _row(context);
  }

  Widget _row(BuildContext context) => Row(children: [
        if (icon != null)
          Container(
            width: 44,
            height: 44,
            margin: const EdgeInsetsDirectional.only(end: 14),
            decoration: BoxDecoration(color: Palette.cardHigh, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, size: 22, color: value ? Palette.accent : Palette.muted),
          ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        Switch(value: value, onChanged: onChanged),
      ]);
}

/// A thin bar for VRAM and similar meters.
class MeterBar extends StatelessWidget {
  const MeterBar({super.key, required this.fraction, this.color = Palette.accent});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(value: fraction.clamp(0.0, 1.0), minHeight: 8, color: color, backgroundColor: Palette.cardHigh),
      );
}

/// A soft blurred blob drawn behind the status card, like the shapes in a modern dashboard.
class Blob extends StatelessWidget {
  const Blob({super.key, required this.color, this.size = 220});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(size, size), painter: _BlobPainter(color));
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 70);
    final path = Path();
    const points = 9;
    for (var i = 0; i <= points; i++) {
      final angle = i / points * math.pi * 2;
      final radius = size.width / 2 * (0.78 + 0.16 * math.sin(angle * 3 + 1.2));
      final p = Offset(size.width / 2 + radius * math.cos(angle), size.height / 2 + radius * math.sin(angle));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path..close(), paint);
  }

  @override
  bool shouldRepaint(covariant _BlobPainter old) => old.color != color;
}

String formatDuration(Duration d) {
  if (d.inSeconds < 1) return '${d.inMilliseconds} ms';
  if (d.inMinutes < 1) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  return '${d.inMinutes} min ${d.inSeconds % 60} s';
}

String formatAgo(DateTime? t, DateTime now) {
  if (t == null) return 'never';
  final d = now.difference(t);
  if (d.inSeconds < 5) return 'just now';
  if (d.inSeconds < 60) return '${d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// A list that scrolls smoothly with the mouse wheel: each wheel step glides to its target with an ease-out curve (and steps that
/// arrive while gliding add up) instead of jumping by a fixed amount.
class SmoothList extends StatefulWidget {
  const SmoothList({super.key, required this.children, this.padding = EdgeInsets.zero});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  State<SmoothList> createState() => _SmoothListState();
}

class _SmoothListState extends State<SmoothList> {
  final ScrollController _controller = ScrollController();
  double? _target;
  int _token = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _wheel(PointerScrollEvent event) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final from = _target ?? position.pixels;
    final to = (from + event.scrollDelta.dy * 1.4).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if (to == position.pixels && _target == null) return;
    _target = to;
    final mine = ++_token;
    _controller
        .animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic)
        .whenComplete(() {
      if (mine == _token) _target = null;
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(event, (e) => _wheel(e as PointerScrollEvent));
          }
        },
        // no scrollbar: the mouse wheel scrolls
        child: ListView(
          controller: _controller,
          physics: const NeverScrollableScrollPhysics(),
          padding: widget.padding,
          children: widget.children,
        ),
      );
}
