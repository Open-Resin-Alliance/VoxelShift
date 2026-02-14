import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxelshift/core/conversion/ctb_parser.dart';
import 'package:voxelshift/core/conversion/converter.dart';
import 'package:voxelshift/core/models/models.dart';

void main() {
  const testFilePath = r'E:\VoxelShift_TestData\A.ctb';

  group('CTB Parser - A.ctb (CTBv4E)', () {
    late CtbParser parser;

    setUpAll(() async {
      final file = File(testFilePath);
      if (!await file.exists()) {
        fail('Test file not found: $testFilePath');
      }
      parser = await CtbParser.open(testFilePath);
    });

    tearDownAll(() async {
      await parser.close();
    });

    test('reads header fields correctly', () {
      print('=== CTBv4E Header ===');
      print('Magic: 0x${parser.magic.toRadixString(16)}');
      print('Version: ${parser.version}');
      print('Resolution: ${parser.resolutionX} x ${parser.resolutionY}');
      print('Display: ${parser.bedXMm} x ${parser.bedYMm} mm');
      print('Machine Z: ${parser.bedZMm} mm');
      print('Layer height: ${parser.layerHeightMm} mm');
      print('Layer count: ${parser.layerCount}');
      print('Exposure: ${parser.exposureTime}s / Bottom: ${parser.bottomExposureTime}s');
      print('Bottom layers: ${parser.bottomLayerCount}');
      print('Lift height: ${parser.liftHeight} mm');
      print('Lift speed: ${parser.liftSpeed} mm/min');
      print('Retract speed: ${parser.retractSpeed} mm/min');
      print('Encryption key: 0x${parser.encryptionKey.toRadixString(16)}');
      print('Preview large offset: 0x${parser.previewLargeOffset.toRadixString(16)}');
      print('Preview small offset: 0x${parser.previewSmallOffset.toRadixString(16)}');
      print('Print time: ${parser.printTime}s');
      print('Machine name: ${parser.machineName}');

      // Known values from hex dump analysis
      expect(parser.magic, equals(0x12FD0107));
      expect(parser.resolutionX, equals(15120));
      expect(parser.resolutionY, equals(6230));
      expect(parser.layerCount, equals(40));
      expect(parser.layerHeightMm, closeTo(0.05, 0.001));
      expect(parser.exposureTime, closeTo(2.3, 0.1));
      expect(parser.bottomExposureTime, closeTo(32.0, 0.1));
      expect(parser.encryptionKey, equals(0x4F4295C8));
    });

    test('reads preview images', () async {
      final largePng = await parser.readPreviewLarge();
      final smallPng = await parser.readPreviewSmall();

      print('Large preview: ${largePng?.length ?? 0} bytes');
      print('Small preview: ${smallPng?.length ?? 0} bytes');

      // At least one should be available
      if (largePng != null) {
        expect(largePng.length, greaterThan(100));
        // PNG magic: 0x89 0x50 0x4E 0x47
        expect(largePng[0], equals(0x89));
        expect(largePng[1], equals(0x50)); // 'P'
      }
      if (smallPng != null) {
        expect(smallPng.length, greaterThan(100));
      }
    });

    test('decodes layer 0 correctly', () async {
      final pixels = await parser.readLayerImage(0);
      final expectedPixels = parser.resolutionX * parser.resolutionY;

      print('Layer 0: ${pixels.length} pixels (expected $expectedPixels)');
      expect(pixels.length, equals(expectedPixels));

      // Count non-zero pixels
      int nonZero = 0;
      for (int i = 0; i < pixels.length; i++) {
        if (pixels[i] > 0) nonZero++;
      }
      print('Layer 0 non-zero pixels: $nonZero / $expectedPixels '
          '(${(nonZero / expectedPixels * 100).toStringAsFixed(1)}%)');

      // Layer 0 should have content (it's a bottom layer)
      expect(nonZero, greaterThan(0));
    });

    test('decodes all layers', () async {
      final expectedPixels = parser.resolutionX * parser.resolutionY;
      print('Decoding all ${parser.layerCount} layers...');

      for (int i = 0; i < parser.layerCount; i++) {
        final pixels = await parser.readLayerImage(i);
        expect(pixels.length, equals(expectedPixels),
            reason: 'Layer $i pixel count mismatch');

        if (i == 0 || i == parser.layerCount - 1 || i == parser.layerCount ~/ 2) {
          int nonZero = 0;
          for (int j = 0; j < pixels.length; j++) {
            if (pixels[j] > 0) nonZero++;
          }
          print('  Layer $i: $nonZero non-zero pixels '
              '(${(nonZero / expectedPixels * 100).toStringAsFixed(1)}%)');
        }
      }
      print('All layers decoded successfully.');
    });
  });

  group('Full Conversion - A.ctb', () {
    test('converts to .nanodlp', timeout: Timeout(Duration(minutes: 5)), () async {
      final file = File(testFilePath);
      if (!await file.exists()) {
        fail('Test file not found: $testFilePath');
      }

      final converter = CtbToNanoDlpConverter();
      final logMessages = <String>[];
      converter.addLogListener((msg) {
        logMessages.add(msg);
        print('[LOG] $msg');
      });

      final outputDir = r'E:\VoxelShift_TestData\output';
      await Directory(outputDir).create(recursive: true);

      final result = await converter.convert(
        testFilePath,
        options: ConversionOptions(
          outputDirectory: outputDir,
          outputFileName: 'A_test_output',
        ),
        onProgress: (p) {
          if (p.current % 10 == 0 || p.current == p.total) {
            print('[PROGRESS] ${p.phase} ${p.current}/${p.total}');
          }
        },
      );

      print('\n=== Conversion Result ===');
      print('Success: ${result.success}');
      if (!result.success) {
        print('Error: ${result.errorMessage}');
      }
      print('Output: ${result.outputPath}');
      print('Layers: ${result.layerCount}');
      print('File size: ${result.outputFileSizeBytes} bytes '
          '(${(result.outputFileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB)');
      print('Duration: ${result.duration.inMilliseconds}ms');
      print('Target: ${result.targetProfile}');

      expect(result.success, isTrue, reason: result.errorMessage ?? '');
      expect(result.layerCount, equals(40));
      expect(result.outputFileSizeBytes, greaterThan(0));

      // Verify the output file exists
      final outputFile = File(result.outputPath);
      expect(await outputFile.exists(), isTrue);
      print('\nOutput file verified: ${result.outputPath}');
    });
  });
}
