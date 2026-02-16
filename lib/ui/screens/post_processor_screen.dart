import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/conversion/converter.dart';
import '../../core/conversion/profile_detector.dart';
import '../../core/models/models.dart';
import '../../core/network/app_settings.dart';
import '../../core/network/device_cache.dart';
import '../../core/network/nanodlp_client.dart';
import 'settings_screen.dart';

/// Processing phases for the post-processor flow.
enum _Phase { loading, converting, converted, uploading, complete, error }

/// Post-processor mode: minimal UI for automated conversion/upload.
/// Designed to be called by other slicers with a CTB file path as argument.
class PostProcessorScreen extends StatefulWidget {
  final String ctbFilePath;
  final NanoDlpDevice? activeDevice;
  final ValueChanged<NanoDlpDevice> onSetActiveDevice;

  const PostProcessorScreen({
    super.key,
    required this.ctbFilePath,
    this.activeDevice,
    required this.onSetActiveDevice,
  });

  @override
  State<PostProcessorScreen> createState() => _PostProcessorScreenState();
}

class _PostProcessorScreenState extends State<PostProcessorScreen> {
  final _converter = CtbToNanoDlpConverter();
  final _cache = DeviceCache();

  SliceFileInfo? _fileInfo;
  PrinterProfile? _selectedProfile;

  ConversionResult? _result;
  String? _errorMessage;
  _Phase _phase = _Phase.loading;

  double _convertProgress = 0.0;
  double _uploadProgress = 0.0;
  bool _isDeviceProcessing = false;
  int? _uploadedPlateId;
  bool _isStartingPrint = false;
  ConversionProgress? _conversionProgress;
  ConversionProgress? _pendingConversionProgress;
  bool _hasPendingConversionUiUpdate = false;
  DateTime? _conversionSampleAt;
  int _conversionSampleCount = 0;
  double? _conversionRateLayersPerSec;
  double? _pendingConversionRateLayersPerSec;
  String? _lastConversionPhase;
  Timer? _conversionUiTicker;

  DateTime? _uploadSampleAt;
  double _uploadSampleProgress = 0.0;
  int _uploadTotalBytes = 0;
  double? _uploadRateMbPerSec;
  DateTime? _deviceProcessingStartedAt;
  Timer? _deviceProcessingTicker;
  DateTime? _processStartedAt;
  DateTime? _processEndedAt;

  // Background mode options
  bool _runInBackground = false;
  bool _autoStartPrint = false;
  bool _useAsDefault = false;
  bool _isResinLoading = false;
  List<ResinProfile> _resinProfiles = [];
  ResinProfile? _selectedResin;
  bool _backgroundDialogShown = false;

  DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _converter.addLogListener(_onLog);
    _loadCachedDevices();
    _loadFile();
  }

  @override
  void dispose() {
    _stopConversionUiTicker();
    _stopDeviceProcessingTicker();
    _converter.removeLogListener(_onLog);
    super.dispose();
  }

  void _startDeviceProcessingTicker() {
    _deviceProcessingTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!(_phase == _Phase.uploading && _isDeviceProcessing)) {
        _stopDeviceProcessingTicker();
        return;
      }
      setState(() {});
    });
  }

  void _stopDeviceProcessingTicker() {
    _deviceProcessingTicker?.cancel();
    _deviceProcessingTicker = null;
  }

  void _startConversionUiTicker() {
    _conversionUiTicker ??= Timer.periodic(const Duration(milliseconds: 220), (
      _,
    ) {
      if (!mounted) return;
      if (_phase != _Phase.converting) {
        _stopConversionUiTicker();
        return;
      }
      if (!_hasPendingConversionUiUpdate) return;

      final pending = _pendingConversionProgress;
      if (pending == null) return;

      _hasPendingConversionUiUpdate = false;
      setState(() {
        _conversionProgress = pending;
        _convertProgress = pending.fraction;
        _conversionRateLayersPerSec = _pendingConversionRateLayersPerSec;
      });
    });
  }

  void _stopConversionUiTicker() {
    _conversionUiTicker?.cancel();
    _conversionUiTicker = null;
  }

  void _onLog(String msg) {
    debugPrint('[PostProcessor] $msg');
  }

  bool _shouldUpdateProgress(double nextValue) {
    if (nextValue >= 1.0 && _uploadProgress < 1.0) return true;
    final now = DateTime.now();
    final elapsed = now.difference(_lastProgressUpdate).inMilliseconds;
    final isHeavyConverting =
        _phase == _Phase.converting && (_conversionProgress?.workers ?? 0) >= 9;
    final minIntervalMs = isHeavyConverting ? 500 : 250;
    final minDelta = isHeavyConverting ? 0.04 : 0.02;
    if (elapsed < minIntervalMs &&
        (nextValue - _convertProgress).abs() < minDelta) {
      return false;
    }
    _lastProgressUpdate = now;
    return true;
  }

  Future<void> _loadResinProfiles() async {
    final device = widget.activeDevice;
    if (device == null || _isResinLoading) return;

    setState(() => _isResinLoading = true);
    final client = NanoDlpClient(device);
    try {
      final profiles = await client.listResinProfiles();
      var selectable = profiles.where((p) => !p.locked).toList();

      // Filter by layer height if we have file info
      final ctbLayerHeightUm = (_fileInfo != null)
          ? (_fileInfo!.layerHeight * 1000).round()
          : null;
      if (ctbLayerHeightUm != null) {
        final matchingProfiles = selectable.where((p) {
          // Try 1: Check Depth field (layer height in microns)
          final depth = p.raw['Depth'] ?? p.raw['depth'];
          if (depth != null) {
            final profileDepthUm = (depth is int)
                ? depth
                : int.tryParse('$depth');
            if (profileDepthUm != null && profileDepthUm == ctbLayerHeightUm) {
              return true;
            }
          }

          // Try 2: Parse layer height from profile name (e.g., "50μm" or "30µm")
          final nameMatch = RegExp(
            r'(\d+)\s*[uµ]m',
            caseSensitive: false,
          ).firstMatch(p.name);
          if (nameMatch != null) {
            final nameLayerHeight = int.tryParse(nameMatch.group(1)!);
            if (nameLayerHeight != null &&
                nameLayerHeight == ctbLayerHeightUm) {
              return true;
            }
          }

          return false;
        }).toList();

        // Only use filtered list if we found matches
        if (matchingProfiles.isNotEmpty) {
          selectable = matchingProfiles;
        }
      }

      if (!mounted) return;
      setState(() {
        _resinProfiles = selectable;
        _selectedResin ??= selectable.isNotEmpty ? selectable.first : null;
      });
    } finally {
      client.dispose();
      if (mounted) setState(() => _isResinLoading = false);
    }
  }

  Future<void> _showBackgroundOptionsDialog() async {
    if (widget.activeDevice == null) return;
    if (_resinProfiles.isEmpty && !_isResinLoading) {
      _loadResinProfiles();
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(32),
              constraints: const BoxConstraints(maxWidth: 500),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 32,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.25),
                              Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.15),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.2),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.science_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Select Material Profile',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.3,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Choose your resin',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF94A3B8),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_isResinLoading)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Column(
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Loading material profiles…',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MATERIAL PROFILE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                              width: 1.5,
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<ResinProfile>(
                              value: _selectedResin,
                              isExpanded: true,
                              dropdownColor: const Color(0xFF16213E),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              icon: Icon(
                                Icons.arrow_drop_down,
                                color: Colors.white.withValues(alpha: 0.7),
                                size: 28,
                              ),
                              onChanged: (p) {
                                setDialogState(() => _selectedResin = p);
                              },
                              items: _resinProfiles.map((profile) {
                                return DropdownMenuItem(
                                  value: profile,
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            ctx,
                                          ).colorScheme.primary,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          profile.name,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF0F172A,
                            ).withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ADVANCED OPTIONS',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                  color: Colors.white.withValues(alpha: 0.4),
                                ),
                              ),
                              const SizedBox(height: 10),
                              InkWell(
                                onTap: () {
                                  setDialogState(
                                    () => _useAsDefault = !_useAsDefault,
                                  );
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: Checkbox(
                                          value: _useAsDefault,
                                          onChanged: (val) => setDialogState(
                                            () => _useAsDefault = val ?? false,
                                          ),
                                          activeColor: Theme.of(
                                            ctx,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Use as default',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              'Remember this choice for future conversions',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.white.withValues(
                                                  alpha: 0.5,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              InkWell(
                                onTap: () {
                                  setDialogState(
                                    () => _autoStartPrint = !_autoStartPrint,
                                  );
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: Checkbox(
                                          value: _autoStartPrint,
                                          onChanged: (val) => setDialogState(
                                            () =>
                                                _autoStartPrint = val ?? false,
                                          ),
                                          activeColor: Theme.of(
                                            ctx,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Auto-start print',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              'Begin printing immediately after upload',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.white.withValues(
                                                  alpha: 0.5,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: BorderSide(color: Colors.grey.shade700),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: _selectedResin == null
                              ? null
                              : () async {
                                  // Save as default if checkbox is set
                                  if (_useAsDefault && _selectedResin != null) {
                                    final settings = await AppSettings.load();
                                    settings.defaultMaterialProfileId =
                                        _selectedResin!.profileId;
                                    await settings.save();
                                  }
                                  setState(() => _runInBackground = true);
                                  Navigator.of(ctx).pop();
                                },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: Theme.of(ctx).colorScheme.primary,
                            foregroundColor: Colors.black,
                            disabledBackgroundColor: Colors.grey.shade800,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.check_circle_outline, size: 18),
                              const SizedBox(width: 8),
                              const Text(
                                'Continue',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSettingsDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.settings,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Post-processing Settings',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                const Expanded(child: SettingsScreen()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadCachedDevices() async {
    await _cache.load();
    if (mounted) {}
  }

  String? _getResolutionLabel(int resolutionX) {
    if (resolutionX >= 14500 && resolutionX <= 15400) return '16K';
    if (resolutionX >= 11300 && resolutionX <= 11700) return '12K';
    if (resolutionX >= 7500 && resolutionX <= 7900) return '8K';
    if (resolutionX >= 4800 && resolutionX <= 5200) return '4K';
    return null;
  }

  Future<void> _showResolutionMismatchWarning(
    String ctbLabel,
    String deviceLabel,
    int ctbResX,
  ) async {
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(28),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 32,
                  spreadRadius: 8,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.4),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text(
                        'Resolution Mismatch',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'This CTB file cannot be converted for the selected printer. It will fail:',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.35),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'CTB File',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withValues(alpha: 0.5),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              ctbLabel,
                              style: const TextStyle(
                                fontSize: 16,
                                color: Colors.orange,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$ctbResX px',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.orange.withValues(alpha: 0.6),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.cyan.withValues(alpha: 0.35),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Printer',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withValues(alpha: 0.5),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              deviceLabel,
                              style: const TextStyle(
                                fontSize: 16,
                                color: Colors.cyan,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.activeDevice?.displayName ?? 'Unknown',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.cyan.withValues(alpha: 0.6),
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'To fix this, do one of:',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ...[
                  'Re-slice the model for your $deviceLabel printer',
                  'Load a different $deviceLabel CTB file',
                  'Switch to a printer that matches this $ctbLabel file',
                ].map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 8),
                          child: Text(
                            '•',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            item,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCorruptLayersWarning(List<int> corruptLayers) async {
    if (!mounted || corruptLayers.isEmpty) return;

    final preview = corruptLayers.take(10).map((i) => i + 1).toList();
    final suffix = corruptLayers.length > 10 ? '…' : '';
    final layerList = '${preview.join(', ')}$suffix';

    await showDialog(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(28),
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 32,
                  spreadRadius: 8,
                ),
              ],
            ),
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
                        color: Colors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.35),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Possible Corrupt Layers',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Detected ${corruptLayers.length} layer(s) that appear fully black or white. This can indicate a corrupt CTB file:',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    'Layers: $layerList',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Continue'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadFile() async {
    try {
      final info = await _converter.readFileInfo(widget.ctbFilePath);
      final profiles = PrinterProfileDetector.getTargetProfilesForResolution(
        info.resolutionX,
        info.resolutionY,
      );

      // Check for corrupt layers (warning only)
      final corruptLayers = await _converter.checkForCorruptLayers(
        widget.ctbFilePath,
      );
      if (mounted && corruptLayers.isNotEmpty) {
        await _showCorruptLayersWarning(corruptLayers);
      }

      // Check for resolution mismatch (block conversion)
      if (widget.activeDevice?.machineResolutionX != null) {
        final deviceResX = widget.activeDevice!.machineResolutionX!;
        final deviceLabel = _getResolutionLabel(deviceResX);
        final ctbLabel = _getResolutionLabel(info.resolutionX);
        if (deviceLabel != null &&
            ctbLabel != null &&
            deviceLabel != ctbLabel) {
          if (mounted) {
            await _showResolutionMismatchWarning(
              ctbLabel,
              deviceLabel,
              info.resolutionX,
            );
            setState(() {
              _errorMessage =
                  'Resolution mismatch: $ctbLabel file on $deviceLabel printer';
              _phase = _Phase.error;
            });
          }
          return;
        }
      }

      if (!mounted) return;

      // Auto-select profile by active device
      PrinterProfile? selectedProfile;
      if (widget.activeDevice != null) {
        final activeLabel =
            widget.activeDevice!.machineLcdType ??
            widget.activeDevice!.machineProfileLabel;
        if (activeLabel != null) {
          final lowerLabel = activeLabel.toLowerCase();
          final is3Bit =
              lowerLabel.contains('3bit') ||
              lowerLabel.contains('3-bit') ||
              lowerLabel.contains('3 bit');
          final board = is3Bit ? BoardType.twoBit3Subpixel : BoardType.rgb8Bit;
          selectedProfile = profiles.firstWhere(
            (p) => p.board == board,
            orElse: () => profiles.first,
          );
        }
      }
      selectedProfile ??= profiles.first;

      setState(() {
        _fileInfo = info;
        _selectedProfile = selectedProfile;
      });

      if (widget.activeDevice != null && mounted) {
        // Load settings to check for default profile
        final settings = await AppSettings.load();

        // Skip dialog if we have a default profile saved
        if (settings.defaultMaterialProfileId != null) {
          // Use default profile if available
          if (mounted) {
            _backgroundDialogShown = true;
            _startConversion();
          }
          return;
        }

        // No default profile: show material selection dialog
        if (mounted && !_backgroundDialogShown) {
          _backgroundDialogShown = true;
          await _loadResinProfiles();
          await _showBackgroundOptionsDialog();
        }
        if (mounted) _startConversion();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load file: $e';
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _startConversion() async {
    if (widget.ctbFilePath.isEmpty || _selectedProfile == null) return;

    setState(() {
      _phase = _Phase.converting;
      _errorMessage = null;
      _result = null;
      _convertProgress = 0.0;
      _processStartedAt = DateTime.now();
      _processEndedAt = null;
      _conversionProgress = null;
      _pendingConversionProgress = null;
      _hasPendingConversionUiUpdate = false;
      _conversionSampleAt = null;
      _conversionSampleCount = 0;
      _conversionRateLayersPerSec = null;
      _pendingConversionRateLayersPerSec = null;
      _lastConversionPhase = null;
    });
    _startConversionUiTicker();

    try {
      final result = await _converter.convert(
        widget.ctbFilePath,
        options: ConversionOptions(targetProfile: _selectedProfile),
        onProgress: (p) {
          if (!mounted) return;
          _pendingConversionProgress = p;

          final phaseChanged = _lastConversionPhase != p.phase;
          if (phaseChanged) {
            _lastConversionPhase = p.phase;
            _conversionSampleAt = null;
            _conversionSampleCount = p.current;
            _pendingConversionRateLayersPerSec = null;
          }

          final shouldTrackThroughput =
              _isThroughputPhase(p.phase) && p.total > 0;

          final now = DateTime.now();
          final sampleAt = _conversionSampleAt;
          if (shouldTrackThroughput) {
            if (sampleAt != null) {
              final dtMs = now.difference(sampleAt).inMilliseconds;
              final dCount = p.current - _conversionSampleCount;
              if (dtMs >= 400 && dCount > 0) {
                final instantRate = dCount / (dtMs / 1000.0);
                _pendingConversionRateLayersPerSec =
                    _pendingConversionRateLayersPerSec == null
                    ? instantRate
                    : ((_pendingConversionRateLayersPerSec! * 0.65) +
                          (instantRate * 0.35));
                _conversionSampleAt = now;
                _conversionSampleCount = p.current;
              }
            } else {
              _conversionSampleAt = now;
              _conversionSampleCount = p.current;
            }
          } else {
            _pendingConversionRateLayersPerSec = null;
            _conversionSampleAt = null;
            _conversionSampleCount = p.current;
          }

          if (_shouldUpdateProgress(p.fraction)) {
            _hasPendingConversionUiUpdate = true;
          }
        },
      );

      if (!mounted) return;
      _stopConversionUiTicker();

      // Store result and go straight to upload (skip intermediate screen)
      setState(() {
        _result = result;
      });

      if (result.success && widget.activeDevice != null) {
        if (mounted) {
          _startUpload();
        }
      } else if (mounted) {
        // Failed: show converted phase with error
        setState(() {
          _phase = _Phase.converted;
        });
      }
    } catch (e) {
      _stopConversionUiTicker();
      setState(() {
        _errorMessage = 'Conversion failed: $e';
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _startUpload() async {
    if (_result == null || widget.activeDevice == null) return;

    final device = widget.activeDevice!;
    final outputPath = _result!.outputPath;
    final client = NanoDlpClient(device);

    try {
      // Get available profiles
      final profiles = await client.listResinProfiles();
      var selectable = profiles.where((p) => !p.locked).toList();

      // Filter by layer height if we have file info
      final ctbLayerHeightUm = (_fileInfo != null)
          ? (_fileInfo!.layerHeight * 1000).round()
          : null;
      if (ctbLayerHeightUm != null) {
        final matchingProfiles = selectable.where((p) {
          // Try 1: Check Depth field (layer height in microns)
          final depth = p.raw['Depth'] ?? p.raw['depth'];
          if (depth != null) {
            final profileDepthUm = (depth is int)
                ? depth
                : int.tryParse('$depth');
            if (profileDepthUm != null && profileDepthUm == ctbLayerHeightUm) {
              return true;
            }
          }

          // Try 2: Parse layer height from profile name (e.g., "50μm" or "30µm")
          final nameMatch = RegExp(
            r'(\d+)\s*[uµ]m',
            caseSensitive: false,
          ).firstMatch(p.name);
          if (nameMatch != null) {
            final nameLayerHeight = int.tryParse(nameMatch.group(1)!);
            if (nameLayerHeight != null &&
                nameLayerHeight == ctbLayerHeightUm) {
              return true;
            }
          }

          return false;
        }).toList();

        // Only use filtered list if we found matches
        if (matchingProfiles.isNotEmpty) {
          selectable = matchingProfiles;
        }
      }

      if (selectable.isEmpty) {
        setState(() {
          _errorMessage = 'No material profiles on device';
          _phase = _Phase.error;
        });
        client.dispose();
        return;
      }

      // Check for default material profile or background selection
      final settings = await AppSettings.load();
      ResinProfile? selectedResin = _runInBackground ? _selectedResin : null;

      if (selectedResin == null && settings.defaultMaterialProfileId != null) {
        selectedResin = selectable.firstWhere(
          (p) => p.profileId == settings.defaultMaterialProfileId,
          orElse: () => selectable.first,
        );
      }

      // Always show material selection if we haven't already
      if (selectedResin == null && !_backgroundDialogShown) {
        _backgroundDialogShown = true;
        selectedResin = await _showMaterialProfileDialog(selectable);
        if (selectedResin == null) {
          // User cancelled — stay on converted state
          if (mounted) {
            setState(() => _phase = _Phase.converted);
          }
          client.dispose();
          return;
        }
      } else {
        selectedResin ??= selectable.first;
      }

      // Now start uploading
      setState(() {
        _phase = _Phase.uploading;
        _uploadProgress = 0.0;
        _isDeviceProcessing = false;
        _uploadSampleAt = null;
        _uploadSampleProgress = 0.0;
        _uploadRateMbPerSec = null;
        _deviceProcessingStartedAt = null;
      });
      _stopDeviceProcessingTicker();

      _uploadTotalBytes = await File(outputPath).length();

      final jobName = widget.ctbFilePath
          .split(Platform.pathSeparator)
          .last
          .replaceAll(RegExp(r'\.[^.]*$'), '');

      // Upload
      final uploadResult = await client.importPlate(
        outputPath,
        jobName: jobName,
        profileId: selectedResin.profileId,
        onProgress: (p) {
          if (!mounted) return;

          final now = DateTime.now();
          final sampleAt = _uploadSampleAt;
          if (sampleAt != null && _uploadTotalBytes > 0) {
            final dtMs = now.difference(sampleAt).inMilliseconds;
            final dProgress = p - _uploadSampleProgress;
            if (dtMs >= 350 && dProgress > 0) {
              final bytesPerSec =
                  (dProgress * _uploadTotalBytes) / (dtMs / 1000.0);
              final mbPerSec = bytesPerSec / (1024 * 1024);
              _uploadRateMbPerSec = _uploadRateMbPerSec == null
                  ? mbPerSec
                  : ((_uploadRateMbPerSec! * 0.65) + (mbPerSec * 0.35));
              _uploadSampleAt = now;
              _uploadSampleProgress = p;
            }
          } else {
            _uploadSampleAt = now;
            _uploadSampleProgress = p;
          }

          if (_shouldUpdateProgress(p)) {
            setState(() {
              _uploadProgress = p;
              if (p >= 0.99) {
                _isDeviceProcessing = true;
                _deviceProcessingStartedAt ??= DateTime.now();
                _startDeviceProcessingTicker();
              }
            });
          }
        },
      );

      if (!uploadResult.success) {
        setState(() {
          _errorMessage = uploadResult.message ?? 'Upload failed';
          _phase = _Phase.error;
        });
        client.dispose();
        return;
      }

      // Move to post-upload processing state.
      setState(() => _uploadProgress = 1.0);

      // Wait for metadata & resolve plateId
      final plate = await client.waitForPlateReady(
        plateId: uploadResult.plateId,
        jobName: jobName,
        timeout: const Duration(minutes: 3),
        onProgress: (_) {
          // Ignore fake progress based on timeout
          if (mounted && !_isDeviceProcessing) {
            setState(() {
              _isDeviceProcessing = true;
              _deviceProcessingStartedAt ??= DateTime.now();
            });
            _startDeviceProcessingTicker();
          }
        },
      );

      int? plateId = uploadResult.plateId;
      if (plateId == null && plate != null) {
        plateId = int.tryParse(
          '${plate['PlateID'] ?? plate['plateId'] ?? plate['plate_id'] ?? plate['id'] ?? ''}',
        );
      }

      if (!mounted) return;

      setState(() {
        _phase = _Phase.complete;
        _uploadProgress = 0.0;
        _uploadedPlateId = plateId;
        _processEndedAt ??= DateTime.now();
      });
      _stopDeviceProcessingTicker();

      if (_runInBackground && _autoStartPrint && plateId != null) {
        await _startPrint();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Upload failed: $e';
        _phase = _Phase.error;
        _uploadProgress = 0.0;
      });
      _stopDeviceProcessingTicker();
    } finally {
      client.dispose();
    }
  }

  Future<ResinProfile?> _showMaterialProfileDialog(
    List<ResinProfile> profiles,
  ) async {
    ResinProfile? selectedProfile = profiles.first;
    bool setAsDefault = false;

    return showDialog<ResinProfile>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Icon(
                          Icons.science,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Select Material Profile',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Choose which material profile to use for this print:',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<ResinProfile>(
                        value: selectedProfile,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF16213E),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        icon: Icon(
                          Icons.arrow_drop_down,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                        onChanged: (profile) {
                          if (profile != null) {
                            setDialogState(() => selectedProfile = profile);
                          }
                        },
                        items: profiles.map((profile) {
                          return DropdownMenuItem(
                            value: profile,
                            child: Text(
                              profile.name,
                              style: const TextStyle(fontSize: 14),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  InkWell(
                    onTap: () {
                      setDialogState(() => setAsDefault = !setAsDefault);
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: Checkbox(
                              value: setAsDefault,
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() => setAsDefault = val);
                                }
                              },
                              activeColor: Colors.purple.shade400,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Remember this choice as default',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withValues(alpha: 0.8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () async {
                          if (setAsDefault && selectedProfile != null) {
                            final settings = await AppSettings.load();
                            settings.defaultMaterialProfileId =
                                selectedProfile!.profileId;
                            await settings.save();
                          }
                          if (!ctx.mounted) return;
                          Navigator.of(ctx).pop(selectedProfile);
                        },
                        child: const Text('Use This Profile'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startPrint() async {
    if (_uploadedPlateId == null || widget.activeDevice == null) return;

    setState(() => _isStartingPrint = true);

    final client = NanoDlpClient(widget.activeDevice!);
    try {
      final result = await client.startPrint(_uploadedPlateId!);

      if (!mounted) return;

      if (result.$1) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.$2 ?? 'Print started'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 2),
          ),
        );
        Future.delayed(const Duration(seconds: 1), () => exit(0));
      } else {
        setState(() => _isStartingPrint = false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.$2 ?? 'Failed to start print'),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isStartingPrint = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      client.dispose();
    }
  }

  void _showCancelDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
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
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Icon(
                      Icons.stop_circle_outlined,
                      color: Colors.redAccent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Cancel Processing?',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'This will stop the current conversion/upload and close the window.',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Keep Going'),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: () => exit(0),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent.withValues(alpha: 0.2),
                      foregroundColor: Colors.redAccent,
                    ),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: AppBar(
              title: const Text('VoxelShift Post-Processor'),
              centerTitle: true,
              backgroundColor: const Color(0xFF1E293B).withValues(alpha: 0.7),
              elevation: 0,
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.0),
                        Colors.white.withValues(alpha: 0.15),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              actions: const [],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F172A), Color(0xFF16213E), Color(0xFF1E293B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 500),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 500),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              final slide =
                                  Tween<Offset>(
                                    begin: const Offset(0, 0.08),
                                    end: Offset.zero,
                                  ).animate(
                                    CurvedAnimation(
                                      parent: animation,
                                      curve: Curves.easeOutCubic,
                                    ),
                                  );
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: slide,
                                  child: child,
                                ),
                              );
                            },
                            child: _buildContent(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Powered by ',
                        style: TextStyle(
                          fontFamily: 'AtkinsonHyperlegible',
                          fontSize: 18,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [
                            Color(0xFFFF9D7A),
                            Color(0xFFFF7A85),
                            Color(0xFFC49FE8),
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ).createShader(bounds),
                        child: const Text(
                          'Open Resin Alliance',
                          style: TextStyle(
                            fontFamily: 'AtkinsonHyperlegible',
                            fontSize: 18,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              left: 16,
              bottom: 16,
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: IconButton(
                      tooltip: 'Settings',
                      onPressed: _showSettingsDialog,
                      icon: const Icon(Icons.settings, size: 18),
                    ),
                  ),
                  const SizedBox(width: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: IconButton(
                      tooltip: 'Run in background',
                      onPressed: _showBackgroundOptionsDialog,
                      icon: const Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: Color(0xFF22D3EE),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: IconButton(
                  tooltip: 'Cancel',
                  onPressed: _showCancelDialog,
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    size: 18,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_phase) {
      case _Phase.error:
        return Column(
          key: const ValueKey('error'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Error',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => exit(1),
                child: const Text('Close'),
              ),
            ),
          ],
        );

      case _Phase.loading:
        if (widget.activeDevice == null && _fileInfo != null) {
          return Column(
            key: const ValueKey('no-device'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.print_disabled,
                color: Colors.orange.shade400,
                size: 48,
              ),
              const SizedBox(height: 16),
              const Text(
                'No Printer Selected',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                'Please set an active printer first',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => exit(1),
                  child: const Text('Close'),
                ),
              ),
            ],
          );
        }
        return _buildActivityWidget(
          'Loading file...',
          key: 'activity',
          color: Colors.cyan,
        );

      case _Phase.converting:
        return _buildActivityWidget(
          _displayConversionPhase(_conversionProgress?.phase),
          key: 'activity',
          progress: _convertProgress,
          color: _getColorForFileSize(),
        );

      case _Phase.converted:
        return _buildCheckpointWidget(
          'Conversion Complete',
          subtitle: '${_result?.layerCount ?? 0} layers processed',
          color: Colors.cyan,
          key: 'converted',
        );

      case _Phase.uploading:
        return _buildActivityWidget(
          _isDeviceProcessing
              ? 'Processing on device...'
              : 'Uploading to ${widget.activeDevice!.displayName}...',
          key: _isDeviceProcessing ? 'processing' : 'activity',
          progress: _uploadProgress,
          color: Colors.cyan,
          isDeviceProcessing: _isDeviceProcessing,
        );

      case _Phase.complete:
        return _buildCompleteWidget();
    }
  }

  Widget _buildActivityWidget(
    String message, {
    required String key,
    required Color color,
    double? progress,
    bool isDeviceProcessing = false,
  }) {
    return Column(
      key: ValueKey(key),
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        _SpinnerArcs(color: color),
        const SizedBox(height: 32),
        Text(
          message,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        if (progress != null) ...[
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              tween: Tween<double>(
                begin: 0,
                end: isDeviceProcessing ? 0 : progress,
              ),
              builder: (context, value, _) => LinearProgressIndicator(
                value: isDeviceProcessing ? null : value,
                color: color,
                backgroundColor: color.withValues(alpha: 0.2),
                minHeight: 9,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isDeviceProcessing
                ? 'Processing on device... This may take a while.'
                : '${(progress * 100).toStringAsFixed(0)}%'
                      '${_conversionProgress != null ? " (${_conversionProgress!.current}/${_conversionProgress!.total})" : ""}'
                      '${_conversionProgress?.workers != null ? ' • ${_conversionProgress!.workers} workers' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 30),
          _buildTelemetryContainer(isDeviceProcessing: isDeviceProcessing),
          if (_conversionProgress?.workers != null &&
              _conversionProgress!.workers! > 5) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.shade900.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.orange.shade700.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    color: Colors.orange.shade300,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Heavy processing: RGB lighting or UI may briefly stall',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.shade200,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ],
        if (progress == null) const SizedBox(height: 140),
      ],
    );
  }

  Widget _buildTelemetryContainer({required bool isDeviceProcessing}) {
    final lines = _buildTelemetryLines(isDeviceProcessing: isDeviceProcessing);
    final hasLines = lines.isNotEmpty;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: hasLines ? 1.0 : 0.35,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: SizedBox(
          height: 90,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: hasLines
                ? lines
                : [
                    Text(
                      'Metrics will appear here during processing.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTelemetryLines({required bool isDeviceProcessing}) {
    final lines = <String>[];

    if (_phase == _Phase.converting) {
      final phaseText = (_conversionProgress?.phase ?? '').toLowerCase();
      final board = _selectedProfile?.board == BoardType.twoBit3Subpixel
          ? '3-bit subpixel'
          : '8-bit RGB';

      String mode;
      if (phaseText.contains('reading')) {
        mode = 'I/O decode';
      } else if (phaseText.contains('processing')) {
        mode = 'CPU layer processing';
      } else if (phaseText.contains('compressing')) {
        mode = 'Compression pass';
      } else if (phaseText.contains('writing')) {
        mode = 'Packaging/ZIP write';
      } else {
        mode = 'Initialization';
      }

      lines.add('$mode • $board');

      if (phaseText.contains('compressing')) {
        lines.add('PNG recompress • zlib level 7 (adaptive)');
      } else if (phaseText.contains('processing')) {
        lines.add('PNG encode • Up filter + zlib level 1');
        final engine = _extractEngineFromPhase(_conversionProgress?.phase);
        if (engine != null && engine.isNotEmpty) {
          lines.add(engine);
        }
      } else if (phaseText.contains('writing')) {
        lines.add('NanoDLP packaging');
      }

      // Throughput is only meaningful outside the lightweight read phase.
      final rate = _conversionRateLayersPerSec;
      if (!phaseText.contains('reading') && rate != null && rate > 0) {
        lines.add('${rate.toStringAsFixed(1)} layers/s');
      }
    } else if (_phase == _Phase.uploading) {
      if (isDeviceProcessing) {
        final started = _deviceProcessingStartedAt;
        if (started == null) {
          lines.add('Device-side processing');
        } else {
          final elapsed = DateTime.now().difference(started);
          final mm = elapsed.inMinutes;
          final ss = elapsed.inSeconds % 60;
          lines.add(
            'Device processing • ${mm}m ${ss.toString().padLeft(2, '0')}s',
          );
        }
      } else {
        lines.add('Network upload');
        final rate = _uploadRateMbPerSec;
        if (rate != null && rate > 0) {
          lines.add('${rate.toStringAsFixed(2)} MB/s');
        }
      }
    }

    if (lines.isEmpty) return const [];

    return lines
        .map(
          (line) => Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              line,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        )
        .toList();
  }

  Color _getColorForFileSize() {
    final layers = _result?.layerCount ?? 0;

    // Thresholds: 50 layers (orange), 150 layers (deep orange), 300 layers+ (red)
    if (layers >= 300) {
      return Colors.red.shade600;
    } else if (layers >= 150) {
      return Colors.deepOrange.shade500;
    } else if (layers >= 50) {
      return Colors.orange.shade500;
    } else {
      return Colors.cyan;
    }
  }

  bool _isThroughputPhase(String phase) {
    final p = phase.toLowerCase();
    return p.contains('processing') ||
        p.contains('compressing') ||
        p.contains('writing');
  }

  String _displayConversionPhase(String? rawPhase) {
    if (rawPhase == null || rawPhase.isEmpty) return 'Initializing...';
    // Remove bracketed engine hints from the main header.
    return rawPhase.replaceAll(RegExp(r'\s*\[.*?\]\s*'), '').trim();
  }

  String? _extractEngineFromPhase(String? phase) {
    if (phase == null) return null;
    final match = RegExp(r'\[(.*?)\]').firstMatch(phase);
    return match?.group(1);
  }

  Widget _buildCheckpointWidget(
    String title, {
    String? subtitle,
    required Color color,
    required String key,
  }) {
    return Column(
      key: ValueKey(key),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutBack,
          tween: Tween(begin: 0.0, end: 1.0),
          builder: (context, scale, _) {
            return Transform.scale(
              scale: scale,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [color.withValues(alpha: 0.8), color],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 44),
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCompleteWidget() {
    final totalDuration = _processStartedAt != null
        ? (_processEndedAt ?? DateTime.now()).difference(_processStartedAt!)
        : null;
    final totalDurationText = totalDuration == null
        ? null
        : '${totalDuration.inMinutes}m ${(totalDuration.inSeconds % 60).toString().padLeft(2, '0')}s';

    return Column(
      key: const ValueKey('complete'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutBack,
          tween: Tween(begin: 0.0, end: 1.0),
          builder: (context, scale, _) {
            return Transform.scale(
              scale: scale,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      width: 86,
                      height: 86,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            Colors.green.shade400,
                            Colors.green.shade700,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.green.withValues(alpha: 0.4),
                            blurRadius: 22,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Upload Complete',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Your plate is ready on ${widget.activeDevice!.displayName}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        _StatusPill(
                          label: 'Ready to print',
                          icon: Icons.local_printshop_outlined,
                          color: Colors.green.shade300,
                        ),
                        if (_uploadedPlateId != null)
                          _StatusPill(
                            label: 'Plate #${_uploadedPlateId!}',
                            icon: Icons.layers_outlined,
                            color: Colors.cyanAccent.shade100,
                          ),
                        if (totalDurationText != null)
                          _StatusPill(
                            label: 'Total time $totalDurationText',
                            icon: Icons.timer_outlined,
                            color: Colors.purpleAccent.shade100,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        if (_uploadedPlateId != null) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isStartingPrint ? null : _startPrint,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple.shade700,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _isStartingPrint
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.play_arrow, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'Start Print',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _isStartingPrint ? null : () => exit(0),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.grey.shade700),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Close'),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _StatusPill({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated spinner arcs that visibly rotate.
class _SpinnerArcs extends StatefulWidget {
  final Color color;
  const _SpinnerArcs({required this.color});

  @override
  State<_SpinnerArcs> createState() => _SpinnerArcsState();
}

class _SpinnerArcsState extends State<_SpinnerArcs>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outerTurns = Tween<double>(begin: 0, end: 1).animate(_controller);
    final middleTurns = Tween<double>(begin: 0, end: -2).animate(_controller);
    final innerTurns = Tween<double>(begin: 0, end: 3).animate(_controller);

    return SizedBox(
      width: 80,
      height: 80,
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          children: [
            RotationTransition(
              turns: outerTurns,
              child: SizedBox(
                width: 80,
                height: 80,
                child: CustomPaint(
                  painter: _StaticArcPainter(
                    sweepAngle: math.pi * 0.8,
                    strokeWidth: 2.5,
                    alpha: 0.30,
                    color: widget.color,
                  ),
                ),
              ),
            ),
            RotationTransition(
              turns: middleTurns,
              child: SizedBox(
                width: 56,
                height: 56,
                child: CustomPaint(
                  painter: _StaticArcPainter(
                    sweepAngle: math.pi * 0.6,
                    strokeWidth: 2.5,
                    alpha: 0.55,
                    color: widget.color,
                  ),
                ),
              ),
            ),
            RotationTransition(
              turns: innerTurns,
              child: SizedBox(
                width: 36,
                height: 36,
                child: CustomPaint(
                  painter: _StaticArcPainter(
                    sweepAngle: math.pi * 0.5,
                    strokeWidth: 2.5,
                    alpha: 1.0,
                    color: widget.color,
                  ),
                ),
              ),
            ),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.9),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.35),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaticArcPainter extends CustomPainter {
  final double sweepAngle;
  final double strokeWidth;
  final double alpha;
  final Color color;

  const _StaticArcPainter({
    required this.sweepAngle,
    required this.strokeWidth,
    required this.alpha,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - (strokeWidth / 2);
    final paint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_StaticArcPainter oldDelegate) {
    return oldDelegate.sweepAngle != sweepAngle ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.alpha != alpha ||
        oldDelegate.color != color;
  }
}

class _AnimatedProcessingBlock extends StatefulWidget {
  final Color primaryColor;

  const _AnimatedProcessingBlock({required this.primaryColor});

  @override
  State<_AnimatedProcessingBlock> createState() =>
      _AnimatedProcessingBlockState();
}

class _AnimatedProcessingBlockState extends State<_AnimatedProcessingBlock>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final progress = _controller.value;
          final countT = Curves.easeInOut.transform(progress);
          final popT = Curves.easeOutBack.transform(progress);
          final numSlices = (countT * 6).toInt() + 1;
          final separation = popT * 18;

          return CustomPaint(
            painter: _CubeSlicePainter(
              primaryColor: widget.primaryColor,
              sliceCount: numSlices,
              separation: separation,
            ),
            size: const Size(120, 120),
          );
        },
      ),
    );
  }
}

class _CubeSlicePainter extends CustomPainter {
  final Color primaryColor;
  final int sliceCount;
  final double separation;

  _CubeSlicePainter({
    required this.primaryColor,
    required this.sliceCount,
    required this.separation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final outlineStroke = Paint()
      ..color = primaryColor.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    const double cubeSize = 85;
    const double depth = 20;
    const double cornerRadius = 4;

    final baseRect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: cubeSize,
      height: cubeSize,
    );

    final sliceHeight = cubeSize / sliceCount;

    // Draw slices from back to front for proper 3D occlusion
    for (int i = 0; i < sliceCount; i++) {
      // Calculate offset from center for peeling effect
      final centerIndex = sliceCount / 2.0;
      final distanceFromCenter = (i - centerIndex).abs();

      // Add wavy motion with sine for peeling effect
      final waveAmount =
          math.sin((i / sliceCount) * math.pi) * separation * 0.3;
      final sliceVerticalOffset =
          distanceFromCenter * separation * (i < centerIndex ? -0.5 : 0.5);
      final sliceHorizontalOffset = waveAmount;

      final sliceTop = baseRect.top + (sliceHeight * i) + sliceVerticalOffset;
      final sliceLeft = baseRect.left + sliceHorizontalOffset;

      final sliceRect = Rect.fromLTWH(
        sliceLeft,
        sliceTop,
        cubeSize,
        sliceHeight - 1,
      );

      // Create gradient fill for bubbly gel effect
      final gradientFill = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            primaryColor.withValues(alpha: 0.25),
            primaryColor.withValues(alpha: 0.1),
          ],
        ).createShader(sliceRect)
        ..style = PaintingStyle.fill;

      // Draw front face with rounded corners for bubble effect
      final frontRRect = RRect.fromRectAndRadius(
        sliceRect,
        const Radius.circular(cornerRadius),
      );
      canvas.drawRRect(frontRRect, gradientFill);
      canvas.drawRRect(frontRRect, outlineStroke);

      // Draw 3D depth faces
      final topRight = Offset(
        sliceRect.right + depth / 3,
        sliceRect.top - depth / 3,
      );
      final bottomRight = Offset(
        sliceRect.right + depth / 3,
        sliceRect.bottom - depth / 3,
      );
      final topLeft = Offset(
        sliceRect.left + depth / 4,
        sliceRect.top - depth / 4,
      );

      // Right face - slightly darker for depth
      final rightFill = Paint()
        ..color = primaryColor.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill;
      final rightPath = Path()
        ..moveTo(sliceRect.right, sliceRect.top)
        ..lineTo(topRight.dx, topRight.dy)
        ..lineTo(bottomRight.dx, bottomRight.dy)
        ..lineTo(sliceRect.right, sliceRect.bottom)
        ..close();
      canvas.drawPath(rightPath, rightFill);
      canvas.drawPath(rightPath, outlineStroke);

      // Top face - lighter for gel bubble effect
      final topFill = Paint()
        ..color = primaryColor.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill;
      final topPath = Path()
        ..moveTo(sliceRect.left, sliceRect.top)
        ..lineTo(topLeft.dx, topLeft.dy)
        ..lineTo(topRight.dx, topRight.dy)
        ..lineTo(sliceRect.right, sliceRect.top)
        ..close();
      canvas.drawPath(topPath, topFill);
      canvas.drawPath(topPath, outlineStroke);
    }
  }

  @override
  bool shouldRepaint(_CubeSlicePainter oldDelegate) {
    return oldDelegate.sliceCount != sliceCount ||
        oldDelegate.separation != separation ||
        oldDelegate.primaryColor != primaryColor;
  }
}
