import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/conversion/converter.dart';
import '../../core/conversion/profile_detector.dart';
import '../../core/models/models.dart';
import '../../core/network/device_cache.dart';
import '../../core/network/nanodlp_client.dart';

/// Conversion screen: pick CTB → choose profile → convert → result.
class ConversionScreen extends StatefulWidget {
  final NanoDlpDevice? activeDevice;

  const ConversionScreen({super.key, this.activeDevice});

  @override
  State<ConversionScreen> createState() => _ConversionScreenState();
}

class _ConversionScreenState extends State<ConversionScreen> {
  final _converter = CtbToNanoDlpConverter();
  final _cache = DeviceCache();
  final _logKey = GlobalKey<_LogSectionState>();
  final List<String> _logBuffer = [];
  Timer? _logFlushTimer;
  bool _hasLogs = false;
  List<NanoDlpDevice> _cachedDevices = [];

  // File + info
  String? _selectedFilePath;
  SliceFileInfo? _fileInfo;

  // Profile selection
  List<PrinterProfile> _availableProfiles = [];
  PrinterProfile? _selectedProfile;

  // Conversion
  bool _isConverting = false;
  bool? _uploadAfterConversion; // Track which action was clicked
  bool _isUploading = false;
  ConversionProgress? _progress;
  ConversionResult? _result;
  String? _errorMessage;

  // Upload cancellation
  bool _cancelUpload = false;

  // File details expansion
  bool _showFileDetailsExposure = false;

  // Material profile selection for upload
  List<ResinProfile> _resinProfiles = [];
  ResinProfile? _materialProfile;
  bool _autoStartPrint = false;
  bool _isResinLoading = false;

  // Progress update key to rebuild only the progress widget when needed
  final _progressKey = GlobalKey<_ProgressSectionState>();

  @override
  void initState() {
    super.initState();
    _converter.addLogListener(_onLog);
    _loadCachedDevices();
  }

  Future<void> _loadCachedDevices() async {
    final devices = await _cache.load();
    if (mounted) {
      setState(() => _cachedDevices = devices);
    }
  }

  @override
  void didUpdateWidget(covariant ConversionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-evaluate profile selection when active device changes
    final oldKey = oldWidget.activeDevice?.cacheKey;
    final newKey = widget.activeDevice?.cacheKey;
    debugPrint(
      '[didUpdateWidget] oldDevice=${oldWidget.activeDevice?.displayName} (key=$oldKey)',
    );
    debugPrint(
      '[didUpdateWidget] newDevice=${widget.activeDevice?.displayName} (key=$newKey)',
    );
    debugPrint(
      '[didUpdateWidget] hasFileInfo=${_fileInfo != null} profileCount=${_availableProfiles.length}',
    );
    if (newKey != oldKey &&
        _fileInfo != null &&
        _availableProfiles.isNotEmpty) {
      debugPrint('[didUpdateWidget] Re-evaluating profile selection...');
      setState(() {
        _selectedProfile = _autoSelectProfile(_availableProfiles, _fileInfo!);
      });
    }
  }

  @override
  void dispose() {
    _converter.removeLogListener(_onLog);
    _logFlushTimer?.cancel();
    super.dispose();
  }

  void _onLog(String msg) {
    if (!mounted) return;
    _logBuffer.add(msg);
    if (!_hasLogs) {
      setState(() => _hasLogs = true);
    }
    _logFlushTimer ??= Timer(const Duration(milliseconds: 200), _flushLogs);
  }

  void _flushLogs() {
    _logFlushTimer?.cancel();
    _logFlushTimer = null;
    if (!mounted || _logBuffer.isEmpty) return;
    final batch = List<String>.from(_logBuffer);
    _logBuffer.clear();
    _logKey.currentState?.appendLogs(batch);
  }

  Future<void> _loadResinProfiles() async {
    final device = widget.activeDevice;
    if (device == null) return;
    if (_isResinLoading) return;

    setState(() => _isResinLoading = true);
    final client = NanoDlpClient(device);
    try {
      final profiles = await client.listResinProfiles();
      var selectable = profiles.where((p) => !p.locked).toList();

      debugPrint('[ProfileFilter] Total profiles: ${selectable.length}');

      // Filter by layer height if we have file info
      final ctbLayerHeightUm = (_fileInfo != null)
          ? (_fileInfo!.layerHeight * 1000).round()
          : null;

      if (ctbLayerHeightUm != null) {
        debugPrint('[ProfileFilter] CTB layer height: ${ctbLayerHeightUm}µm');

        final matchingProfiles = selectable.where((p) {
          // Try 1: Check Depth field (layer height in microns)
          final depth = p.raw['Depth'] ?? p.raw['depth'];
          if (depth != null) {
            final profileDepthUm = (depth is int)
                ? depth
                : int.tryParse('$depth');
            if (profileDepthUm != null && profileDepthUm == ctbLayerHeightUm) {
              debugPrint(
                '[ProfileFilter] ${p.name}: Depth=${profileDepthUm}µm ✓ MATCH',
              );
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
              debugPrint(
                '[ProfileFilter] ${p.name}: name contains ${nameLayerHeight}µm ✓ MATCH',
              );
              return true;
            }
          }

          debugPrint('[ProfileFilter] ${p.name}: Depth=$depth, no match');
          return false;
        }).toList();

        debugPrint(
          '[ProfileFilter] Matching profiles: ${matchingProfiles.length}',
        );

        // Only use filtered list if we found matches
        if (matchingProfiles.isNotEmpty) {
          selectable = matchingProfiles;
        }
      }

      // Remove duplicates by profile name
      final seen = <String>{};
      selectable = selectable.where((p) => seen.add(p.name)).toList();

      if (!mounted) return;
      setState(() {
        _resinProfiles = selectable;
        if (_materialProfile == null && selectable.isNotEmpty) {
          _materialProfile = selectable.first;
        }
      });
    } finally {
      client.dispose();
      if (mounted) setState(() => _isResinLoading = false);
    }
  }

