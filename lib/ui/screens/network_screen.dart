import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/models/nanodlp_device.dart';
import '../../core/models/resin_profile.dart';
import '../../core/network/nanodlp_client.dart';
import '../../core/network/device_cache.dart';
import '../../core/network/nanodlp_scanner.dart';

/// Network screen: scan for NanoDLP printers, view status, upload plates.
class NetworkScreen extends StatefulWidget {
  final NanoDlpDevice? activeDevice;
  final ValueChanged<NanoDlpDevice?> onSetActiveDevice;

  const NetworkScreen({
    super.key,
    this.activeDevice,
    required this.onSetActiveDevice,
  });

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final _scanner = NanoDlpScanner();
  final _cache = DeviceCache();
  final _devices = <NanoDlpDevice>[];
  final _logs = <String>[];

  bool _isScanning = false;
  int _scanProgress = 0;
  int _scanTotal = 1;
  Timer? _autoScanTimer;
  DateTime? _lastScanAt;
  final bool _autoScanEnabled = true;

  // Upload state
  bool _isUploading = false;
  String? _uploadMessage;

  @override
  void initState() {
    super.initState();
    _scanner.addDeviceFoundListener(_onDeviceFound);
    _scanner.addLogListener(_onLog);
    _loadCachedDevices();
    _scheduleAutoScan();
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
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

  Future<void> _loadCachedDevices() async {
    final cached = await _cache.load();
    if (!mounted || cached.isEmpty) return;
    setState(() {
      _devices.clear();
      _devices.addAll(cached);
      _lastScanAt = DateTime.now();
    });
  }

  void _scheduleAutoScan() {
    if (!_autoScanEnabled) return;
    if (_devices.isNotEmpty) return;
    _autoScanTimer?.cancel();
    const interval = Duration(minutes: 5);
    _autoScanTimer = Timer.periodic(
      interval,
      (_) => _startScan(background: true),
    );

    final now = DateTime.now();
    final shouldScanNow =
        _lastScanAt == null || now.difference(_lastScanAt!) > interval;
    if (shouldScanNow) {
      Future.microtask(() => _startScan(background: true));
    }
  }

  void _mergeDevice(NanoDlpDevice device) {
    final idx = _devices.indexWhere((d) => d.cacheKey == device.cacheKey);
    if (idx >= 0) {
      final existing = _devices[idx];
      _devices[idx] = NanoDlpDevice(
        ipAddress: existing.ipAddress,
        port: existing.port,
        hostName: device.hostName ?? existing.hostName,
        printerName: device.printerName ?? existing.printerName,
        firmwareVersion: device.firmwareVersion ?? existing.firmwareVersion,
        status: device.status ?? existing.status,
        state: device.state ?? existing.state,
        printing: device.printing ?? existing.printing,
        layerId: device.layerId ?? existing.layerId,
        layersCount: device.layersCount ?? existing.layersCount,
        currentHeight: device.currentHeight ?? existing.currentHeight,
        progress: device.progress ?? existing.progress,
        machineResolutionX:
          device.machineResolutionX ?? existing.machineResolutionX,
        machineResolutionY:
          device.machineResolutionY ?? existing.machineResolutionY,
        machineProfileLabel:
          device.machineProfileLabel ?? existing.machineProfileLabel,
        machineModelName:
          device.machineModelName ?? existing.machineModelName,
        machineSerial: device.machineSerial ?? existing.machineSerial,
        machineLcdType: device.machineLcdType ?? existing.machineLcdType,
        lastSeen: device.lastSeen ?? existing.lastSeen,
        isOnline: device.isOnline,
      );
      return;
    }
    _devices.add(device);
  }

  Future<void> _refreshDeviceStatus(NanoDlpDevice device) async {
    final client = NanoDlpClient(device);
    try {
      final status = await client.getStatusMap();
      final machine = await client.getMachineJson();
      if (!mounted) return;
      if (status == null) {
        setState(() => _mergeDevice(_markOffline(device)));
        return;
      }

      var updated = _deviceFromStatus(device, status);
      if (machine != null) {
        final inferred = NanoDlpClient.inferMachineProfile(machine);
        final modelName = _extractMachineString(machine, [
          'Model',
          'model',
          'Name',
          'name',
          'MachineName',
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
        updated = NanoDlpDevice(
          ipAddress: updated.ipAddress,
          port: updated.port,
          hostName: updated.hostName,
          printerName: updated.printerName,
          firmwareVersion: updated.firmwareVersion,
          status: updated.status,
          state: updated.state,
          printing: updated.printing,
          layerId: updated.layerId,
          layersCount: updated.layersCount,
          currentHeight: updated.currentHeight,
          progress: updated.progress,
          machineResolutionX: inferred.width,
          machineResolutionY: inferred.height,
          machineProfileLabel: inferred.label,
          machineModelName: modelName,
          machineSerial: serial,
          machineLcdType: lcdType,
          lastSeen: updated.lastSeen,
          isOnline: updated.isOnline,
        );
      }
      setState(() => _mergeDevice(updated));
      await _cache.save(_devices);
    } finally {
      client.dispose();
    }
  }

  NanoDlpDevice _deviceFromStatus(
    NanoDlpDevice base,
    Map<String, dynamic> json,
  ) {
    String? hostname = json['Hostname']?.toString();
    String? printerName = json['Name']?.toString() ?? json['Build']?.toString();
    String? firmware = json['Version']?.toString();

    final status = json['Status']?.toString();
    final state = json['State']?.toString();
    final printing = json['Printing'] is bool ? json['Printing'] as bool : null;
    final layerId = int.tryParse('${json['LayerID']}');
    final layersCount = int.tryParse('${json['LayersCount']}');
    final currentHeight = double.tryParse('${json['CurrentHeight']}');
    final prog = json['Progress'] ?? json['progress'];
    final progress = prog is num ? prog.toDouble() : double.tryParse('$prog');

    return NanoDlpDevice(
      ipAddress: base.ipAddress,
      port: base.port,
      hostName: hostname ?? base.hostName,
      printerName: printerName ?? base.printerName,
      firmwareVersion: firmware ?? base.firmwareVersion,
      status: status ?? base.status,
      state: state ?? base.state,
      printing: printing ?? base.printing,
      layerId: layerId ?? base.layerId,
      layersCount: layersCount ?? base.layersCount,
      currentHeight: currentHeight ?? base.currentHeight,
      progress: progress ?? base.progress,
      machineResolutionX: base.machineResolutionX,
      machineResolutionY: base.machineResolutionY,
      machineProfileLabel: base.machineProfileLabel,
      machineModelName: base.machineModelName,
      machineSerial: base.machineSerial,
      machineLcdType: base.machineLcdType,
      lastSeen: DateTime.now(),
      isOnline: true,
    );
  }

  NanoDlpDevice _markOffline(NanoDlpDevice base) => NanoDlpDevice(
        ipAddress: base.ipAddress,
        port: base.port,
        hostName: base.hostName,
        printerName: base.printerName,
        firmwareVersion: base.firmwareVersion,
        status: base.status,
        state: base.state,
        printing: base.printing,
        layerId: base.layerId,
        layersCount: base.layersCount,
        currentHeight: base.currentHeight,
        progress: base.progress,
        machineResolutionX: base.machineResolutionX,
        machineResolutionY: base.machineResolutionY,
        machineProfileLabel: base.machineProfileLabel,
        machineModelName: base.machineModelName,
        machineSerial: base.machineSerial,
        machineLcdType: base.machineLcdType,
        lastSeen: base.lastSeen,
        isOnline: false,
      );

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

  Future<void> _startScan({bool background = false}) async {
    if (_isScanning) return;
    if (background && _devices.isNotEmpty) return;
    setState(() {
      _isScanning = true;
      if (!background) {
        _devices.clear();
        _logs.clear();
      }
      _scanProgress = 0;
      _scanTotal = 1;
      for (final d in _devices) {
        d.isOnline = false;
      }
    });

    try {
      await _scanner.scan(
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
      setState(() {
        _isScanning = false;
        _lastScanAt = DateTime.now();
      });
      await _cache.save(_devices);
      if (_devices.isNotEmpty) {
        _autoScanTimer?.cancel();
      }
    }
  }

  Future<void> _uploadToDevice(NanoDlpDevice device) async {
    // Ask user for file path
    final path = await _pickPlateFile();
    if (path == null || path.isEmpty) return;

    setState(() {
      _isUploading = true;
      _uploadMessage = null;
    });

    final client = NanoDlpClient(device);
    try {
      final profiles = await client.listResinProfiles();
      final selectable = profiles.where((p) => !p.locked).toList();
      if (selectable.isEmpty) {
        setState(() {
          _uploadMessage = 'No material profiles found on the device.';
          _isUploading = false;
        });
        return;
      }

      final options = await _showImportOptionsDialog(path, selectable);
      if (options == null) {
        setState(() => _isUploading = false);
        return;
      }

      final progress = ValueNotifier<double>(0.0);
      final message = ValueNotifier<String>('Preparing import...');
      _showImportProgressDialog(progress, message);

      message.value = 'Uploading file...';
      progress.value = 0.05;
      final result = await client.importPlate(
        path,
        jobName: options.jobName,
        profileId: options.resin.profileId,
        onProgress: (p) => progress.value = 0.05 + (p * 0.4),
      );

      if (!result.success) {
        message.value = result.message ?? 'Upload failed';
        progress.value = 0.0;
        await Future.delayed(const Duration(milliseconds: 800));
        _closeProgressDialog();
        setState(() {
          _uploadMessage = result.message ?? 'Upload failed';
          _isUploading = false;
        });
        return;
      }

      message.value = 'Processing file metadata...';
      progress.value = 0.6;
      final plate = await client.waitForPlateReady(
        plateId: result.plateId,
        jobName: options.jobName,
        onProgress: (p) => progress.value = 0.6 + (p * 0.4),
      );

      final finalMessage = plate != null
          ? 'Import complete!'
          : 'Import complete (metadata pending)';

      message.value = finalMessage;
      progress.value = 1.0;
      await Future.delayed(const Duration(milliseconds: 800));
      _closeProgressDialog();

      setState(() {
        _uploadMessage = finalMessage;
        _isUploading = false;
      });
    } catch (e) {
      setState(() {
        _uploadMessage = 'Upload failed: $e';
        _isUploading = false;
      });
    } finally {
      client.dispose();
    }
  }

  Future<String?> _pickPlateFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['nanodlp', 'zip'],
      dialogTitle: 'Select Plate File',
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  }

  Future<_ImportOptions?> _showImportOptionsDialog(
    String filePath,
    List<ResinProfile> profiles,
  ) async {
    final controller = TextEditingController(text: _fileStem(filePath));
    ResinProfile selected = profiles.first;

    try {
      return await showDialog<_ImportOptions>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => _buildCardDialog(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(Icons.cloud_upload_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Import to NanoDLP',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Job name',
                    labelStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ResinProfile>(
                  initialValue: selected,
                  decoration: InputDecoration(
                    labelText: 'Material profile',
                    labelStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  dropdownColor: const Color(0xFF1E293B),
                  isExpanded: true,
                  items: profiles
                      .map((p) => DropdownMenuItem(
                            value: p,
                            child: Text(p.name),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => selected = value);
                  },
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: () {
                        final jobName = controller.text.trim();
                        if (jobName.isEmpty) return;
                        Navigator.pop(
                          ctx,
                          _ImportOptions(jobName: jobName, resin: selected),
                        );
                      },
                      child: const Text('Import'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  void _showImportProgressDialog(
    ValueNotifier<double> progress,
    ValueNotifier<String> message,
  ) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _buildCardDialog(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Importing…',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: message,
              builder: (context, value, child) => Text(value),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, child) => LinearProgressIndicator(
                value: value.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _closeProgressDialog() {
    if (!mounted) return;
    try {
      Navigator.of(context, rootNavigator: true).pop();
    } catch (_) {
      // ignore if already closed
    }
  }

  Dialog _buildCardDialog({required Widget child, double width = 480}) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  String _fileStem(String path) {
    final sep = path.contains('\\') ? '\\' : '/';
    final name = path.split(sep).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _showDeviceStatus(NanoDlpDevice device) async {
    final client = NanoDlpClient(device);
    try {
      final status = await client.getStatus();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => _buildCardDialog(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.displayName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 500,
                height: 300,
                child: SingleChildScrollView(
                  child: SelectableText(
                    status ?? 'Could not retrieve status.',
                    style: const TextStyle(
                      fontFamily: 'Consolas, monospace',
                      fontSize: 12,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } finally {
      client.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildScanSection(),
        if (_isScanning) ...[
          const SizedBox(height: 12),
          _buildScanProgress(),
        ],
        if (_devices.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildDeviceList(),
        ],
        if (_uploadMessage != null) ...[
          const SizedBox(height: 12),
          _buildUploadStatus(),
        ],
      ],
    );
  }

  Widget _buildScanSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_find,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  'Network Scanner',
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Scan your local network for NanoDLP printer backends.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _autoScanEnabled
                  ? 'Auto-scan enabled (every 5 min)'
                  : 'Auto-scan disabled',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 12,
              ),
            ),
            if (_lastScanAt != null) ...[
              const SizedBox(height: 4),
              Text(
                'Last scan: ${_lastScanAt!.toLocal().toString().split('.').first}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 12,
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
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.search, size: 18),
                label: Text(_isScanning ? 'Scanning…' : 'Start Scan'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanProgress() {
    final pct = _scanTotal > 0 ? _scanProgress / _scanTotal : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Probing $_scanProgress / $_scanTotal',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  '${_devices.length} found',
                  style: TextStyle(
                    color: _devices.isNotEmpty
                        ? Colors.greenAccent
                        : Colors.white.withValues(alpha: 0.4),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: pct, minHeight: 5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.print, size: 18, color: Colors.greenAccent),
                const SizedBox(width: 8),
                Text(
                  'Discovered Devices (${_devices.length})',
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._devices.map((d) => _buildDeviceTile(d)),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceTile(NanoDlpDevice device) {
    final accent = device.isOnline
        ? Colors.greenAccent.withValues(alpha: 0.8)
        : Colors.grey.withValues(alpha: 0.6);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.04),
            Colors.white.withValues(alpha: 0.02),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.15),
                  border: Border.all(color: accent, width: 2),
                ),
                child: Icon(
                  device.isOnline ? Icons.wifi : Icons.wifi_off,
                  size: 18,
                  color: accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            device.displayName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        _statusBadge(
                          device.isOnline ? 'Online' : 'Offline',
                          accent,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.ipAddress}:${device.port}'
                      '${device.firmwareVersion != null ? '  •  v${device.firmwareVersion}' : ''}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                    if (device.printerName != null &&
                        device.printerName!.isNotEmpty &&
                        device.printerName != device.displayName) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Printer: ${device.printerName}'
                        '${device.machineSerial != null && device.machineSerial!.isNotEmpty ? '  •  S/N: ${device.machineSerial}' : ''}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (device.hostName != null &&
                        device.hostName!.isNotEmpty &&
                        device.hostName != device.displayName) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Host: ${device.hostName}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _infoSection(
                  title: 'Device',
                  children: [
                    if (device.machineModelName != null &&
                        device.machineModelName!.isNotEmpty)
                      _statItem(Icons.precision_manufacturing, 'Model',
                          device.machineModelName!),
                    if (device.machineProfileLabel != null &&
                        device.machineProfileLabel!.isNotEmpty)
                      _statItem(Icons.grid_view, 'Panel',
                          device.machineProfileLabel!),
                    if (device.machineLcdType != null &&
                        device.machineLcdType!.isNotEmpty)
                      _statItem(
                          Icons.display_settings, 'LCD', device.machineLcdType!),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _infoSection(
                  title: 'Status',
                  children: [
                    if (device.status != null && device.status!.isNotEmpty)
                      _statItem(Icons.info_outline, 'Status', device.status!),
                    if (device.state != null && device.state!.isNotEmpty)
                      _statItem(Icons.tune, 'State', device.state!),
                    if (device.printing != null)
                      _statItem(Icons.play_circle, 'Printing',
                          device.printing! ? 'Yes' : 'No'),
                    if (device.progress != null)
                      _statItem(Icons.trending_up, 'Progress',
                          _formatProgress(device.progress)),
                    if (device.lastSeen != null)
                      _statItem(Icons.access_time, 'Seen',
                          _formatLastSeen(device.lastSeen)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: 'View status',
                    onPressed: () => _showDeviceStatus(device),
                    color: Colors.white.withValues(alpha: 0.6),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    padding: const EdgeInsets.all(8),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Refresh status',
                    onPressed: () => _refreshDeviceStatus(device),
                    color: Colors.white.withValues(alpha: 0.6),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    padding: const EdgeInsets.all(8),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  _buildActivePrinterButton(device),
                  ElevatedButton.icon(
                    onPressed: _isUploading ? null : () => _uploadToDevice(device),
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('Upload'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUploadStatus() {
    final isError = _uploadMessage?.toLowerCase().contains('fail') ?? false;
    return Card(
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isError
                  ? Colors.red.withValues(alpha: 0.6)
                  : Colors.greenAccent.withValues(alpha: 0.6),
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle,
              color: isError ? Colors.redAccent : Colors.greenAccent,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _uploadMessage!,
                style: TextStyle(
                  color: isError ? Colors.redAccent : Colors.greenAccent,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _infoSection({
    required String title,
    required List<Widget> children,
  }) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: children,
          ),
        ],
      ),
    );
  }

  Widget _statItem(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.6)),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildActivePrinterButton(NanoDlpDevice device) {
    final isActive = widget.activeDevice?.cacheKey == device.cacheKey;
    if (isActive) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.check_circle, size: 18),
        label: const Text('Active Printer'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.tealAccent.withValues(alpha: 0.2),
          foregroundColor: Colors.tealAccent,
          side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.5)),
        ),
        onPressed: () => widget.onSetActiveDevice(null), // Click to deselect
      );
    }
    return OutlinedButton.icon(
      onPressed: () => widget.onSetActiveDevice(device),
      icon: const Icon(Icons.gps_fixed, size: 18),
      label: const Text('Set Active'),
    );
  }


  String _formatProgress(double? progress) {
    if (progress == null) return '-';
    final p = progress > 1 ? progress : progress * 100.0;
    return '${p.toStringAsFixed(1)}%';
  }

  String _formatLastSeen(DateTime? dt) {
    if (dt == null) return '-';
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

}

class _ImportOptions {
  final String jobName;
  final ResinProfile resin;

  const _ImportOptions({
    required this.jobName,
    required this.resin,
  });
}
