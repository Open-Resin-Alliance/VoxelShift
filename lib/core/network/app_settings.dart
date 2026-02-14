import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists application settings/preferences.
class AppSettings {
  static const _fileName = 'app_settings.json';

  String? defaultMaterialProfileId;

  AppSettings({this.defaultMaterialProfileId});

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      defaultMaterialProfileId: json['defaultMaterialProfileId'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'defaultMaterialProfileId': defaultMaterialProfileId,
    };
  }

  Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Load settings from disk.
  static Future<AppSettings> load() async {
    try {
      final instance = AppSettings();
      final file = await instance._getFile();
      if (!await file.exists()) return AppSettings();
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return AppSettings();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return AppSettings();
      return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return AppSettings();
    }
  }

  /// Save settings to disk.
  Future<void> save() async {
    try {
      final file = await _getFile();
      final payload = toJson();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    } catch (_) {
      // best-effort
    }
  }
}
