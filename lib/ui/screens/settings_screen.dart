import 'package:flutter/material.dart';

import '../../core/network/app_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings? _settings;
  bool _loading = true;

  final _gpuHostCtrl = TextEditingController();
  final _cpuHostCtrl = TextEditingController();
  final _cudaHostCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gpuHostCtrl.dispose();
    _cpuHostCtrl.dispose();
    _cudaHostCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await AppSettings.load();
    _applyControllers(settings.postProcessing);
    setState(() {
      _settings = settings;
      _loading = false;
    });
  }

  void _applyControllers(PostProcessingSettings pp) {
    _gpuHostCtrl.text = pp.gpuHostWorkers?.toString() ?? '';
    _cpuHostCtrl.text = pp.cpuHostWorkers?.toString() ?? '';
    _cudaHostCtrl.text = pp.cudaHostWorkers?.toString() ?? '';
  }

  int? _parseIntOrNull(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  Future<void> _save(PostProcessingSettings pp) async {
    final settings = _settings;
    if (settings == null) return;
    settings.postProcessing = pp;
    await settings.save();
  }

  void _updatePostProcessing(PostProcessingSettings Function(PostProcessingSettings) update) {
    final settings = _settings;
    if (settings == null) return;
    final current = settings.postProcessing;
    final updated = update(PostProcessingSettings(
      gpuMode: current.gpuMode,
      gpuBackend: current.gpuBackend,
      autotune: current.autotune,
      fastMode: current.fastMode,
      usePhased: current.usePhased,
      recompressMode: current.recompressMode,
      processPngLevel: current.processPngLevel,
      gpuHostWorkers: current.gpuHostWorkers,
      cpuHostWorkers: current.cpuHostWorkers,
      cudaHostWorkers: current.cudaHostWorkers,
    ));
    setState(() {
      settings.postProcessing = updated;
    });
    _save(updated);
  }

  void _resetDefaults() {
    final defaults = PostProcessingSettings();
    _applyControllers(defaults);
    setState(() {
      _settings?.postProcessing = defaults;
    });
    _save(defaults);
  }

  Future<void> _resetCachedSettings() async {
    if (_settings == null) return;
    _settings!.defaultMaterialProfileId = null;
    _settings!.benchmarkCache.clear();
    await _settings!.save();
    setState(() {});
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cached settings cleared'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final pp = _settings!.postProcessing;

    final accent = Theme.of(context).colorScheme.primary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        _header(accent),
        const SizedBox(height: 12),
        _section(
          title: 'GPU & Auto-tune',
          subtitle: 'Control GPU selection and benchmark caching.',
          icon: Icons.speed,
          children: [
            _dropdown<String>(
              label: 'GPU mode',
              value: pp.gpuMode,
              items: const ['auto', 'gpu', 'cpu'],
              onChanged: (v) => _updatePostProcessing((p) => p..gpuMode = v),
            ),
            _dropdown<String>(
              label: 'GPU backend preference',
              value: pp.gpuBackend,
              items: const ['auto', 'opencl', 'cuda', 'metal'],
              onChanged: (v) => _updatePostProcessing((p) => p..gpuBackend = v),
            ),
            _switchTile(
              title: 'Auto-tune CPU vs GPU',
              subtitle: 'Benchmarks a small sample and caches results.',
              value: pp.autotune,
              onChanged: (v) => _updatePostProcessing((p) => p..autotune = v),
            ),
          ],
        ),
        _section(
          title: 'Pipeline Modes',
          subtitle: 'Speed vs quality controls for processing.',
          icon: Icons.tune,
          children: [
            _switchTile(
              title: 'Fast mode',
              subtitle: 'Lower PNG level for speed-first output.',
              value: pp.fastMode,
              onChanged: (v) => _updatePostProcessing((p) => p..fastMode = v),
            ),
            _switchTile(
              title: 'Use phased pipeline',
              subtitle: 'Opt-in CPU+GPU phased processing.',
              value: pp.usePhased,
              onChanged: (v) => _updatePostProcessing((p) => p..usePhased = v),
            ),
          ],
        ),
        _section(
          title: 'PNG Output',
          subtitle: 'Compression and recompression settings.',
          icon: Icons.image,
          children: [
            _dropdown<int?>(
              label: 'Process PNG level',
              value: pp.processPngLevel,
              items: const [null, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
              itemLabel: (v) => v == null ? 'Auto' : v.toString(),
              onChanged: (v) => _updatePostProcessing((p) => p..processPngLevel = v),
            ),
            _dropdown<String>(
              label: 'Recompress mode',
              value: pp.recompressMode,
              items: const ['adaptive', 'off', 'on', 'force'],
              onChanged: (v) => _updatePostProcessing((p) => p..recompressMode = v),
            ),
          ],
        ),
        _section(
          title: 'Worker Counts',
          subtitle: 'Leave blank to use auto scaling.',
          icon: Icons.memory,
          children: [
            _intField(
              label: 'GPU host workers',
              controller: _gpuHostCtrl,
              onChanged: () => _updatePostProcessing(
                (p) => p..gpuHostWorkers = _parseIntOrNull(_gpuHostCtrl.text),
              ),
            ),
            _intField(
              label: 'CPU host workers',
              controller: _cpuHostCtrl,
              onChanged: () => _updatePostProcessing(
                (p) => p..cpuHostWorkers = _parseIntOrNull(_cpuHostCtrl.text),
              ),
            ),
            _intField(
              label: 'CUDA host workers',
              controller: _cudaHostCtrl,
              onChanged: () => _updatePostProcessing(
                (p) => p..cudaHostWorkers = _parseIntOrNull(_cudaHostCtrl.text),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: _resetDefaults,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset to defaults'),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: _resetCachedSettings,
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Clear cache'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _header(Color accent) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.18),
            accent.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withValues(alpha: 0.35)),
            ),
            child: Icon(Icons.settings, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Post-processing Settings',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 4),
                Text(
                  'These options override environment flags for conversions.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
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
            const SizedBox(height: 12),
            ...children.map((w) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: w,
                )),
          ],
        ),
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required void Function(T) onChanged,
    String Function(T)? itemLabel,
  }) {
    return DropdownButtonFormField<T>(
      value: value,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFF16213E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      items: items
          .map((e) => DropdownMenuItem<T>(
                value: e,
                child: Text(itemLabel != null ? itemLabel(e) : e.toString()),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _intField({
    required String label,
    required TextEditingController controller,
    required VoidCallback onChanged,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'Leave empty for auto',
        filled: true,
        fillColor: const Color(0xFF16213E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      onChanged: (_) => onChanged(),
    );
  }
}
