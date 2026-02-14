import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:voxelshift/core/conversion/converter.dart';
import 'package:voxelshift/core/models/conversion_options.dart';

/// Simple CLI tool to convert CTB files to NanoDLP format.
/// 
/// Usage (via Flutter, which provides dart:ui):
///   flutter run --profile bin/convert_ctb.dart -- input.ctb output.nanodlp
///   flutter run --release bin/convert_ctb.dart -- input.ctb output.nanodlp
///
/// For benchmarking, use Profile or Release mode:
///   Profile:  ~2-3s for 40 layers (JIT + PGO)
///   Release: ~1-2s for 40 layers (full AOT)
///   Debug:   ~16s for 40 layers (unoptimized JIT)
/// 
/// Exit codes:
///   0 = Success
///   1 = Argument error or conversion failed
void main(List<String> args) async {
  if (args.isEmpty || args.length < 2) {
    print('Usage: flutter run [--profile|--release] bin/convert_ctb.dart -- <input.ctb> <output.nanodlp>');
    print('');
    print('Examples:');
    print('  flutter run --profile bin/convert_ctb.dart -- input.ctb output.nanodlp');
    print('  flutter run --release bin/convert_ctb.dart -- input.ctb output.nanodlp');
    exit(1);
  }

  final inputPath = args[0];
  final outputPath = args[1];

  final inputFile = File(inputPath);
  if (!await inputFile.exists()) {
    print('Error: Input file not found: $inputPath');
    exit(1);
  }

  final converter = CtbToNanoDlpConverter();
  
  // Log messages to stdout
  converter.addLogListener(print);

  print('Starting conversion...');
  final stopwatch = Stopwatch()..start();

  try {
    final result = await converter.convert(
      inputPath,
      options: ConversionOptions(
        outputDirectory: File(outputPath).parent.path,
        outputFileName: p.basenameWithoutExtension(outputPath),
      ),
      onProgress: (p) {
        // Print progress every 25%
        if (p.current == 0 || p.fraction % 0.25 < 0.01 || p.current == p.total) {
          final pct = (p.fraction * 100).toStringAsFixed(0);
          print('Progress: $pct% — ${p.phase} (${p.current}/${p.total})');
        }
      },
    );

    stopwatch.stop();

    if (result.success) {
      print('✓ Conversion succeeded in ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2)}s');
      print('  Output: ${result.outputPath}');
      print('  Size: ${(result.outputFileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB');
      print('  Layers: ${result.layerCount}');
      exit(0);
    } else {
      print('✗ Conversion failed: ${result.errorMessage}');
      exit(1);
    }
  } catch (e, st) {
    print('✗ Error: $e');
    print(st);
    exit(1);
  }
}
