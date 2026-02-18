import 'package:flutter/material.dart';

import '../../core/models/nanodlp_device.dart';
import '../../core/network/nanodlp_client.dart';
import '../../core/network/nanodlp_scanner.dart';

/// Onboarding flow: discover and select a printer to set as active.
class OnboardingScreen extends StatefulWidget {
  final ValueChanged<NanoDlpDevice?> onDeviceSelected;

  const OnboardingScreen({super.key, required this.onDeviceSelected});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _scanner = NanoDlpScanner();
  final _devices = <NanoDlpDevice>[];
  final _logs = <String>[];
  final _manualIpController = TextEditingController();

  bool _isScanning = false;
  bool _isFetchingDetails = false;
  int _scanProgress = 0;
  int _scanTotal = 1;
  String? _hoveredDeviceIp;

  @override
  void initState() {
    super.initState();
    _scanner.addLogListener(_onLog);
    _scanner.addDeviceFoundListener(_onDeviceFound);
    // Auto-start scan on entry
    Future.microtask(_startScan);
  }

  @override
  void dispose() {
    _manualIpController.dispose();
    super.dispose();
  }

  void _onDeviceFound(NanoDlpDevice device) {
    if (!mounted) return;
    setState(() => _mergeDevice(device));
  }

  void _onLog(String msg) {
    if (!mounted) return;
    setState(() => _logs.add(msg));
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _devices.clear();
      _logs.clear();
      _scanProgress = 0;
      _scanTotal = 1;
    });

    final manualIp = _manualIpController.text.trim();
    try {
      await _scanner.scan(
        ipOverride: manualIp.isNotEmpty ? manualIp : null,
        onProgress: (scanned, total) {
          if (!mounted) return;
          setState(() {
            _scanProgress = scanned;
            _scanTotal = total;
          });
        },
      );
    } catch (e) {
      _onLog('Scan error: $e');
    }

    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  void _mergeDevice(NanoDlpDevice device) {
    final idx = _devices.indexWhere((d) => d.cacheKey == device.cacheKey);
    if (idx >= 0) {
      _devices[idx] = device;
    } else {
      _devices.add(device);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.of(context).padding.top + 12,
              20,
              20,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.view_in_ar,
                          color: Theme.of(context).colorScheme.primary,
                          size: 28,
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'VoxelShift',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Welcome to VoxelShift',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Find your NanoDLP printer, or continue in local conversion mode.',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _buildStep(
                              number: 1,
                              title: 'Discover Your Printer',
                              description:
                                  'Scanning your local network for NanoDLP instances...',
                              isActive: true,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Scan a specific IP (optional)',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _manualIpController,
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.done,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'e.g. 192.168.1.42',
                                hintStyle: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.35),
                                ),
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.04),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.55),
                                  ),
                                ),
                                prefixIcon: Icon(
                                  Icons.router,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.7),
                                  size: 18,
                                ),
                              ),
                            ),
                            if (_isScanning) ...[
                              const SizedBox(height: 14),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: _scanTotal > 0
                                      ? _scanProgress / _scanTotal
                                      : null,
                                  minHeight: 6,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Scanned $_scanProgress / $_scanTotal...',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isScanning ? null : _startScan,
                                icon: _isScanning
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                        ),
                                      )
                                    : const Icon(Icons.refresh, size: 18),
                                label: Text(
                                  _isScanning
                                      ? 'Scanning...'
                                      : 'Rescan Network',
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _isFetchingDetails
                                    ? null
                                    : () => widget.onDeviceSelected(null),
                                icon: const Icon(Icons.skip_next, size: 18),
                                label: const Text('Continue without machine'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildDiscoveryStatus(),
                    if (_logs.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Discovery Log',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 120,
                                ),
                                child: SingleChildScrollView(
                                  child: Text(
                                    _logs.join('\n'),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                      color: Colors.white.withValues(
                                        alpha: 0.52,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Loading overlay when fetching details
          if (_isFetchingDetails)
            Container(
              color: Colors.black.withValues(alpha: 0.7),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.cyan.shade300),
                    const SizedBox(height: 16),
                    Text(
                      'Fetching printer details...',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryStatus() {
    if (_devices.isNotEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.greenAccent.shade200),
                  const SizedBox(width: 8),
                  Text(
                    '${_devices.length} printer${_devices.length == 1 ? '' : 's'} found',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Select a printer to continue',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 14),
              ..._devices.map((device) => _buildDeviceCard(device)),
            ],
          ),
        ),
      );
    }

    if (_isScanning) {
      return const SizedBox.shrink();
    }

    final noIpv4 = _scanTotal == 0;
    return Card(
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: (noIpv4 ? Colors.redAccent : Colors.orangeAccent)
                  .withValues(alpha: 0.8),
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              noIpv4 ? Icons.wifi_off : Icons.search_off,
              color: noIpv4 ? Colors.redAccent : Colors.orangeAccent,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    noIpv4 ? 'No IPv4 network detected' : 'No printers found',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    noIpv4
                        ? 'Connect to Wi‑Fi or Ethernet with IPv4 enabled, then rescan.'
                        : 'Make sure your NanoDLP printer is online and on the same network.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep({
    required int number,
    required String title,
    required String description,
    required bool isActive,
  }) {
    return AnimatedOpacity(
      opacity: isActive ? 1.0 : 0.4,
      duration: const Duration(milliseconds: 300),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isActive
                  ? LinearGradient(
                      colors: [Colors.cyan.shade400, Colors.blue.shade400],
                    )
                  : LinearGradient(
                      colors: [Colors.grey.shade700, Colors.grey.shade800],
                    ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: Colors.cyan.withValues(alpha: 0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
            ),
            child: Center(
              child: isActive
                  ? Text(
                      '$number',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    )
                  : Icon(Icons.check, color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isActive
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(NanoDlpDevice device) {
    final isHovered = _hoveredDeviceIp == device.ipAddress;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredDeviceIp = device.ipAddress),
      onExit: (_) => setState(() => _hoveredDeviceIp = null),
      child: GestureDetector(
        onTap: () => _selectDevice(device),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isHovered
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: isHovered
                  ? Colors.cyan.withValues(alpha: 0.5)
                  : Colors.cyan.withValues(alpha: 0.2),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.print, color: Colors.cyan.shade300, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          '${device.ipAddress}:${device.port}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (device.machineLcdType != null) ...[
                          Text(
                            ' • ',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.3),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            device.machineLcdType!,
                            style: TextStyle(
                              color: Colors.cyan.shade300,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        if (device.machineResolutionX != null) ...[
                          Text(
                            ' • ',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.3),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${device.machineResolutionX}×${device.machineResolutionY}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: isHovered
                    ? Colors.cyan.shade400
                    : Colors.white.withValues(alpha: 0.3),
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fetch full machine specs and call onDeviceSelected
  Future<void> _selectDevice(NanoDlpDevice device) async {
    if (_isFetchingDetails) return;
    setState(() => _isFetchingDetails = true);

    final client = NanoDlpClient(device);
    try {
      final machine = await client.getMachineJson();
      if (machine != null) {
        final inferred = NanoDlpClient.inferMachineProfile(machine);
        final modelName = _extractMachineString(machine, [
          'Model',
          'model',
          'ModelName',
          'machineName',
          'PrinterName',
          'printerName',
        ]);
        final serial = _extractMachineString(machine, [
          'Serial',
          'serial',
          'SerialNumber',
          'serialNumber',
          'SN',
          'S/N',
          'UUID',
          'uuid',
        ]);
        final lcdType = _inferLcdType(inferred.width, inferred.height);

        final updated = NanoDlpDevice(
          ipAddress: device.ipAddress,
          port: device.port,
          hostName: device.hostName,
          printerName: device.printerName,
          firmwareVersion: device.firmwareVersion,
          status: device.status,
          state: device.state,
          printing: device.printing,
          layerId: device.layerId,
          layersCount: device.layersCount,
          currentHeight: device.currentHeight,
          progress: device.progress,
          machineResolutionX: inferred.width,
          machineResolutionY: inferred.height,
          machineProfileLabel: inferred.label,
          machineModelName: modelName,
          machineSerial: serial,
          machineLcdType: lcdType,
          lastSeen: device.lastSeen,
          isOnline: device.isOnline,
        );

        widget.onDeviceSelected(updated);
      } else {
        // Fall back to basic device if machine.json not available
        widget.onDeviceSelected(device);
      }
    } catch (e) {
      debugPrint('[Onboarding] Error fetching device details: $e');
      // Fall back to basic device on error
      widget.onDeviceSelected(device);
    } finally {
      client.dispose();
      if (mounted) {
        setState(() => _isFetchingDetails = false);
      }
    }
  }

  String? _extractMachineString(
    Map<String, dynamic> machine,
    List<String> keys,
  ) {
    for (final key in keys) {
      final v = machine[key];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  String? _inferLcdType(int? width, int? height) {
    if (width == null) return null;
    // Athena 2 LCD types based on resolution (native or output width)
    //
    // Native sub-pixel widths:
    //   16K 3bit: 15136
    //   16K 8bit: 15120
    //   12K:      11520
    //
    // Output (PNG) widths:
    //   16K 3bit: ~7568 (15136 / 2)
    //   16K 8bit: ~5040 (15120 / 3)
    //   12K 8bit: ~3840 (11520 / 3)
    if (width == 15136 || (width >= 7400 && width <= 7700)) return '16K 3bit';
    if (width == 15120 || (width >= 4900 && width <= 5200)) return '16K 8bit';
    if (width == 15360) return '16K';
    if (width == 11520 || (width >= 3700 && width <= 3900)) return '12K';
    return null;
  }
}
