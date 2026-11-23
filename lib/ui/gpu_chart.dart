import 'package:flutter/material.dart';

import '../core/system_info.dart';
import 'theme.dart';

/// A live line chart of the graphics card: how busy it is (percent), how much of its memory is in use (percent of the card), and the
/// ceiling this PC lends (a dashed line). The newest sample is on the right; hover to read the values at a moment.
class GpuChart extends StatefulWidget {
  const GpuChart({super.key, required this.samples, required this.limitPercent, required this.limitLabel, this.height = 190});

  final List<GpuSample> samples;

  /// The lend ceiling as a percent of the card's memory (null when the card is unknown).
  final double? limitPercent;
  final String limitLabel;
  final double height;

  @override
  State<GpuChart> createState() => _GpuChartState();
}

class _GpuChartState extends State<GpuChart> {
  double? _hoverX; // 0..1 across the plot

  static const _util = Palette.accent;
  static const _vram = Color(0xFFB58CFF);
  static const _limit = Palette.warn;

  @override
  Widget build(BuildContext context) {
    final s = widget.samples;
    final last = s.isEmpty ? null : s.last;
    GpuSample? hovered;
    if (_hoverX != null && s.isNotEmpty) {
      hovered = s[(_hoverX! * (s.length - 1)).round().clamp(0, s.length - 1)];
    }
    final shown = hovered ?? last;
    Widget legend(Color color, String name, String value, {bool dashed = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 16, height: dashed ? 0 : 3, decoration: dashed ? BoxDecoration(border: Border(top: BorderSide(color: color, width: 2))) : BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Text(name, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 6),
          Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 22, runSpacing: 6, children: [
        legend(_util, 'GPU load', shown == null ? '—' : '${shown.utilization.round()}%'),
        legend(_vram, 'Memory', shown == null ? '—' : '${shown.memoryPercent.round()}% (${(shown.usedMb / 1024).toStringAsFixed(1)} GB)'),
        if (widget.limitPercent != null) legend(_limit, 'Lend limit', widget.limitLabel, dashed: true),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        height: widget.height,
        child: MouseRegion(
          onHover: (e) => setState(() => _hoverX = (e.localPosition.dx / (context.size?.width ?? 1)).clamp(0.0, 1.0)),
          onExit: (_) => setState(() => _hoverX = null),
          child: LayoutBuilder(builder: (context, box) => CustomPaint(
                size: Size(box.maxWidth, widget.height),
                painter: _ChartPainter(samples: s, limit: widget.limitPercent, hoverX: _hoverX),
              )),
        ),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(s.length < 2 ? 'Collecting…' : _ago(s.first.at), style: Theme.of(context).textTheme.bodySmall),
        Text(hovered == null ? 'now' : _ago(hovered.at), style: Theme.of(context).textTheme.bodySmall),
      ]),
    ]);
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 3) return 'now';
    if (d.inMinutes < 1) return '${d.inSeconds} s ago';
    return '${d.inMinutes} min ${d.inSeconds % 60} s ago';
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.samples, required this.limit, required this.hoverX});
  final List<GpuSample> samples;
  final double? limit;
  final double? hoverX;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 36.0, bottom = 4.0, top = 6.0;
    final plot = Rect.fromLTRB(left, top, size.width - 4, size.height - bottom);

    // grid and the percent labels
    final grid = Paint()
      ..color = Palette.outline
      ..strokeWidth = 1;
    for (final p in [0, 25, 50, 75, 100]) {
      final y = plot.bottom - plot.height * p / 100;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final tp = TextPainter(text: TextSpan(text: '$p%', style: const TextStyle(fontSize: 10.5, color: Palette.muted)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    Path line(double Function(GpuSample) value) {
      final path = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = plot.left + plot.width * (samples.length == 1 ? 1 : i / (samples.length - 1));
        final y = plot.bottom - plot.height * value(samples[i]).clamp(0, 100) / 100;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    if (samples.length >= 2) {
      // the load, with a soft fill below it
      final util = line((s) => s.utilization);
      final fill = Path.from(util)
        ..lineTo(plot.right, plot.bottom)
        ..lineTo(plot.left, plot.bottom)
        ..close();
      canvas.drawPath(fill, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Palette.accent.withValues(alpha: 0.28), Palette.accent.withValues(alpha: 0.0)]).createShader(plot));
      canvas.drawPath(util, Paint()
        ..color = Palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round);
      canvas.drawPath(line((s) => s.memoryPercent), Paint()
        ..color = const Color(0xFFB58CFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round);
    }

    // the lend ceiling, dashed
    if (limit != null) {
      final y = plot.bottom - plot.height * limit!.clamp(0, 100) / 100;
      final dash = Paint()
        ..color = Palette.warn
        ..strokeWidth = 1.6;
      for (var x = plot.left; x < plot.right; x += 10) {
        canvas.drawLine(Offset(x, y), Offset((x + 5).clamp(plot.left, plot.right), y), dash);
      }
    }

    // the hover guide
    if (hoverX != null && samples.length >= 2) {
      final x = plot.left + plot.width * hoverX!;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), Paint()
        ..color = Palette.muted.withValues(alpha: 0.6)
        ..strokeWidth = 1);
      final s = samples[(hoverX! * (samples.length - 1)).round().clamp(0, samples.length - 1)];
      for (final (value, color) in [(s.utilization, Palette.accent), (s.memoryPercent, const Color(0xFFB58CFF))]) {
        canvas.drawCircle(Offset(x, plot.bottom - plot.height * value.clamp(0, 100) / 100), 4, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
