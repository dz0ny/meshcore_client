import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/helpers/smaz.dart';

void main() {
  group('Smaz', () {
    test('decodes prefixed payloads with leading whitespace', () {
      expect(Smaz.tryDecodePrefixed('  s:AQ=='), 'the');
    });

    test('returns null for invalid prefixed payloads', () {
      expect(Smaz.tryDecodePrefixed('s:not-valid'), isNull);
    });

    test('throws on truncated verbatim runs', () {
      expect(
        () => Smaz.decompressBytes(Uint8List.fromList([255, 3, 0x41])),
        throwsFormatException,
      );
    });
  });
}
