import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/network/active_device_store.dart';
import 'core/models/nanodlp_device.dart';
import 'ui/theme.dart';
import 'ui/screens/conversion_screen.dart';
import 'ui/screens/network_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/post_processor_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'core/conversion/conversion_analytics.dart';
import 'ui/widgets/analytics_overlay.dart';

class _ToggleAnalyticsIntent extends Intent {
  const _ToggleAnalyticsIntent();
}

class _CliOptions {
  final bool help;
  final String? filePath;
  final List<String> unknownArgs;

  const _CliOptions({
    required this.help,
    required this.filePath,
    required this.unknownArgs,
  });
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final cli = _parseCliArgs(args);
  if (cli.help) {
    await _printCliHelp();
    exit(0);
  }

  if (cli.unknownArgs.isNotEmpty) {
    print('[Main] Unknown args ignored: ${cli.unknownArgs.join(' ')}');
  }

  // Check for file from environment variable (for slicer post-processing)
  final envFile = Platform.environment['VOXELSHIFT_FILE'];

  String? postProcessorFile;
  if (envFile != null && envFile.isNotEmpty) {
    postProcessorFile = envFile;
    print('[Main] Post-processor mode (env): $postProcessorFile');
  } else if (cli.filePath != null && cli.filePath!.isNotEmpty) {
    postProcessorFile = cli.filePath;
    print('[Main] Post-processor mode (args): $postProcessorFile');
  } else if (args.isNotEmpty) {
    print('[Main] Command-line args: $args');
  }

  print('[Main] Startup complete.');

  if (postProcessorFile != null &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: Size(660, 760),
      minimumSize: Size(600, 700),
      center: true,
      backgroundColor: Platform.isMacOS
          ? const Color(0xFF0F172A)
          : Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setResizable(false);
      if (!Platform.isMacOS) {
        await windowManager.setAsFrameless();
      }
    });
  }

  runApp(VoxelShiftApp(postProcessorFile: postProcessorFile));
}

_CliOptions _parseCliArgs(List<String> args) {
  bool help = false;
  String? filePath;
  final unknown = <String>[];

  for (int i = 0; i < args.length; i++) {
    final arg = args[i].trim();
    if (arg.isEmpty) continue;

    if (arg == '-h' || arg == '--help') {
      help = true;
      continue;
    }

    if (arg == '--file' || arg == '-f') {
      if (i + 1 < args.length) {
        filePath = args[++i];
      } else {
        unknown.add(arg);
      }
      continue;
    }

    if (arg.startsWith('--file=')) {
      final v = arg.substring('--file='.length).trim();
      if (v.isNotEmpty) filePath = v;
      continue;
    }

    if (!arg.startsWith('-') && filePath == null) {
      filePath = arg;
      continue;
    }

    unknown.add(arg);
  }

  if (filePath != null) {
    final f = File(filePath);
    if (!f.existsSync()) {
      print('[Main] Warning: file does not exist: $filePath');
    }
  }

  return _CliOptions(help: help, filePath: filePath, unknownArgs: unknown);
}

Future<void> _printCliHelp() async {
  stdout.writeln('''
VoxelShift CLI

Usage:
  voxelshift.exe [options] [file.ctb]

Options:
  -h, --help              Show this help and exit.
  -f, --file <path>       Input file path (CTB/CBDDLP/Photon).

Windows runner options:
  --attach-console        Force attach/create console for stdout logs.
  --new-console           Force create a new console window.

Examples:
  voxelshift.exe -h
  voxelshift.exe large_test.ctb
  voxelshift.exe --file "C:\\prints\\large_test.ctb"
  voxelshift.exe --attach-console --file "C:\\prints\\large_test.ctb"

Environment variables:
  VOXELSHIFT_FILE=<path>            Alternative way to pass input file.
  VOXELSHIFT_GPU_MODE=auto|cpu|gpu
  VOXELSHIFT_AUTOTUNE=0|1
  VOXELSHIFT_GPU_BACKEND=auto|opencl|cuda|tensor|metal
  VOXELSHIFT_CPU_HOST_WORKERS=<N>
  VOXELSHIFT_GPU_HOST_WORKERS=<N>
''');
  await stdout.flush();
}

class VoxelShiftApp extends StatelessWidget {
  final String? postProcessorFile;

  const VoxelShiftApp({super.key, this.postProcessorFile});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoxelShift',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();