  bool get _canUpload =>
      widget.activeDevice != null &&
      _selectedProfile != null &&
      _materialProfile != null;

  /// Get the active device's board type from its label or resolution.
  /// Returns null if device is not available or board type cannot be determined.
  BoardType? _getActiveDeviceBoard() {
    final activeDevice = widget.activeDevice;
    if (activeDevice == null) {
      debugPrint('[BoardDetect] No active device');
      return null;
    }

    debugPrint('[BoardDetect] Active device: ${activeDevice.displayName}');
    debugPrint(
      '[BoardDetect]   machineLcdType: ${activeDevice.machineLcdType}',
    );
    debugPrint(
      '[BoardDetect]   machineProfileLabel: ${activeDevice.machineProfileLabel}',
    );
    debugPrint(
      '[BoardDetect]   machineResolutionX: ${activeDevice.machineResolutionX}',
    );
    debugPrint(
      '[BoardDetect]   machineResolutionY: ${activeDevice.machineResolutionY}',
    );
    debugPrint(
      '[BoardDetect]   machineModelName: ${activeDevice.machineModelName}',
    );
    debugPrint('[BoardDetect]   machineSerial: ${activeDevice.machineSerial}');

    // Try to infer from machineLcdType first (has bit depth), then machineProfileLabel
    // machineLcdType = "16K 3bit", machineProfileLabel = "16K" — prefer the more specific one
    final lcdType = activeDevice.machineLcdType;
    final profileLabel = activeDevice.machineProfileLabel;
    debugPrint(
      '[BoardDetect]   checking lcdType="$lcdType" and profileLabel="$profileLabel"',
    );

    // Check both labels — if either contains 3bit info, use it
    final combinedLabel = '${lcdType ?? ''} ${profileLabel ?? ''}'
        .toLowerCase();
    final is3Bit =
        combinedLabel.contains('3bit') ||
        combinedLabel.contains('3-bit') ||
        combinedLabel.contains('3 bit');

    if (lcdType != null || profileLabel != null) {
      final result = is3Bit ? BoardType.twoBit3Subpixel : BoardType.rgb8Bit;
      debugPrint(
        '[BoardDetect]   → combined label detection: is3Bit=$is3Bit → $result',
      );
      return result;
    }

    // Fallback: Infer from resolution if available
    final width = activeDevice.machineResolutionX;
    if (width != null) {
      debugPrint('[BoardDetect]   → resolution-based detection: width=$width');
      // 16K 3-bit has output width ~7400-7700 (15136 / 2)
      // 16K 8-bit has output width ~5040 (15120 / 3)
      if (width >= 7400 && width <= 7700) {
        debugPrint('[BoardDetect]   → 3-bit (width $width in 7400-7700 range)');
        return BoardType.twoBit3Subpixel;
      } else if (width >= 4900 && width <= 5200) {
        debugPrint('[BoardDetect]   → 8-bit (width $width in 4900-5200 range)');
        return BoardType.rgb8Bit;
      }
      debugPrint(
        '[BoardDetect]   → width $width did not match any known range',
      );
    }

    debugPrint('[BoardDetect]   → COULD NOT DETERMINE board type');
    return null;
  }

  /// Auto-select target profile based on active device or cached device LCD type.
  PrinterProfile? _autoSelectProfile(
    List<PrinterProfile> availableProfiles,
    SliceFileInfo fileInfo,
  ) {
    if (availableProfiles.isEmpty) return null;

    final hwClass = PrinterProfileDetector.getResolutionClass(
      fileInfo.resolutionX,
    );
    if (hwClass == null) return availableProfiles.first;

    // Priority 1: If active device has a known board type, strongly prefer it
    final activeDeviceBoard = _getActiveDeviceBoard();
    if (activeDeviceBoard != null) {
      final matching = availableProfiles
          .where((p) => p.board == activeDeviceBoard)
          .toList();
      if (matching.isNotEmpty) {
        debugPrint(
          '[AutoSelect] Matched active device board type: $activeDeviceBoard → ${matching.first.name}',
        );
        return matching.first;
      }
      debugPrint(
        '[AutoSelect] Active device board: $activeDeviceBoard, but no matching profile',
      );
    }

    // Priority 2: Use the active device's LCD type if available
    final activeDevice = widget.activeDevice;
    if (activeDevice != null) {
      final deviceLabel =
          activeDevice.machineProfileLabel ?? activeDevice.machineLcdType;
      if (deviceLabel != null) {
        for (final profile in availableProfiles) {
          if (_profileMatchesLabel(profile, deviceLabel, hwClass)) {
            debugPrint(
              '[AutoSelect] Matched active device label: $deviceLabel → ${profile.name}',
            );
            return profile;
          }
        }
        debugPrint(
          '[AutoSelect] Active device label "$deviceLabel" did not match any profile',
        );
      }
    }

    // Priority 3: Look at cached devices
    for (final device in _cachedDevices) {
      final deviceLabel = device.machineProfileLabel ?? device.machineLcdType;
      if (deviceLabel == null) continue;

      for (final profile in availableProfiles) {
        if (_profileMatchesLabel(profile, deviceLabel, hwClass)) {
          debugPrint(
            '[AutoSelect] Matched cached device label: $deviceLabel → ${profile.name}',
          );
          return profile;
        }
      }
    }

    // Fallback: Prefer board type match over first-in-list
    // For 16K, strongly prefer 3-bit; for other resolutions, prefer 8-bit
    final threeBit = availableProfiles
        .where((p) => p.board == BoardType.twoBit3Subpixel)
        .firstOrNull;
    final eightBit = availableProfiles
        .where((p) => p.board == BoardType.rgb8Bit)
        .firstOrNull;

    if (hwClass == '16K' && threeBit != null) {
      debugPrint('[AutoSelect] Fallback to 3-bit for 16K: ${threeBit.name}');
      return threeBit;
    }
    if (eightBit != null) {
      debugPrint('[AutoSelect] Fallback to 8-bit: ${eightBit.name}');
      return eightBit;
    }
    if (threeBit != null) {
      debugPrint('[AutoSelect] Fallback to 3-bit: ${threeBit.name}');
      return threeBit;
    }

    debugPrint(
      '[AutoSelect] No match found, using first available: ${availableProfiles.first.name}',
    );
    return availableProfiles.first;
  }

