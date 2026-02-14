import 'dart:io';
import 'package:voxelshift/core/conversion/converter.dart';
import 'package:voxelshift/core/models/conversion_options.dart';

/// Benchmark conversion on large CTB file to test adaptive concurrency.
void main(List<String> args) async {
  final inputFile = 'E:\\VoxelShift_TestData\\largefile.ctb';
  final outputDir = 'E:\\VoxelShift_TestData\\output';
  
  if (!await File(inputFile).exists()) {
    print('Error: $inputFile not found');
    exit(1);
  }

  final converter = CtbToNanoDlpConverter();
  converter.addLogListener(print);

  print('╔═══════════════════════════════════════════════════════════╗');
  print('║         LARGE FILE CONVERSION BENCHMARK                 ║');
  print('║     (Adaptive Concurrency + Blank Layer Detection)      ║');
  print('╚═══════════════════════════════════════════════════════════╝');
  print('');

  final sw = Stopwatch()..start();
  int lastProgress = 0;

  try {
    final result = await converter.convert(
      inputFile,
      options: ConversionOptions(
        outputDirectory: outputDir,
        outputFileName: 'largefile_bench',
      ),
      onProgress: (p) {
        final pct = (p.fraction * 100).toInt();
        if (pct % 10 == 0 && pct != lastProgress) {
          final elapsed = sw.elapsedMilliseconds / 1000;
          final perLayer = p.current > 0 ? elapsed / p.current : 0;
          print('Progress: $pct% (${p.current}/${p.total} layers) '
              '– ${elapsed.toStringAsFixed(1)}s elapsed, '
              '${perLayer.toStringAsFixed(2)}s per layer');
          lastProgress = pct;
        }
      },
    );

    sw.stop();

    print('');
    if (result.success) {
      print('✅ SUCCESS');
      print('   Output: ${result.outputPath}');
      print('   Layers: ${result.layerCount}');
      print('   File size: ${(result.outputFileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB');
      print('   Duration: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      print('   Avg per layer: ${(sw.elapsedMilliseconds / result.layerCount / 1000).toStringAsFixed(2)}s');
      exit(0);
    } else {
      print('❌ FAILED: ${result.errorMessage}');
      exit(1);
    }
  } catch (e, st) {
    print('❌ ERROR: $e');
    print(st);
    exit(1);
  }
}