        if (postProcessorFile != null && !Platform.isMacOS) {
          const radius = 20.0;
          content = Padding(
            padding: const EdgeInsets.all(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: content,
              ),
            ),
          );
        }

        return Shortcuts(
          shortcuts: {
            LogicalKeySet(
              LogicalKeyboardKey.control,
              LogicalKeyboardKey.shift,
              LogicalKeyboardKey.keyA,
            ): const _ToggleAnalyticsIntent(),
            LogicalKeySet(
              LogicalKeyboardKey.meta,
              LogicalKeyboardKey.shift,
              LogicalKeyboardKey.keyA,
            ): const _ToggleAnalyticsIntent(),
          },
          child: Actions(
            actions: {
              _ToggleAnalyticsIntent: CallbackAction<_ToggleAnalyticsIntent>(
                onInvoke: (intent) {
                  AnalyticsBus.toggle();
                  return null;
                },
              ),
            },
            child: Stack(
              children: [
                content,
                ValueListenableBuilder<bool>(
                  valueListenable: AnalyticsBus.enabled,
                  builder: (context, enabled, _) {
                    if (!enabled) return const SizedBox.shrink();
                    return ValueListenableBuilder(
                      valueListenable: AnalyticsBus.latest,
                      builder: (context, report, __) {
                        if (report == null) return const SizedBox.shrink();
                        return Center(
                          child: AnalyticsOverlay(
                            analytics: report,
                            onClose: AnalyticsBus.toggle,
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
      home: postProcessorFile != null
          ? _PostProcessorWrapper(filePath: postProcessorFile!)
          : const AppShell(),
    );
  }
}

/// Wrapper for post-processor mode.
class _PostProcessorWrapper extends StatefulWidget {
  final String filePath;

  const _PostProcessorWrapper({required this.filePath});

  @override
  State<_PostProcessorWrapper> createState() => _PostProcessorWrapperState();
}

class _PostProcessorWrapperState extends State<_PostProcessorWrapper> {
  final _activeDeviceStore = ActiveDeviceStore();
  NanoDlpDevice? _activeDevice;
  bool _isLoading = true;
  bool _skipDeviceSelection = false;

  @override
  void initState() {
    super.initState();
    _loadActiveDevice();
  }

  Future<void> _loadActiveDevice() async {
    final device = await _activeDeviceStore.load();
    setState(() {
      _activeDevice = device;
      _isLoading = false;
    });
  }

  void _setActiveDevice(NanoDlpDevice? device) {
    setState(() => _activeDevice = device);
    _activeDeviceStore.save(device);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_activeDevice == null && !_skipDeviceSelection) {
      return OnboardingScreen(
        onDeviceSelected: (device) {
          if (device == null) {
            setState(() => _skipDeviceSelection = true);
            return;
          }
          _setActiveDevice(device);
        },
      );
    }

    return PostProcessorScreen(
      ctbFilePath: widget.filePath,
      activeDevice: _activeDevice,
      onSetActiveDevice: (device) => _setActiveDevice(device),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _tabIndex = 0;
  final _activeDeviceStore = ActiveDeviceStore();
  NanoDlpDevice? _activeDevice;
  bool? _showOnboarding;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadActiveDevice();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadActiveDevice() async {
    final device = await _activeDeviceStore.load();
    if (mounted) {
      setState(() {
        _activeDevice = device;
        _showOnboarding = device == null; // Show onboarding if no device
      });
    }
  }

  void _setActiveDevice(NanoDlpDevice? device) {
    setState(() {
      _activeDevice = device;
      _showOnboarding = false;
    });
    _activeDeviceStore.save(device);
  }

  @override
  Widget build(BuildContext context) {
    // Show loading while determining if onboarding is needed
    if (_showOnboarding == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Show onboarding if no active device
    if (_showOnboarding == true) {
      return OnboardingScreen(
        onDeviceSelected: (device) {
          _setActiveDevice(device);
        },
      );
    }

    // Show main app
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              Icons.view_in_ar,
              color: Theme.of(context).colorScheme.primary,
              size: 26,
            ),
            const SizedBox(width: 10),
            const Text(
              'VoxelShift',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
            ),
            if (_activeDevice != null) ...[
              const SizedBox(width: 20),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.tealAccent.withValues(alpha: 0.15),
                  border: Border.all(
                    color: Colors.tealAccent.withValues(alpha: 0.5),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Colors.tealAccent,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _activeDevice!.displayName,
                      style: TextStyle(
                        color: Colors.tealAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_activeDevice!.machineLcdType != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '(${_activeDevice!.machineLcdType})',
                        style: TextStyle(
                          color: Colors.tealAccent.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.purple.shade700,
                      Colors.pink.shade400,
                      Colors.red.shade400,
                      Colors.deepOrange.shade700,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: SizedBox(
                  height: 20,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Transform.translate(
                        offset: const Offset(0, -1.5),
                        child: Text(
                          'An Open Resin Alliance Project',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.9),
                            height: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          ConversionScreen(activeDevice: _activeDevice),
          NetworkScreen(
            activeDevice: _activeDevice,
            onSetActiveDevice: _setActiveDevice,
          ),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        height: 64,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.transform),
            selectedIcon: Icon(Icons.transform),
            label: 'Convert',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi),
            selectedIcon: Icon(Icons.wifi),
            label: 'Network',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
