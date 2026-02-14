import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import '../models/nanodlp_device.dart';
import '../models/resin_profile.dart';

/// Client for the NanoDLP REST API — upload plates, check status.
class NanoDlpClient {
  final http.Client _http;
  final String baseUrl;

  NanoDlpClient(NanoDlpDevice device)
      : baseUrl = device.baseUrl,
        _http = http.Client();

  NanoDlpClient.fromUrl(this.baseUrl) : _http = http.Client();

  /// Check if the NanoDLP backend is reachable.
  Future<bool> ping() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Get printer status as raw JSON string.
  Future<String?> getStatus() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) return response.body;
    } catch (_) {}
    return null;
  }

  /// Get printer status as a decoded JSON map.
  Future<Map<String, dynamic>?> getStatusMap() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Get the current printer state.
  ///
  /// Returns 0 when idle/ready, any other value when busy.
  Future<int?> getPrinterState() async {
    final status = await getStatusMap();
    if (status == null) return null;
    return _extractInt(status, [
      'State',
      'state',
      'PrinterState',
      'printer_state',
    ]);
  }

  /// Get machine.json as a decoded map.
  Future<Map<String, dynamic>?> getMachineJson() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/json/db/machine.json'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Upload a plate file to the NanoDLP printer.
  Future<(bool success, String? message)> uploadPlate(
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return (false, 'File not found.');

    try {
      final fileName = filePath.split(Platform.pathSeparator).last;
      final fileBytes = await file.readAsBytes();
      final fileSize = fileBytes.length;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/plate/add'),
      );

      request.files.add(http.MultipartFile.fromBytes(
        'ZipFile',
        fileBytes,
        filename: fileName,
      ));

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 10),
      );

      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        onProgress?.call(1.0);
        return (true, 'Upload successful (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
      } else {
        return (false, 'Upload failed (HTTP ${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      return (false, 'Upload failed: $e');
    }
  }

  /// List resin/material profiles from NanoDLP.
  Future<List<ResinProfile>> listResinProfiles() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/json/db/profiles.json'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];

      final decoded = jsonDecode(response.body);
      final entries = _extractListFromJson(decoded, keys: ['profiles', 'data']);
      final profiles = <ResinProfile>[];
      final seen = <String>{};

      for (final entry in entries) {
        if (entry is! Map) continue;
        final raw = Map<String, dynamic>.from(entry);
        final id = ResinProfile.resolveProfileId(raw);
        if (id == null) continue;
        if (seen.contains(id)) continue;
        final name = ResinProfile.resolveName(raw);
        final locked = ResinProfile.resolveLocked(name, raw);
        profiles.add(ResinProfile(name: name, profileId: id, raw: raw, locked: locked));
        seen.add(id);
      }

      return profiles;
    } catch (_) {
      return [];
    }
  }

  /// Import a file into NanoDLP using the WebUI-style flow.
  /// Returns (success, message, plateId).
  ///
  /// Uses dart:io [HttpClient] with chunked streaming to provide real-time
  /// upload progress via [onProgress] (0.0 – 1.0).
  Future<({bool success, String? message, int? plateId})> importPlate(
    String filePath, {
    required String jobName,
    required String profileId,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return (success: false, message: 'File not found.', plateId: null);
    }

    try {
      final uri = Uri.parse('$baseUrl/plate/add');
      final host = uri.host.toLowerCase();
      final isLocalhost = host == 'localhost' ||
          host == '127.0.0.1' ||
          host.startsWith('127.');

      onProgress?.call(0.0);

      // Build multipart body streaming from disk to track real bytes sent.
      final boundary = 'voxelshift-${DateTime.now().millisecondsSinceEpoch}';
      final contentType = 'multipart/form-data; boundary=$boundary';

      final fieldParts = <Uint8List>[];
      void addField(String name, String value) {
        fieldParts.add(Uint8List.fromList(utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="$name"\r\n'
          '\r\n'
          '$value\r\n',
        )));
      }

      addField('Path', jobName);
      addField('ProfileID', profileId);

      Uint8List? fileHeader;
      Uint8List? fileFooter;
      int fileSize = 0;

      if (isLocalhost) {
        addField('USBFile', filePath);
      } else {
        final fileName = filePath.split(Platform.pathSeparator).last;
        fileHeader = Uint8List.fromList(utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="ZipFile"; filename="$fileName"\r\n'
          'Content-Type: application/octet-stream\r\n'
          '\r\n',
        ));
        fileFooter = Uint8List.fromList(utf8.encode('\r\n'));
        fileSize = await file.length();
      }

      final closing = Uint8List.fromList(utf8.encode('--$boundary--\r\n'));

      int totalBytes = 0;
      for (final part in fieldParts) {
        totalBytes += part.length;
      }
      if (fileHeader != null) totalBytes += fileHeader.length;
      totalBytes += fileSize;
      if (fileFooter != null) totalBytes += fileFooter.length;
      totalBytes += closing.length;

      // Use dart:io HttpClient for chunked streaming with progress
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await httpClient.postUrl(uri);
        request.headers.set('Content-Type', contentType);
        request.headers.set('Content-Length', totalBytes.toString());
        request.headers.set('Accept',
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
        request.followRedirects = false;

        int sent = 0;
        void report(int delta) {
          sent += delta;
          final pct = (sent / totalBytes).clamp(0.0, 1.0);
          onProgress?.call(pct);
        }

        // Send small field parts
        for (final part in fieldParts) {
          request.add(part);
          report(part.length);
          await Future.delayed(Duration.zero);
        }

        // Stream file bytes (if applicable)
        if (fileHeader != null) {
          request.add(fileHeader);
          report(fileHeader.length);
          await Future.delayed(Duration.zero);

          await for (final chunk in file.openRead()) {
            request.add(chunk);
            report(chunk.length);
            await Future.delayed(Duration.zero);
          }

          if (fileFooter != null) {
            request.add(fileFooter);
            report(fileFooter.length);
            await Future.delayed(Duration.zero);
          }
        }

        request.add(closing);
        report(closing.length);

        final response = await request.close().timeout(
          const Duration(minutes: 5),
        );

        final statusCode = response.statusCode;
        final responseBody = await response.transform(utf8.decoder).join();

        if (statusCode == 200 || statusCode == 302) {
          onProgress?.call(1.0);
          int? plateId;
          final location = response.headers.value('location');
          if (location != null) {
            final match = RegExp(r'/(\d+)').firstMatch(location);
            if (match != null) {
              plateId = int.tryParse(match.group(1) ?? '');
            }
          }
          return (
            success: true,
            message: 'Upload successful',
            plateId: plateId,
          );
        }

        return (
          success: false,
          message: 'Upload failed (HTTP $statusCode): $responseBody',
          plateId: null,
        );
      } finally {
        httpClient.close();
      }
    } catch (e) {
      return (success: false, message: 'Upload failed: $e', plateId: null);
    }
  }

  /// List plates as JSON maps (best-effort parsing).
  Future<List<Map<String, dynamic>>> listPlatesJson() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/plates/list/json'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];
      final decoded = jsonDecode(response.body);
      final entries = _extractListFromJson(decoded, keys: ['plates', 'files', 'data']);
      return entries
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (_) {
      return [];
    }
  }

  /// Poll for an imported plate to appear with valid metadata.
  Future<Map<String, dynamic>?> waitForPlateReady({
    int? plateId,
    String? jobName,
    Duration timeout = const Duration(seconds: 15),
    void Function(double progress)? onProgress,
  }) async {
    final start = DateTime.now();
    const delay = Duration(milliseconds: 300);

    while (DateTime.now().difference(start) < timeout) {
      final plates = await listPlatesJson();
      final plate = _findPlate(plates, plateId: plateId, jobName: jobName);
      if (plate != null) {
        if (_isMetadataReady(plate)) return plate;
      }

      final progress = (DateTime.now().difference(start).inMilliseconds / timeout.inMilliseconds)
          .clamp(0.0, 1.0);
      onProgress?.call(progress);
      await Future.delayed(delay);
    }

    return null;
  }

  /// List plates on the NanoDLP backend.
  Future<String?> listPlates() async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/plates'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) return response.body;
    } catch (_) {}
    return null;
  }

  /// Start printing a plate by its ID.
  Future<(bool success, String? message)> startPrint(int plateId) async {
    try {
      final baseNoSlash = baseUrl.replaceAll(RegExp(r'/+$'), '');
      final response = await _http
          .get(Uri.parse('$baseNoSlash/printer/start/$plateId'))
          .timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200 || response.statusCode == 302) {
        return (true, 'Print started successfully');
      } else {
        return (false, 'Failed to start print (HTTP ${response.statusCode})');
      }
    } catch (e) {
      return (false, 'Failed to start print: $e');
    }
  }

  static List<dynamic> _extractListFromJson(
    dynamic decoded, {
    List<String> keys = const [],
  }) {
    if (decoded is List) return decoded;
    if (decoded is Map) {
      for (final key in keys) {
        final value = decoded[key];
        if (value is List) return value;
      }
      final values = decoded.values.whereType<List>().toList();
      if (values.isNotEmpty) return values.first;
      return [decoded];
    }
    return const [];
  }

  static Map<String, dynamic>? _findPlate(
    List<Map<String, dynamic>> plates, {
    int? plateId,
    String? jobName,
  }) {
    if (plateId != null) {
      for (final p in plates) {
        final id = p['PlateID'] ?? p['plateId'] ?? p['plate_id'] ?? p['id'];
        final parsed = int.tryParse('$id');
        if (parsed != null && parsed == plateId) return p;
      }
    }

    if (jobName != null && jobName.trim().isNotEmpty) {
      final needle = jobName.trim().toLowerCase();
      for (final p in plates) {
        final candidates = [
          p['Path'],
          p['path'],
          p['Name'],
          p['name'],
          p['File'],
          p['file'],
        ];
        for (final c in candidates) {
          final s = c?.toString().toLowerCase();
          if (s != null && s.contains(needle)) return p;
        }
      }
    }

    return null;
  }

  static bool _isMetadataReady(Map<String, dynamic> plate) {
    bool hasPositive(dynamic v) {
      if (v == null) return false;
      if (v is num) return v > 0;
      final parsed = double.tryParse('$v');
      return parsed != null && parsed > 0;
    }

    final candidates = [
      plate['LayerHeight'],
      plate['layerHeight'],
      plate['LayersCount'],
      plate['layerCount'],
      plate['PrintTime'],
      plate['printTime'],
      plate['UsedMaterial'],
      plate['usedMaterial'],
    ];

    if (candidates.any(hasPositive)) return true;

    final fileData = plate['file_data'] ?? plate['fileData'];
    if (fileData is Map) {
      final lastModified = fileData['last_modified'] ?? fileData['lastModified'];
      if (hasPositive(lastModified)) return true;
    }

    return false;
  }

  /// Infer screen class and board type based on machine.json.
  static ({int? width, int? height, String? label}) inferMachineProfile(
    Map<String, dynamic> machine,
  ) {
    final width = _extractInt(machine, [
      'PWidth',
      'XRes',
      'ResolutionX',
      'LCDX',
      'Width',
      'ProjectorX',
      'ProjectorWidth',
      'ProjectorW',
      'ScreenX',
    ]);
    final height = _extractInt(machine, [
      'PHeight',
      'YRes',
      'ResolutionY',
      'LCDY',
      'Height',
      'ProjectorY',
      'ProjectorHeight',
      'ProjectorH',
      'ScreenY',
    ]);

    String? label;

    final bits = _extractInt(machine, ['ColorBits', 'BitDepth', 'Bits']);
    final boardHint3Bit = bits == 3;

    if (width != null) {
      // Detect board type using output width heuristics.
      if (_within(width, 7400, 8200)) {
        label = '16K (3-bit)';
      } else if (_within(width, 5200, 5600)) {
        label = '16K (8-bit)';
      } else if (_within(width, 5600, 6100)) {
        label = '12K (3-bit)';
      } else if (_within(width, 3700, 4300)) {
        label = '12K (8-bit)';
      } else if (width >= 15000) {
        label = boardHint3Bit ? '16K (3-bit)' : '16K';
      } else if (width >= 11000) {
        label = boardHint3Bit ? '12K (3-bit)' : '12K';
      }
    }

    return (width: width, height: height, label: label);
  }

  static int? _extractInt(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final v = m[key];
      if (v is int) return v;
      if (v is num) return v.round();
      final parsed = int.tryParse('$v');
      if (parsed != null) return parsed;
    }
    return null;
  }

  static bool _within(int v, int min, int max) => v >= min && v <= max;

  void dispose() => _http.close();
}
