import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxelshift/core/conversion/converter.dart';
import 'package:voxelshift/core/models/models.dart';

void main() {
  group('Large File Benchmark', () {
    test('largefile.ctb converts efficiently', () async {
      final largeFilePath = r'E:\VoxelShift_TestData\largefile.ctb';
      final largeFile = File(largeFilePath);

      if (!await largeFile.exists()) {
        print('⚠️  Large file not found at $largeFilePath');
        return;
      }

      final fileSizeMb = (await largeFile.length()) / 1024 / 1024;
      print('\n📊 Large File Benchmark');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('File: largefile.ctb');
      print('Size: ${fileSizeMb.toStringAsFixed(1)} MB');

      final converter = CtbToNanoDlpConverter();
      converter.addLogListener(print);

      final sw = Stopwatch()..start();
      int lastProgress = 0;

      final result = await converter.convert(
        largeFilePath,
        options: ConversionOptions(
          outputDirectory: r'E:\VoxelShift_TestData\output',
          outputFileName: 'largefile_benchmark',
        ),
        onProgress: (p) {
          final percentDone = (p.fraction * 100).toInt();
          if (percentDone - lastProgress >= 10 || percentDone >= 100) {
            print('[PROGRESS] ${p.phase}: ${percentDone}% (${p.current}/${p.total})');
            lastProgress = percentDone;
          }
        },
      );

      sw.stop();

      print('\n📈 Benchmark Results');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      if (result.success) {
        final elapsedSec = sw.elapsedMilliseconds / 1000;
        final layerTime = (sw.elapsedMilliseconds / result.layerCount).toStringAsFixed(1);
        final throughput = (result.layerCount / elapsedSec).toStringAsFixed(1);
        
        print('✅ Conversion succeeded');
        print('   Layers: ${result.layerCount}');
        print('   Duration: ${elapsedSec.toStringAsFixed(1)}s');
        print('   Time/layer: ${layerTime}ms');
        print('   Throughput: $throughput layers/sec');
        print('   Output size: ${(result.outputFileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB');
      } else {
        print('❌ Conversion failed: ${result.errorMessage}');
      }
      print('');

      expect(result.success, isTrue);
    });
  });
}
