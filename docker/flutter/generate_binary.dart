#!/usr/bin/env dart
// Script to generate binary RFW test file from text format

import 'dart:io';
import 'package:rfw/formats.dart';

void main(List<String> args) {
  if (args.length != 2) {
    print('Usage: dart run generate_binary.dart <input.rfwtxt> <output.rfw>');
    print('Converts a text RFW file to binary format.');
    exit(1);
  }

  final inputPath = args[0];
  final outputPath = args[1];

  try {
    // Read text file
    final textFile = File(inputPath);
    if (!textFile.existsSync()) {
      print('❌ Input file not found: $inputPath');
      exit(1);
    }

    final content = textFile.readAsStringSync();
    print('📄 Reading text format: $inputPath');

    // Parse text format
    final library = parseLibraryFile(content);
    print('✅ Parsed successfully');

    // Encode to binary
    final binaryBlob = encodeLibraryBlob(library);
    print('📦 Encoded to binary: ${binaryBlob.length} bytes');

    // Write binary file
    final binaryFile = File(outputPath);
    binaryFile.writeAsBytesSync(binaryBlob);
    print('💾 Written to: $outputPath');

    print('');
    print('✅ Binary file generated successfully!');
  } catch (e) {
    print('❌ Error: $e');
    exit(1);
  }
}