  /// Handle profile selection with warnings for device mismatches.
  void _onProfileSelected(PrinterProfile profile) {
    debugPrint(
      '[ProfileSelect] User selected: ${profile.name} (${profile.board})',
    );
    final activeDevice = widget.activeDevice;
    if (activeDevice == null) {
      debugPrint('[ProfileSelect] No active device, accepting selection');
      setState(() => _selectedProfile = profile);
      return;
    }

    final activeDeviceBoard = _getActiveDeviceBoard();
    debugPrint(
      '[ProfileSelect] Active device board: $activeDeviceBoard, profile board: ${profile.board}',
    );

    // Check for mismatch: if active device is determined and doesn't match profile
    if (activeDeviceBoard != null && activeDeviceBoard != profile.board) {
      final deviceBoardName = activeDeviceBoard == BoardType.twoBit3Subpixel
          ? '3-bit'
          : '8-bit';
      final profileBoardName = profile.board == BoardType.twoBit3Subpixel
          ? '3-bit'
          : '8-bit';
      debugPrint(
        '[ProfileSelect] MISMATCH! Device=$deviceBoardName, Profile=$profileBoardName → showing warning',
      );
      _showProfileMismatchWarning(profile, deviceBoardName, profileBoardName);
      return;
    }

    debugPrint('[ProfileSelect] No mismatch, accepting selection');
    setState(() => _selectedProfile = profile);
  }

