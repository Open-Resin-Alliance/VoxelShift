import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/nanodlp_device.dart';

/// Persists the user's selected "active" target printer.
class ActiveDeviceStore {
  static const _fileName = 'active_device.json';

  Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Load the stored active device, or null if none set.
  Future<NanoDlpDevice?> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return NanoDlpDevice.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  /// Save the active device.
  Future<void> save(NanoDlpDevice? device) async {
    try {
      final file = await _getFile();
      if (device == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      final payload = device.toJson();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    } catch (_) {
      // best-effort
    }
  }
}
