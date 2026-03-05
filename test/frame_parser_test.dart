import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/buffer_reader.dart';
import 'package:meshcore_client/src/models/message.dart';
import 'package:meshcore_client/src/protocol/frame_parser.dart';

void main() {
  group('FrameParser', () {
    test('does not treat bracketed payload prefixes as sender names', () {
      final payload = Uint8List.fromList([
        0x01, // channel idx
        0x00, // path len
        MessageTextType.plain.value,
        0x78, 0x56, 0x34, 0x12, // timestamp
        ...'[ops]: status'.codeUnits,
      ]);

      final message = FrameParser.parseChannelMessage(BufferReader(payload));

      expect(message.channelIdx, 1);
      expect(message.senderName, isNull);
      expect(message.text, '[ops]: status');
    });

    test('decodes SMAZ-prefixed channel text and keeps sender', () {
      final payload = Uint8List.fromList([
        0x01, // channel idx
        0x00, // path len
        MessageTextType.plain.value,
        0x78, 0x56, 0x34, 0x12, // timestamp
        ...'Alice: s:AQ=='.codeUnits, // "the"
      ]);

      final message = FrameParser.parseChannelMessage(BufferReader(payload));

      expect(message.senderName, 'Alice');
      expect(message.text, 'the');
    });

    test('parses V3 channel frames with path bytes before txt type', () {
      final payload = Uint8List.fromList([
        0x14, // snr * 4
        0x01, // flags: has path bytes
        0x00, // reserved
        0x02, // channel idx
        0x02, // path len
        0xAA, 0xBB, // path bytes
        MessageTextType.plain.value,
        0x78, 0x56, 0x34, 0x12, // timestamp
        ...'Bob: status ok'.codeUnits,
      ]);

      final message = FrameParser.parseChannelMessageV3(BufferReader(payload));

      expect(message.channelIdx, 2);
      expect(message.pathLen, 2);
      expect(message.senderName, 'Bob');
      expect(message.text, 'status ok');
      expect(message.senderTimestamp, 0x12345678);
    });
  });
}