  /// Show warning when selecting a profile that doesn't match active device.
  void _showProfileMismatchWarning(
    PrinterProfile profile,
    String deviceBoardName,
    String profileBoardName,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => _buildCardDialog(
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
                    color: Colors.amberAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.amberAccent.withValues(alpha: 0.35),
                    ),
                  ),
                  child: const Icon(
                    Icons.warning_amber,
                    color: Colors.amberAccent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Board Type Mismatch',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Your active printer "${widget.activeDevice!.displayName}" is $deviceBoardName, but you selected a $profileBoardName profile (${profile.name}).',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amberAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.amberAccent.withValues(alpha: 0.25),
                ),
              ),
              child: const Text(
                'This mismatch may cause compatibility issues. The file may not display correctly on your printer.',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 16),
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
                    Navigator.pop(ctx);
                    setState(() => _selectedProfile = profile);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amberAccent.withValues(alpha: 0.3),
                    foregroundColor: Colors.amberAccent,
                  ),
                  child: const Text('Use Anyway'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Check if CTB resolution matches active device resolution.
  /// Blocks loading if there's a mismatch and shows error dialog.
  void _checkResolutionMismatch(SliceFileInfo ctbInfo, NanoDlpDevice device) {
    final ctbResX = ctbInfo.resolutionX;
    final ctbResY = ctbInfo.resolutionY;
    final deviceResX = device.machineResolutionX;

    // Skip check if device resolution is unknown
    if (deviceResX == null) return;

    final deviceLabel = _getResolutionLabel(deviceResX);
    final ctbLabel = _getResolutionLabel(ctbResX);

    debugPrint(
      '[ResolutionCheck] CTB: ${ctbResX}x${ctbResY} ($ctbLabel) vs Device: $deviceResX ($deviceLabel)',
    );

    // Check if resolutions are different classes (e.g., 16K vs 12K)
    if (deviceLabel != null && ctbLabel != null && deviceLabel != ctbLabel) {
      // Clear the file to prevent conversion
      setState(() => _fileInfo = null);
      _showResolutionMismatchWarning(
        ctbLabel,
        deviceLabel,
        ctbResX,
        deviceResX,
      );
    }
  }

  /// Get a friendly resolution label from pixel count.
  /// Returns "16K", "12K", "8K", etc., or null if unknown.
  String? _getResolutionLabel(int resolutionX) {
    if (resolutionX >= 14500 && resolutionX <= 15400) return '16K';
    if (resolutionX >= 11300 && resolutionX <= 11700) return '12K';
    if (resolutionX >= 7500 && resolutionX <= 7900) return '8K';
    if (resolutionX >= 4800 && resolutionX <= 5200) return '4K';
    return null;
  }

  void _showResolutionMismatchWarning(
    String ctbLabel,
    String deviceLabel,
    int ctbResX,
    int deviceResX,
  ) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => _buildCardDialog(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with icon
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
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
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Description
            Text(
              'This file cannot be converted on the selected printer and will fail:',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            // Resolution boxes
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
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
                          '$ctbLabel',
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
                    padding: const EdgeInsets.all(14),
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
                          '$deviceLabel',
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
            const SizedBox(height: 20),
            // Action items
            Text(
              'To fix this, do one of:',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ...[
                  'Re-slice the model for your $deviceLabel printer',
                  'Load a different $deviceLabel CTB file',
                  'Switch to a different printer for $ctbLabel',
                ]
                .map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 7),
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
                )
                .toList(),
            const SizedBox(height: 20),

            // Button
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 12,
                  ),
                  backgroundColor: Colors.purple.withValues(alpha: 0.8),
                  elevation: 0,
                ),
                child: const Text(
                  'Close',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _profileMatchesLabel(
    PrinterProfile profile,
    String deviceLabel,
    String hwClass,
  ) {
    final lowerLabel = deviceLabel.toLowerCase();

    // Check hardware class matches (e.g. "16k" in device label)
    if (!lowerLabel.contains(hwClass.toLowerCase())) return false;

    // Check bit-depth match
    final is3Bit =
        lowerLabel.contains('3bit') ||
        lowerLabel.contains('3-bit') ||
        lowerLabel.contains('3 bit');

    if (is3Bit) {
      return profile.board == BoardType.twoBit3Subpixel;
    } else {
      return profile.board == BoardType.rgb8Bit;
    }
  }

  // ── File picking ──────────────────────────────────────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ctb', 'cbddlp', 'photon'],
      dialogTitle: 'Select CTB File',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _loadFile(path);
  }

  Future<void> _loadFile(String path) async {
    final fileName = path.split(Platform.pathSeparator).last;

    // Show loading dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _buildCardDialog(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 20),
            Text(
              'Analyzing File',
              style: Theme.of(
                ctx,
              ).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              fileName,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 14),
            Text(
              'Reading header and layers...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final info = await _converter.readFileInfo(path);
      final profiles = PrinterProfileDetector.getTargetProfilesForResolution(
        info.resolutionX,
        info.resolutionY,
      );

      // Refresh device cache to get latest connected device info
      final devices = await _cache.load();

      if (!mounted) return;

      // Check for corrupt layers
      final corruptLayers = await _converter.checkForCorruptLayers(path);
      if (corruptLayers.isNotEmpty && mounted) {
        _showCorruptLayersWarning(corruptLayers, info.layerCount);
      }

      debugPrint(
        '[LoadFile] File loaded: ${info.resolutionX}x${info.resolutionY}',
      );
      debugPrint(
        '[LoadFile] Available profiles: ${profiles.map((p) => '${p.name} (${p.board})').join(', ')}',
      );
      debugPrint(
        '[LoadFile] Active device at load time: ${widget.activeDevice?.displayName ?? 'NONE'}',
      );
      debugPrint(
        '[LoadFile]   machineLcdType: ${widget.activeDevice?.machineLcdType}',
      );
      debugPrint(
        '[LoadFile]   machineProfileLabel: ${widget.activeDevice?.machineProfileLabel}',
      );
      debugPrint('[LoadFile] Cached devices: ${devices.length}');
      for (final d in devices) {
        debugPrint(
          '[LoadFile]   cached: ${d.displayName} lcdType=${d.machineLcdType} profileLabel=${d.machineProfileLabel} resX=${d.machineResolutionX}',
        );
      }

      final selectedProfile = _autoSelectProfile(profiles, info);
      debugPrint(
        '[LoadFile] SELECTED PROFILE: ${selectedProfile?.name} (${selectedProfile?.board})',
      );

      setState(() {
        _selectedFilePath = path;
        _fileInfo = info;
        _availableProfiles = profiles;
        _cachedDevices = devices; // Update with fresh device info
        _selectedProfile = selectedProfile;
      });

      // Check for resolution mismatch with active device
      if (widget.activeDevice != null) {
        _checkResolutionMismatch(info, widget.activeDevice!);
        await _loadResinProfiles();
      }

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      setState(() {
        _selectedFilePath = path;
        _errorMessage = 'Failed to read file: $e';
      });
    }
  }

  // ── Conversion ────────────────────────────────────────────

  Future<void> _startConversion({required bool uploadAfter}) async {
    if (_selectedFilePath == null || _selectedProfile == null) return;

    setState(() {
      _isConverting = true;
      _uploadAfterConversion = uploadAfter;
      _progress = null;
      _result = null;
      _errorMessage = null;
      _hasLogs = false;
    });
    _logKey.currentState?.clear();

    try {
      final result = await _converter.convert(
        _selectedFilePath!,
        options: ConversionOptions(targetProfile: _selectedProfile),
        onProgress: (p) {
          // Update progress state without rebuilding entire widget tree
          if (mounted) {
            _progress = p;
            // Only rebuild progress section if it exists
            _progressKey.currentState?.updateProgress(p);
          }
        },
      );

      setState(() {
        _result = result;
        _isConverting = false;
        if (!result.success) _errorMessage = result.errorMessage;
      });

      // If upload was requested and conversion succeeded
      if (uploadAfter &&
          result.success &&
          widget.activeDevice != null &&
          mounted) {
        // Small delay so the user sees the result first
        await Future.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        await _uploadToActivePrinter(
          overrideResin: _materialProfile,
          startPrintAfter: _autoStartPrint,
          showSuccessDialog: !_autoStartPrint,
        );
      }

      if (mounted) {
        setState(() => _uploadAfterConversion = null);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Conversion failed: $e';
        _isConverting = false;
        _uploadAfterConversion = null;
      });
    }
  }

  // ── Post-conversion upload prompt ─────────────────────────

  // ── Upload to active printer ──────────────────────────────

  Future<void> _uploadToActivePrinter({
    ResinProfile? overrideResin,
    bool startPrintAfter = false,
    bool showSuccessDialog = true,
  }) async {
    final device = widget.activeDevice;
    final outputPath = _result?.outputPath;
    if (device == null || outputPath == null) return;

    // Check resolution match before uploading
    if (_fileInfo != null) {
      final ctbResX = _fileInfo!.resolutionX;
      final deviceResX = device.machineResolutionX;
      if (deviceResX != null) {
        final deviceLabel = _getResolutionLabel(deviceResX);
        final ctbLabel = _getResolutionLabel(ctbResX);
        if (deviceLabel != null &&
            ctbLabel != null &&
            deviceLabel != ctbLabel) {
          _showResolutionMismatchWarning(
            ctbLabel,
            deviceLabel,
            ctbResX,
            deviceResX,
          );
          return;
        }
      }
    }

    setState(() => _isUploading = true);

    final client = NanoDlpClient(device);
    try {
      // Fetch resin profiles from the device
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

      // Remove duplicates by profile name
      final seen = <String>{};
      selectable = selectable.where((p) => seen.add(p.name)).toList();

      if (selectable.isEmpty) {
        if (mounted) {
          final msg = ctbLayerHeightUm != null
              ? 'No material profiles found for ${ctbLayerHeightUm}µm layer height.'
              : 'No material profiles found on device.';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
        setState(() => _isUploading = false);
        return;
      }

      // Resolve material/profile selection
      ResinProfile? selectedResin = overrideResin;
      String? jobName;
      if (selectedResin == null) {
        // Show import options dialog
        final options = await _showUploadOptionsDialog(outputPath, selectable);
        if (options == null) {
          setState(() => _isUploading = false);
          return;
        }
        selectedResin = options.resin;
        jobName = options.jobName;
      } else {
        jobName = outputPath
            .split(Platform.pathSeparator)
            .last
            .replaceAll(RegExp(r'\.[^.]*$'), '');
      }

      // Reset cancel flag at start
      _cancelUpload = false;

      // Show progress dialog with detailed tracking
      final progress = ValueNotifier<double>(0.0);
      final stage = ValueNotifier<String>('Preparing upload');
      final stageIcon = ValueNotifier<IconData>(Icons.hourglass_bottom);
      _showUploadProgressDialog(device, outputPath, progress, stage, stageIcon);

      // Stage 1: Upload file
      stage.value = 'Uploading to device';
      stageIcon.value = Icons.upload_file;
      progress.value = 0.01;
      final result = await client.importPlate(
        outputPath,
        jobName: jobName,
        profileId: selectedResin.profileId,
        onProgress: (p) => progress.value = p * 0.6, // 0% – 60%
      );

      // Check if upload was cancelled
      if (_cancelUpload) {
        _closeUploadDialog();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Upload cancelled')));
        }
        setState(() => _isUploading = false);
        return;
      }

      if (!result.success) {
        stage.value = 'Upload failed';
        stageIcon.value = Icons.error_outline;
        progress.value = 0.0;
        await Future.delayed(const Duration(milliseconds: 800));
        _closeUploadDialog();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message ?? 'Upload failed')),
          );
        }
        setState(() => _isUploading = false);
        return;
      }

      // Stage 2: Processing metadata
      stage.value = 'Processing metadata';
      stageIcon.value = Icons.settings_outlined;
      progress.value = 0.6;
      final plate = await client.waitForPlateReady(
        plateId: result.plateId,
        jobName: jobName,
        onProgress: (p) => progress.value = 0.6 + (p * 0.4),
      );

      // Check if upload was cancelled
      if (_cancelUpload) {
        _closeUploadDialog();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Upload cancelled')));
        }
        setState(() => _isUploading = false);
        return;
      }

      // Resolve plateId
      int? plateId = result.plateId;
      if (plateId == null && plate != null) {
        plateId = int.tryParse(
          '${plate['PlateID'] ?? plate['plateId'] ?? plate['plate_id'] ?? plate['id'] ?? ''}',
        );
      }

      // Stage 3: Complete
      stage.value = 'Upload complete!';
      stageIcon.value = Icons.check_circle;
      progress.value = 1.0;
      await Future.delayed(const Duration(milliseconds: 800));
      _closeUploadDialog();

      if (mounted) {
        if (startPrintAfter && plateId != null) {
          final startResult = await client.startPrint(plateId);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  startResult.$1
                      ? 'Print started!'
                      : (startResult.$2 ?? 'Failed to start print'),
                ),
                backgroundColor: startResult.$1
                    ? Colors.green.shade700
                    : Colors.red.shade700,
              ),
            );
          }
        } else if (showSuccessDialog) {
          _showUploadSuccessDialog(device, plateId);
        }
      }
    } catch (e) {
      _closeUploadDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      client.dispose();
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<_UploadOptions?> _showUploadOptionsDialog(
    String filePath,
    List<ResinProfile> profiles,
  ) async {
    final stem = filePath.split(Platform.pathSeparator).last;
    final dot = stem.lastIndexOf('.');
    final defaultName = dot > 0 ? stem.substring(0, dot) : stem;
    final controller = TextEditingController(text: defaultName);
    ResinProfile selected = profiles.first;

    try {
      return await showDialog<_UploadOptions>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => _buildCardDialog(
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
                        Icons.cloud_upload_outlined,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Upload to ${widget.activeDevice!.displayName}',
                        style: const TextStyle(
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
                      .map(
                        (p) => DropdownMenuItem(value: p, child: Text(p.name)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => selected = value);
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
                    ElevatedButton.icon(
                      onPressed: () {
                        final jobName = controller.text.trim();
                        if (jobName.isEmpty) return;
                        Navigator.pop(
                          ctx,
                          _UploadOptions(jobName: jobName, resin: selected),
                        );
                      },
                      icon: const Icon(Icons.upload, size: 18),
                      label: const Text('Upload'),
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

  void _showUploadProgressDialog(
    NanoDlpDevice device,
    String outputPath,
    ValueNotifier<double> progress,
    ValueNotifier<String> stage,
    ValueNotifier<IconData> stageIcon,
  ) {
    if (!mounted) return;
    final primary = Theme.of(context).colorScheme.primary;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          width: 520,
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
                      color: primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: primary.withValues(alpha: 0.4)),
                    ),
                    child: Icon(
                      Icons.cloud_upload_outlined,
                      color: primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Uploading to Printer',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          device.displayName,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: Colors.white.withValues(alpha: 0.06)),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: stage,
                builder: (context, value, child) => Row(
                  children: [
                    ValueListenableBuilder<IconData>(
                      valueListenable: stageIcon,
                      builder: (context, icon, child) => Icon(
                        icon,
                        color: primary.withValues(alpha: 0.9),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        value,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ValueListenableBuilder<double>(
                      valueListenable: progress,
                      builder: (context, v, child) => Text(
                        '${(v * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, value, child) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: value.clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    color: primary,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'File size: ${_getFileSizeMb(_result?.outputFileSizeBytes ?? 0)} MB',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _showCancelUploadConfirmation,
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCancelUploadConfirmation() async {
    if (!mounted) return;
    final primary = Theme.of(context).colorScheme.primary;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          width: 420,
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
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Icon(
                      Icons.warning_outlined,
                      color: Colors.orange,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Cancel Upload?',
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
                'Are you sure you want to cancel the upload? '
                'Any partially uploaded data will be lost.',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.7),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: primary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    child: const Text(
                      'Continue Upload',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      _cancelUpload = true;
      _closeUploadDialog();
    }
  }

  String _getFileSizeMb(int bytes) {
    final mb = bytes / 1024 / 1024;
    return mb.toStringAsFixed(1);
  }

  String _fmt3(num value) => value.toStringAsFixed(3);

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

  void _closeUploadDialog() {
    if (!mounted) return;
    try {
      Navigator.of(context).pop();
    } catch (_) {}
  }

  void _showUploadSuccessDialog(NanoDlpDevice device, int? plateId) {
    bool isStartingPrint = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            width: 460,
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
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.green.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(
                        Icons.check_circle,
                        color: Colors.green.shade400,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Upload Complete',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Your plate is ready on ${device.displayName}',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (plateId != null)
                      ElevatedButton.icon(
                        onPressed: isStartingPrint
                            ? null
                            : () async {
                                setDialogState(() => isStartingPrint = true);
                                final client = NanoDlpClient(device);
                                try {
                                  final result = await client.startPrint(
                                    plateId,
                                  );
                                  if (!ctx.mounted) return;
                                  Navigator.of(ctx).pop();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          result.$1
                                              ? 'Print started!'
                                              : (result.$2 ??
                                                    'Failed to start print'),
                                        ),
                                        backgroundColor: result.$1
                                            ? Colors.green.shade700
                                            : Colors.red.shade700,
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  setDialogState(() => isStartingPrint = false);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Error: $e')),
                                    );
                                  }
                                } finally {
                                  client.dispose();
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple.shade700,
                        ),
                        icon: isStartingPrint
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.play_arrow, size: 20),
                        label: const Text('Start Print'),
                      ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: isStartingPrint
                          ? null
                          : () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1100;

        final leftColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildFileSection(),
            if (_fileInfo != null) ...[
              const SizedBox(height: 12),
              _buildFileInfoCard(),
            ],
          ],
        );

        final rightColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_fileInfo != null) ...[
              _buildProfileSelector(),
              const SizedBox(height: 16),
              _buildMaterialProfilePicker(),
              const SizedBox(height: 16),
              _buildActionButtons(),
              if (_canUpload) ...[
                const SizedBox(height: 12),
                _buildStartPrintCheckbox(),
              ],
            ],
            if (_progress != null && _isConverting) ...[
              const SizedBox(height: 16),
              _ProgressSection(key: _progressKey, progress: _progress!),
            ],
            if (_result != null && _result!.success) ...[
              const SizedBox(height: 16),
              _buildResultCard(),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              _buildErrorCard(),
            ],
            if (_hasLogs) ...[const SizedBox(height: 16), _buildLogSection()],
          ],
        );

        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: leftColumn),
                    const SizedBox(width: 20),
                    Expanded(child: rightColumn),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    leftColumn,
                    const SizedBox(height: 16),
                    rightColumn,
                  ],
                ),
        );
      },
    );
  }

  Widget _buildFileSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.layers,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Source File',
                        style: Theme.of(context).textTheme.titleMedium!
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Select a CTB, CBDDLP, or Photon file to convert',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_selectedFilePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.insert_drive_file,
                      size: 18,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selectedFilePath!.split(Platform.pathSeparator).last,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isConverting ? null : _pickFile,
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(
                  _selectedFilePath == null ? 'Select CTB File' : 'Change File',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileInfoCard() {
    final info = _fileInfo!;
    final primary = Theme.of(context).colorScheme.primary;
    final printHeight = info.layerCount * info.layerHeight;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.description_outlined, color: primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'File Details',
                        style: Theme.of(context).textTheme.titleMedium!
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Data extracted from ${info.sourcePath.split(Platform.pathSeparator).last}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Resolution badge - top right
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: primary.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    info.detectedResolutionLabel,
                    style: TextStyle(
                      color: primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (info.thumbnailPng != null) ...[
              GestureDetector(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => Dialog(
                      backgroundColor: const Color(0xFF0D1117),
                      insetPadding: const EdgeInsets.all(16),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Image.memory(
                              info.thumbnailPng!,
                              fit: BoxFit.contain,
                            ),
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1117),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final maxHeight = math.min(
                        300.0,
                        constraints.maxWidth * 0.6,
                      );
                      final height = maxHeight.clamp(180.0, 300.0);
                      return SizedBox(
                        height: height,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            info.thumbnailPng!,
                            fit: BoxFit.contain,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            _sectionLabel('GEOMETRY'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _statTile(
                    Icons.aspect_ratio_rounded,
                    'Resolution',
                    '${info.resolutionX} × ${info.resolutionY}',
                    Colors.cyanAccent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _statTile(
                    Icons.layers_rounded,
                    'Layers',
                    '${info.layerCount}',
                    Colors.tealAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _statTile(
                    Icons.height_rounded,
                    'Layer Height',
                    '${_fmt3(info.layerHeight)} mm',
                    Colors.amberAccent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _statTile(
                    Icons.straighten_rounded,
                    'Print Height',
                    '${_fmt3(printHeight)} mm',
                    Colors.orangeAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () {
                setState(
                  () => _showFileDetailsExposure = !_showFileDetailsExposure,
                );
              },
              child: Row(
                children: [
                  Text(
                    _showFileDetailsExposure ? 'Hide details' : 'Show more',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _showFileDetailsExposure
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
            if (_showFileDetailsExposure) ...[
              const SizedBox(height: 16),
              _sectionLabel('EXPOSURE'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _statTile(
                      Icons.timer_outlined,
                      'Normal',
                      '${_fmt3(info.exposureTime)} s',
                      Colors.lightBlueAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _statTile(
                      Icons.timer,
                      'Bottom',
                      '${_fmt3(info.bottomExposureTime)} s',
                      Colors.purpleAccent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _statTile(
                      Icons.filter_none_rounded,
                      'Bottom Layers',
                      '${info.bottomLayerCount}',
                      Colors.pinkAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _statTile(
                      Icons.swap_vert_rounded,
                      'Lift Height',
                      '${_fmt3(info.liftHeight)} mm',
                      Colors.greenAccent,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Small uppercase section divider with accent bar.
  Widget _sectionLabel(String text) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.4),
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  /// Individual stat tile with colored icon + label/value.
  Widget _statTile(IconData icon, String label, String value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: accent.withValues(alpha: 0.7)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoColumn(List<(String, String)> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      item.$1,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item.$2,
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildProfileSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.memory,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  'Target Profile',
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_availableProfiles.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No matching target profiles found.',
                        style: TextStyle(color: Colors.orange, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: DropdownButtonFormField<PrinterProfile>(
                  initialValue: _selectedProfile,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF16213E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  dropdownColor: const Color(0xFF1E293B),
                  isExpanded: true,
                  items: _availableProfiles.map((p) {
                    final is3Bit = p.board == BoardType.twoBit3Subpixel;
                    return DropdownMenuItem(
                      value: p,
                      child: Row(
                        children: [
                          Icon(
                            is3Bit ? Icons.grain : Icons.grid_on,
                            size: 18,
                            color: is3Bit
                                ? Colors.amberAccent
                                : Colors.greenAccent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(p.name)),
                          Text(
                            is3Bit ? '3-bit' : '8-bit',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: _isConverting
                      ? null
                      : (profile) =>
                            _onProfileSelected(profile ?? _selectedProfile!),
                ),
              ),
            if (_selectedProfile != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  _chip(
                    'Board',
                    _selectedProfile!.board == BoardType.twoBit3Subpixel
                        ? '3-bit Greyscale'
                        : '8-bit RGB',
                  ),
                  _chip(
                    'Output Width',
                    '${_selectedProfile!.pngOutputWidth}px',
                  ),
                  _chip('Max Z', '${_selectedProfile!.maxZHeight} mm'),
                  _chip(
                    'Pixel Pitch',
                    '${_selectedProfile!.pixelPitchUm.toStringAsFixed(1)} µm',
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMaterialProfilePicker() {
    final device = widget.activeDevice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.water_drop,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  'Material',
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (device == null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.cloud_off, color: Colors.orange, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Connect a printer to select material profiles.',
                        style: TextStyle(color: Colors.orange, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              )
            else if (_isResinLoading)
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Loading materials…',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ],
              )
            else if (_resinProfiles.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No materials available on printer.',
                        style: TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: DropdownButtonFormField<ResinProfile>(
                  initialValue: _materialProfile,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF16213E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  dropdownColor: const Color(0xFF1E293B),
                  isExpanded: true,
                  items: _resinProfiles
                      .map(
                        (p) => DropdownMenuItem(value: p, child: Text(p.name)),
                      )
                      .toList(),
                  onChanged: _resinProfiles.isEmpty
                      ? null
                      : (p) => setState(() => _materialProfile = p),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  void _showCorruptLayersWarning(List<int> corruptLayers, int totalLayers) {
    if (!mounted) return;

    final layerList = corruptLayers.take(10).map((i) => '#${i + 1}').join(', ');
    final hasMore = corruptLayers.length > 10;

    showDialog(
      context: context,
      builder: (ctx) => _buildCardDialog(
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
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.35),
                    ),
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Possible File Corruption',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Detected ${corruptLayers.length} layer(s) that appear fully black or fully white, which may indicate a corrupt CTB file:',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Text(
                '$layerList${hasMore ? ', ...' : ''}',
                style: TextStyle(
                  color: Colors.orange.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'This could be caused by:',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ...[
              'Incomplete file download',
              'Transfer errors',
              'Slicer software issues',
              'Corrupted support structures',
            ].map(
              (reason) => Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• ',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        reason,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'You can proceed with conversion, but the print may fail or have defects.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    final canConvert = !_isConverting && _selectedProfile != null;
    final isConvertingWithoutUpload =
        _isConverting && _uploadAfterConversion == false;
    final isConvertingWithUpload =
        _isConverting && _uploadAfterConversion == true;

    return Row(
      spacing: 12,
      children: [
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: canConvert
                  ? () => _startConversion(uploadAfter: false)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                foregroundColor: Colors.white.withValues(alpha: 0.8),
              ),
              icon: isConvertingWithoutUpload
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download),
              label: const Text('Just Convert'),
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: (canConvert && _canUpload)
                  ? () => _startConversion(uploadAfter: true)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan.shade700,
                foregroundColor: Colors.white,
              ),
              icon: isConvertingWithUpload
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_upload),
              label: const Text('Convert & Upload'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStartPrintCheckbox() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Checkbox(
              value: _autoStartPrint,
              onChanged: (value) {
                setState(() {
                  _autoStartPrint = value ?? false;
                });
              },
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Start print after upload',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    final r = _result!;
    final sizeMb = r.outputFileSizeBytes / 1024 / 1024;
    final hasActiveDevice = widget.activeDevice != null;
    return Card(
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Colors.greenAccent.withValues(alpha: 0.6),
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.greenAccent),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Conversion Complete',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.greenAccent,
                    ),
                  ),
                ),
                if (hasActiveDevice)
                  ElevatedButton.icon(
                    onPressed: _isUploading ? null : _uploadToActivePrinter,
                    icon: _isUploading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.upload, size: 18),
                    label: Text(
                      _isUploading
                          ? 'Uploading…'
                          : 'Upload to ${widget.activeDevice!.displayName}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _infoColumn([
              ('Output', r.outputPath.split(Platform.pathSeparator).last),
              ('Size', '${sizeMb.toStringAsFixed(1)} MB'),
              ('Layers', '${r.layerCount}'),
              ('Profile', r.targetProfile.name),
              (
                'Duration',
                '${(r.duration.inMilliseconds / 1000).toStringAsFixed(1)} s',
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Card(
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Colors.red.withValues(alpha: 0.6),
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 8),
                Text(
                  'Log',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _LogSection(key: _logKey),
          ],
        ),
      ),
    );
  }
}

class _LogSection extends StatefulWidget {
  const _LogSection({super.key});

  @override
  State<_LogSection> createState() => _LogSectionState();
}

class _LogSectionState extends State<_LogSection> {
  final List<String> _logs = [];

  void appendLogs(List<String> lines) {
    if (lines.isEmpty) return;
    setState(() {
      _logs.addAll(lines);
      if (_logs.length > 400) {
        _logs.removeRange(0, _logs.length - 400);
      }
    });
  }

  void clear() {
    if (_logs.isEmpty) return;
    setState(() => _logs.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      child: SelectionArea(
        child: ListView.builder(
          reverse: true,
          itemCount: _logs.length,
          itemBuilder: (context, index) {
            final line = _logs[_logs.length - 1 - index];
            return Text(
              line,
              style: const TextStyle(
                fontFamily: 'Consolas, monospace',
                fontSize: 12,
                color: Color(0xFF94A3B8),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Efficient progress widget that updates without rebuilding the entire screen.
/// This stateful widget allows progress updates to be isolated from other UI changes.
class _ProgressSection extends StatefulWidget {
  final ConversionProgress progress;

  const _ProgressSection({required super.key, required this.progress});

  @override
  State<_ProgressSection> createState() => _ProgressSectionState();
}

class _ProgressSectionState extends State<_ProgressSection> {
  late ConversionProgress _progress;

  @override
  void initState() {
    super.initState();
    _progress = widget.progress;
  }

  /// Called from the parent to update progress without full rebuild.
  void updateProgress(ConversionProgress p) {
    setState(() => _progress = p);
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  p.phase,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Text(
                  '${(p.fraction * 100).toStringAsFixed(0)}%'
                  '${p.workers != null ? ' • ${p.workers} workers' : ''}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: p.fraction, minHeight: 6),
            ),
            const SizedBox(height: 6),
            Text(
              'Layer ${p.current} / ${p.total}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadOptions {
  final String jobName;
  final ResinProfile resin;

  const _UploadOptions({required this.jobName, required this.resin});
}
