import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import '../models/nanodlp_device.dart';

/// Scans the local network for NanoDLP printer backends.
class NanoDlpScanner {
  static const List<int> defaultPorts = [80, 8080];
  static const int _connectionTimeoutMs = 1500;
  static const int _maxParallelProbes = 64;

  final List<void Function(NanoDlpDevice)> _deviceFoundListeners = [];
  final List<void Function(String)> _logListeners = [];

  void addDeviceFoundListener(void Function(NanoDlpDevice) listener) =>
      _deviceFoundListeners.add(listener);

  void addLogListener(void Function(String) listener) =>
      _logListeners.add(listener);

  /// Scan all local subnets for NanoDLP instances.
  Future<List<NanoDlpDevice>> scan({
    List<int>? ports,
    String? ipOverride,
    void Function(int scanned, int total)? onProgress,
  }) async {
    ports ??= defaultPorts;
    final forcedIp = ipOverride?.trim();
    if (forcedIp != null && forcedIp.isNotEmpty) {
      final found = <NanoDlpDevice>[];
      final probeCandidates = <(String, int)>[];
      for (final port in ports) {
        probeCandidates.add((forcedIp, port));
      }

      _log('Scanning forced IP $forcedIp across ${ports.length} port(s) '
          '(${probeCandidates.length} total probes)');

      int scanned = 0;
      for (final candidate in probeCandidates) {
        final (ip, port) = candidate;
        final device = await probe(ip, port);
        if (device != null) {
          found.add(device);
          for (final listener in _deviceFoundListeners) {
            listener(device);
          }
          _log('  Found NanoDLP at $ip:$port — ${device.displayName}');
        }
        scanned++;
        onProgress?.call(scanned, probeCandidates.length);
      }

      _log('Scan complete. ${found.length} device(s) found.');
      return found;
    }

    final subnets = await _getLocalSubnets();

    _log('Found ${subnets.length} network interface(s)');
    for (final subnet in subnets) {
      _log('  Subnet: $subnet');
    }

    final ipCandidates = <String>{};
    for (final subnet in subnets) {
      ipCandidates.addAll(_generateSubnetAddresses(subnet));
    }

    final probeCandidates = <(String, int)>[];
    for (final ip in ipCandidates) {
      for (final port in ports) {
        probeCandidates.add((ip, port));
      }
    }

    _log('Scanning ${ipCandidates.length} IPs across ${ports.length} port(s) '
        '(${probeCandidates.length} total probes)');

    if (probeCandidates.isEmpty) {
      _log('No IPv4 subnets detected. Connect to a network with IPv4 enabled.');
      onProgress?.call(0, 0);
      return [];
    }

    final found = <NanoDlpDevice>[];
    final foundIps = <String>{};
    int scanned = 0;

    // Process in batches for controlled parallelism
    for (int i = 0; i < probeCandidates.length; i += _maxParallelProbes) {
      final batch = probeCandidates.sublist(
        i,
        (i + _maxParallelProbes).clamp(0, probeCandidates.length),
      );

      await Future.wait(batch.map((candidate) async {
        final (ip, port) = candidate;

        if (foundIps.contains(ip)) {
          scanned++;
          return;
        }

        final device = await probe(ip, port);
        if (device != null && !foundIps.contains(ip)) {
          foundIps.add(ip);
          found.add(device);
          for (final listener in _deviceFoundListeners) {
            listener(device);
          }
          _log('  Found NanoDLP at $ip:$port — ${device.displayName}');
        }

        scanned++;
        onProgress?.call(scanned, probeCandidates.length);
      }));
    }

    _log('Scan complete. ${found.length} device(s) found.');
    return found;
  }

  /// Probe a single IP:port for NanoDLP.
  Future<NanoDlpDevice?> probe(String ip, int port) async {
    // Quick TCP check
    try {
      final socket = await Socket.connect(
        ip, port,
        timeout: Duration(milliseconds: _connectionTimeoutMs),
      );
      socket.destroy();
    } catch (_) {
      return null;
    }

    // Try NanoDLP /status endpoint
    try {
      final client = http.Client();
      try {
        final response = await client
            .get(
              Uri.parse('http://$ip:$port/status'),
              headers: {'Accept': 'application/json'},
            )
            .timeout(Duration(milliseconds: _connectionTimeoutMs * 2));

        if (response.statusCode != 200) return null;

        if (_isNanoDlpStatusResponse(response.body)) {
          String? printerName;
          String? firmware;
          String? hostname;
          String? status;
          String? state;
          bool? printing;
          int? layerId;
          int? layersCount;
          double? currentHeight;
          double? progress;

          try {
            final json = jsonDecode(response.body) as Map<String, dynamic>;
            hostname = json['Hostname'] as String?;
            printerName = json['Name'] as String? ?? json['Build'] as String?;
            firmware = json['Version']?.toString();
            status = json['Status']?.toString();
            state = json['State']?.toString();
            printing = json['Printing'] is bool ? json['Printing'] as bool : null;
            layerId = int.tryParse('${json['LayerID']}');
            layersCount = int.tryParse('${json['LayersCount']}');
            currentHeight = double.tryParse('${json['CurrentHeight']}');
            final prog = json['Progress'] ?? json['progress'];
            if (prog is num) {
              progress = prog.toDouble();
            } else {
              progress = double.tryParse('$prog');
            }
          } catch (_) {}

          return NanoDlpDevice(
            ipAddress: ip,
            port: port,
            hostName: hostname,
            printerName: printerName,
            firmwareVersion: firmware,
            status: status,
            state: state,
            printing: printing,
            layerId: layerId,
            layersCount: layersCount,
            currentHeight: currentHeight,
            progress: progress,
            lastSeen: DateTime.now(),
            isOnline: true,
          );
        }
      } finally {
        client.close();
      }
    } catch (_) {}

    return null;
  }

  /// Check if JSON response looks like NanoDLP status.
  static bool _isNanoDlpStatusResponse(String content) {
    if (content.isEmpty || !content.trimLeft().startsWith('{')) return false;

    const knownFields = [
      '"Printing"', '"Path"', '"LayerID"', '"Version"',
      '"Hostname"', '"State"', '"Status"', '"LayersCount"',
      '"PlateID"', '"Build"', '"Paused"', '"CurrentHeight"', '"IP"',
    ];

    int matches = 0;
    for (final field in knownFields) {
      if (content.contains(field)) {
        matches++;
        if (matches >= 3) return true;
      }
    }
    return false;
  }

  Future<List<String>> _getLocalSubnets() async {
    final subnets = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
            }
          }
        }
      }
    } catch (_) {}
    return subnets;
  }

  List<String> _generateSubnetAddresses(String subnet) {
    return List.generate(254, (i) => '$subnet.${i + 1}');
  }

  void _log(String message) {
    for (final listener in _logListeners) {
      listener(message);
    }
  }
}
