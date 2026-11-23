// What the dashboard shows about this PC's graphics card (from nvidia-smi, which ships with the NVIDIA driver).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class GpuInfo {
  GpuInfo(this.name, this.usedMb, this.totalMb, [this.utilization = 0]);
  final String name;
  final int usedMb;
  final int totalMb;

  /// How busy the card is, percent.
  final double utilization;
  double get fraction => totalMb == 0 ? 0 : (usedMb / totalMb).clamp(0.0, 1.0);
}

class SystemInfo {
  /// null when there is no NVIDIA card or no driver.
  static Future<GpuInfo?> gpu() async {
    if (Platform.isMacOS) return _appleChip();
    try {
      final r = await Process.run('nvidia-smi', ['--query-gpu=name,memory.used,memory.total,utilization.gpu', '--format=csv,noheader,nounits'], stdoutEncoding: utf8).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      final line = (r.stdout as String).trim().split('\n').first;
      final parts = line.split(',').map((s) => s.trim()).toList();
      if (parts.length < 3) return null;
      return GpuInfo(parts[0], int.tryParse(parts[1]) ?? 0, int.tryParse(parts[2]) ?? 0, parts.length > 3 ? double.tryParse(parts[3]) ?? 0 : 0);
    } on ProcessException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}

/// Macs have no NVIDIA card: the chip and the memory it shares with the system are shown instead.
Future<GpuInfo?> _appleChip() async {
  try {
    final name = (await Process.run('sysctl', ['-n', 'machdep.cpu.brand_string'])).stdout.toString().trim();
    final mem = int.tryParse((await Process.run('sysctl', ['-n', 'hw.memsize'])).stdout.toString().trim()) ?? 0;
    return GpuInfo(name.isEmpty ? 'Apple silicon' : name, 0, mem ~/ (1024 * 1024));
  } catch (_) {
    return null;
  }
}

/// One reading of the card, for the chart.
class GpuSample {
  GpuSample(this.at, this.utilization, this.usedMb, this.totalMb);
  final DateTime at;
  final double utilization;
  final int usedMb;
  final int totalMb;

  /// Memory in use as a percent of the card's memory.
  double get memoryPercent => totalMb == 0 ? 0 : usedMb * 100 / totalMb;
}
