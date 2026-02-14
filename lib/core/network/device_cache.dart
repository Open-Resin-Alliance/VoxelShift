import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/nanodlp_device.dart';

/// Simple on-disk cache for discovered NanoDLP devices.
class DeviceCache {
  static const _fileName = 'nanodlp_devices.json';

  Future<File> _getCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<List<NanoDlpDevice>> load() async {
    try {
      final file = await _getCacheFile();
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => NanoDlpDevice.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<NanoDlpDevice> devices) async {
    try {
      final file = await _getCacheFile();
      final payload = devices.map((d) => d.toJson()).toList(growable: false);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    } catch (_) {
      // best-effort cache only
    }
  }
}
