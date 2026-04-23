#!/usr/bin/env dart
// RFW (Remote Flutter Widgets) Validator
// Validates .rfwtxt or .rfw files for syntax errors

import 'dart:io';
import 'dart:typed_data';
import 'package:rfw/formats.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Usage: dart run validate_rfw.dart <file.rfwtxt|file.rfw>');
    print('');
    print('Validates Remote Flutter Widget files for syntax errors.');
    print('Supports both text (.rfwtxt) and binary (.rfw) formats.');
    exit(1);
  }

  final filePath = args[0];
  final file = File(filePath);

  if (!file.existsSync()) {
    print('❌ File not found: $filePath');
    exit(1);
  }

  try {
    print('Validating RFW file: $filePath');
    print('─' * 50);

    // Read file as bytes to detect format
    final bytes = file.readAsBytesSync();

    // Check for binary format signature (FE 52 46 57 in hex)
    final isBinary = bytes.length >= 4 &&
                     bytes[0] == 0xFE &&
                     bytes[1] == 0x52 &&
                     bytes[2] == 0x46 &&
                     bytes[3] == 0x57;

    final RemoteWidgetLibrary library;

    if (isBinary) {
      print('📦 Format: Binary (.rfw)');
      // Parse binary format - fast and efficient
      library = decodeLibraryBlob(Uint8List.fromList(bytes));
    } else {
      print('📄 Format: Text (.rfwtxt)');
      // Parse text format - human-readable but slower
      final content = String.fromCharCodes(bytes);
      library = parseLibraryFile(content);
    }

    print('✅ Syntax is valid!');
    print('');

    // Show some stats
    final imports = library.imports;
    final widgets = library.widgets;

    print('📊 Statistics:');
    print('  - Imports: ${imports.length}');
    if (imports.isNotEmpty) {
      for (var import in imports) {
        print('    • $import');
      }
    } else {
      print('    ⚠️  No imports found (may cause runtime issues)');
    }

    print('  - Widgets defined: ${widgets.length}');
    if (widgets.isNotEmpty) {
      for (var widget in widgets) {
        print('    • ${widget.name}');
      }
    }

    print('');

    // Optionally show binary size
    try {
      final blob = encodeLibraryBlob(library);
      print('💾 Binary encoding size: ${blob.length} bytes');
    } catch (e) {
      print('⚠️  Could not encode to binary: $e');
    }

    print('');
    print('✅ Validation successful!');
    exit(0);

  } catch (e) {
    print('❌ Syntax error detected:');
    print('');
    print('  $e');
    print('');
    print('Please fix the syntax errors and try again.');
    exit(1);
  }
}
