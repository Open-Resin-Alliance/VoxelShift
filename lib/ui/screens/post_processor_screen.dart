import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/conversion/converter.dart';
import '../../core/conversion/profile_detector.dart';
import '../../core/models/models.dart';
import '../../core/network/app_settings.dart';
import '../../core/network/device_cache.dart';
import '../../core/network/nanodlp_client.dart';

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

class _PostProcessorScreenState extends State<PostProcessorScreen>
    with TickerProviderStateMixin {
  final _converter = CtbToNanoDlpConverter();
  final _cache = DeviceCache();

  SliceFileInfo? _fileInfo;
  PrinterProfile? _selectedProfile;

  ConversionResult? _result;
  String? _errorMessage;
  _Phase _phase = _Phase.loading;

  double _convertProgress = 0.0;
  double _uploadProgress = 0.0;
  bool _isSlicing = false;
  int? _uploadedPlateId;
  bool _isStartingPrint = false;
  ConversionProgress? _conversionProgress;

  // Background mode options
  bool _runInBackground = false;
  bool _autoStartPrint = false;
  bool _isResinLoading = false;
  List<ResinProfile> _resinProfiles = [];
  ResinProfile? _selectedResin;
  bool _backgroundDialogShown = false;

  DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _sliceController;

  @override
  void initState() {
    super.initState();
    _converter.addLogListener(_onLog);
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _sliceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
    _loadCachedDevices();
    _loadFile();
  }

  @override
  void dispose() {
    _converter.removeLogListener(_onLog);
    _pulseController.dispose();
    _sliceController.dispose();
    super.dispose();
  }

  void _onLog(String msg) {
    debugPrint('[PostProcessor] $msg');
  }

  bool _shouldUpdateProgress(double nextValue) {
    if (nextValue >= 1.0 && _uploadProgress < 1.0) return true;
    final now = DateTime.now();
    final elapsed = now.difference(_lastProgressUpdate).inMilliseconds;
    if (elapsed < 250 && (nextValue - _convertProgress).abs() < 0.02) {
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
      final selectable = profiles.where((p) => !p.locked).toList();
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
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
                      child: Icon(
                        Icons.auto_awesome,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Run in Background',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Select the material to use after conversion and optionally start the print automatically.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 16),
                if (_isResinLoading)
                  Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Loading material profiles…',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  )
                else
                  DropdownButtonFormField<ResinProfile>(
                    initialValue: _selectedResin,
                    decoration: InputDecoration(
                      labelText: 'Material profile',
                      labelStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    dropdownColor: const Color(0xFF16213E),
                    isExpanded: true,
                    items: _resinProfiles
                        .map((p) => DropdownMenuItem(
                              value: p,
                              child: Text(p.name),
                            ))
                        .toList(),
                    onChanged: (p) {
                      setDialogState(() => _selectedResin = p);
                    },
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Checkbox(
                      value: _autoStartPrint,
                      onChanged: (val) =>
                          setDialogState(() => _autoStartPrint = val ?? false),
                      activeColor: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Start print after upload',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      onPressed: _selectedResin == null
                          ? null
                          : () {
                              setState(() => _runInBackground = true);
                              Navigator.of(ctx).pop();
                            },
                      icon: const Icon(Icons.play_circle_outline, size: 18),
                      label: const Text('Enable'),
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

  Future<void> _loadCachedDevices() async {
    await _cache.load();
    if (mounted) {
    }
  }

  Future<void> _loadFile() async {
    try {
      final info = await _converter.readFileInfo(widget.ctbFilePath);
      final profiles = PrinterProfileDetector.getTargetProfilesForResolution(
        info.resolutionX,
        info.resolutionY,
      );

      if (!mounted) return;

      // Auto-select profile by active device
      PrinterProfile? selectedProfile;
      if (widget.activeDevice != null) {
        final activeLabel =
            widget.activeDevice!.machineLcdType ?? widget.activeDevice!.machineProfileLabel;
        if (activeLabel != null) {
          final lowerLabel = activeLabel.toLowerCase();
          final is3Bit = lowerLabel.contains('3bit') ||
              lowerLabel.contains('3-bit') ||
              lowerLabel.contains('3 bit');
          final board =
              is3Bit ? BoardType.twoBit3Subpixel : BoardType.rgb8Bit;
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
        _loadResinProfiles();
        await Future.delayed(const Duration(milliseconds: 200));
        final isLargePrint = (info.layerCount) > 300;
        if (mounted && isLargePrint && !_backgroundDialogShown) {
          _backgroundDialogShown = true;
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
    });

    try {
      final result = await _converter.convert(
        widget.ctbFilePath,
        options: ConversionOptions(targetProfile: _selectedProfile),
        onProgress: (p) {
          if (!mounted) return;
          _conversionProgress = p;
          if (_shouldUpdateProgress(p.fraction)) {
            setState(() => _convertProgress = p.fraction);
          }
        },
      );

      if (!mounted) return;

      setState(() {
        _result = result;
        _phase = _Phase.converted;
      });

      // Pulse the checkmark
      _pulseController.repeat(reverse: true);

      if (result.success && widget.activeDevice != null) {
        // Show completion briefly, then auto-upload
        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) {
          _pulseController.stop();
          _pulseController.reset();
          _startUpload();
        }
      }
    } catch (e) {
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
      final selectable = profiles.where((p) => !p.locked).toList();
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

      if (selectedResin == null) {
        // Show selection dialog
        selectedResin = await _showMaterialProfileDialog(selectable);
        if (selectedResin == null) {
          // User cancelled — stay on converted state
          setState(() => _phase = _Phase.converted);
          _pulseController.repeat(reverse: true);
          client.dispose();
          return;
        }
      }

      // Now start uploading
      setState(() {
        _phase = _Phase.uploading;
        _uploadProgress = 0.0;
        _isSlicing = false;
      });

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
          if (_shouldUpdateProgress(p)) {
            setState(() {
              _uploadProgress = p;
              if (p >= 0.99) _isSlicing = true;
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

      // Wait for metadata & resolve plateId (keep progress moving)
      if (mounted) {
        setState(() => _uploadProgress = _uploadProgress.clamp(0.0, 0.95));
      }
      final plate = await client.waitForPlateReady(
        plateId: uploadResult.plateId,
        jobName: jobName,
        onProgress: (p) {
          if (!mounted) return;
          final scaled = 0.95 + (p * 0.05);
          if (_shouldUpdateProgress(scaled)) {
            setState(() => _uploadProgress = scaled.clamp(0.0, 1.0));
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
      });
      _pulseController.repeat(reverse: true);

      if (_runInBackground && _autoStartPrint && plateId != null) {
        await _startPrint();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Upload failed: $e';
        _phase = _Phase.error;
        _uploadProgress = 0.0;
      });
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
              border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
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
            border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
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
                    child: const Icon(Icons.stop_circle_outlined,
                        color: Colors.redAccent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Cancel Processing?',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('VoxelShift Post-Processor'),
        centerTitle: true,
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            tooltip: 'Run in background',
            onPressed: _showBackgroundOptionsDialog,
            icon: const Icon(Icons.auto_awesome, color: Color(0xFF22D3EE)),
          ),
          IconButton(
            tooltip: 'Cancel',
            onPressed: _showCancelDialog,
            icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
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
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _buildContent(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Powered by ',
                  style: TextStyle(
                    fontFamily: 'AtkinsonHyperlegible',
                    fontSize: 22,
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
                      fontSize: 22,
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
              Icon(Icons.print_disabled,
                  color: Colors.orange.shade400, size: 48),
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
          'Converting...',
          key: 'activity',
          progress: _convertProgress,
          color: Colors.cyan,
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
          _isSlicing 
            ? 'Processing/Slicing on device...' 
            : 'Uploading to ${widget.activeDevice!.displayName}...',
          key: _isSlicing ? 'slicing' : 'activity',
          progress: _uploadProgress,
          color: Colors.purpleAccent,
          isSlicing: _isSlicing,
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
    bool isSlicing = false,
  }) {
    return Column(
      key: ValueKey(key),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        isSlicing 
            ? _AnimatedSlicingBlock(
                controller: _sliceController, 
                primaryColor: color,
              )
            : _SpinnerArcs(color: color),
        const SizedBox(height: 32),
        Text(
          message,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        if (progress != null) ...[
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              color: color,
              backgroundColor: color.withValues(alpha: 0.2),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSlicing 
              ? 'Please wait, large files may take a minute...'
              : '${(progress * 100).toStringAsFixed(0)}%'
                '${_conversionProgress?.workers != null ? ' • ${_conversionProgress!.workers} workers' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ],
    );
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
        ScaleTransition(
          scale: _pulseAnimation,
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
    return Column(
      key: const ValueKey('complete'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ScaleTransition(
          scale: _pulseAnimation,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.green.shade400, Colors.green.shade700],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withValues(alpha: 0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.check, color: Colors.white, size: 44),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Upload Complete!',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Your plate is ready on ${widget.activeDevice!.displayName}',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 32),
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          width: 80,
          height: 80,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(begin: widget.color, end: widget.color),
            duration: const Duration(milliseconds: 300),
            builder: (context, color, _) {
              return CustomPaint(
                painter: _ArcPainter(
                  progress: _controller.value,
                  color: color ?? widget.color,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double progress;
  final Color color;
  
  const _ArcPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Outer arc — slow, wide sweep
    _drawArc(canvas, center, size.width / 2 - 2,
        progress * 2 * math.pi,
        sweepAngle: math.pi * 0.8,
        color: color.withValues(alpha: 0.3),
        strokeWidth: 2.5);

    // Middle arc — reverse, narrower
    _drawArc(canvas, center, size.width / 2 - 12,
        -progress * 1.5 * 2 * math.pi,
        sweepAngle: math.pi * 0.6,
        color: color.withValues(alpha: 0.55),
        strokeWidth: 2.5);

    // Inner arc — fast, narrow
    _drawArc(canvas, center, size.width / 2 - 22,
        progress * 3 * 2 * math.pi,
        sweepAngle: math.pi * 0.5,
        color: color,
        strokeWidth: 2.5);

    // Center dot with glow
    final dotPaint = Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(center, 5, dotPaint);
    canvas.drawCircle(center, 4, Paint()..color = color);
  }

  void _drawArc(
    Canvas canvas,
    Offset center,
    double radius,
    double startAngle, {
    required double sweepAngle,
    required Color color,
    required double strokeWidth,
  }) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => 
      old.progress != progress || old.color != color;
}

class _AnimatedSlicingBlock extends StatelessWidget {
  final AnimationController controller;
  final Color primaryColor;

  const _AnimatedSlicingBlock({
    required this.controller,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final progress = controller.value;
          // Smooth easing for slice count, with a pop-out separation
          final countT = Curves.easeInOut.transform(progress);
          final popT = Curves.easeOutBack.transform(progress);
          final numSlices = (countT * 6).toInt() + 1;
          final separation = popT * 18;

          return CustomPaint(
            painter: _CubeSlicePainter(
              primaryColor: primaryColor,
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
      final waveAmount = math.sin((i / sliceCount) * math.pi) * separation * 0.3;
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
      final frontRRect =
          RRect.fromRectAndRadius(sliceRect, const Radius.circular(cornerRadius));
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
