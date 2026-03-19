import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/buffer_reader.dart';
import 'package:meshcore_client/src/models/contact.dart';
import 'package:meshcore_client/src/models/message.dart';
import 'package:meshcore_client/src/protocol/frame_parser.dart';

void main() {
  group('FrameParser', () {
    test('parses V3 contact messages with shifted text type values', () {
      final payload = Uint8List.fromList([
        0x08, // snr * 4
        0x00,
        0x00,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // pubkey prefix
        0x03, // path len
        MessageTextType.signedPlain.value << 2,
        0x78, 0x56, 0x34, 0x12, // timestamp
        0x11, 0x22, 0x33, 0x44, // signed sender prefix
        ...'signed hello'.codeUnits,
      ]);

      final message = FrameParser.parseContactMessageV3(BufferReader(payload));

      expect(message.messageType, MessageType.contact);
      expect(message.senderKeyShort, 'aabbccddeeff');
      expect(message.pathLen, 3);
      expect(message.textType, MessageTextType.signedPlain);
      expect(message.text, 'signed hello');
      expect(message.senderTimestamp, 0x12345678);
      expect(message.roomPostAuthorPrefix, isNotNull);
      expect(
        message.roomPostAuthorKeyShort,
        '11223344',
      );
      expect(message.isRoomPost, isTrue);
    });

    test('room post author is null for non-signed messages', () {
      final payload = Uint8List.fromList([
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, // no path
        MessageTextType.plain.value,
        0x78, 0x56, 0x34, 0x12,
        ...'hello from DM'.codeUnits,
      ]);

      final message = FrameParser.parseContactMessage(BufferReader(payload));

      expect(message.roomPostAuthorPrefix, isNull);
      expect(message.roomPostAuthorKeyShort, isNull);
      expect(message.isRoomPost, isFalse);
      expect(message.text, 'hello from DM');
    });

    test('parses contact message descriptor into hop count', () {
      final payload = Uint8List.fromList([
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x42, // 2 hops, 2-byte hashes
        MessageTextType.plain.value,
        0x78, 0x56, 0x34, 0x12,
        ...'hello'.codeUnits,
      ]);

      final message = FrameParser.parseContactMessage(BufferReader(payload));

      expect(message.pathLen, 2);
      expect(message.text, 'hello');
    });

    test('decodes SMAZ-prefixed contact messages', () {
      final payload = Uint8List.fromList([
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // pubkey prefix
        0x00, // path len
        MessageTextType.plain.value,
        0x78, 0x56, 0x34, 0x12, // timestamp
        ...'s:AQ=='.codeUnits, // "the"
      ]);

      final message = FrameParser.parseContactMessage(BufferReader(payload));

      expect(message.messageType, MessageType.contact);
      expect(message.senderKeyShort, 'aabbccddeeff');
      expect(message.textType, MessageTextType.plain);
      expect(message.text, 'the');
    });

    test('keeps CLI contact messages undecoded', () {
      final payload = Uint8List.fromList([
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // pubkey prefix
        0x00, // path len
        MessageTextType.cliData.value,
        0x78, 0x56, 0x34, 0x12, // timestamp
        ...'s:AQ=='.codeUnits,
      ]);

      final message = FrameParser.parseContactMessage(BufferReader(payload));

      expect(message.textType, MessageTextType.cliData);
      expect(message.text, 's:AQ==');
    });

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
        0x42, // 2 hops, 2-byte hashes
        0xAA, 0xBB, 0xCC, 0xDD, // path bytes
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

    test('parses V3 channel frames without consuming absent path bytes', () {
      final payload = Uint8List.fromList([
        0x10, // snr * 4
        0x00, // flags: no path bytes present
        0x00, // reserved
        0x04, // channel idx
        0x02, // path len metadata
        MessageTextType.plain.value,
        0x04, 0x03, 0x02, 0x01, // timestamp
        ...'plain update'.codeUnits,
      ]);

      final message = FrameParser.parseChannelMessageV3(BufferReader(payload));

      expect(message.channelIdx, 4);
      expect(message.pathLen, 2);
      expect(message.textType, MessageTextType.plain);
      expect(message.text, 'plain update');
      expect(message.senderName, isNull);
      expect(message.senderTimestamp, 0x01020304);
    });

    test('parses contact records with unsigned route descriptor', () {
      final payload = Uint8List.fromList([
        ...List<int>.filled(32, 0x11),
        0x01,
        0x00,
        0x82, // 2 hops, 3-byte hashes
        ...List<int>.filled(64, 0x22),
        ...List<int>.filled(32, 0x00),
        0x78, 0x56, 0x34, 0x12,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xEF, 0xCD, 0xAB, 0x90,
      ]);

      final contact = FrameParser.parseContact(BufferReader(payload));

      expect(contact.outPathLen, 0x82);
      expect(contact.hasPath, isTrue);
      expect(contact.pathHashSize, 3);
      expect(contact.pathHopCount, 2);
      expect(contact.pathByteLength, 6);
    });

    test('parses sensor contact records as sensor type', () {
      final payload = Uint8List.fromList([
        ...List<int>.filled(32, 0x44),
        0x04,
        0x00,
        0x00,
        ...List<int>.filled(64, 0x00),
        ...'WX Station'.codeUnits,
        ...List<int>.filled(32 - 'WX Station'.length, 0x00),
        0x78,
        0x56,
        0x34,
        0x12,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xEF,
        0xCD,
        0xAB,
        0x90,
      ]);

      final contact = FrameParser.parseContact(BufferReader(payload));

      expect(contact.type, ContactType.sensor);
      expect(contact.isSensor, isTrue);
      expect(contact.displayName, 'WX Station');
    });
  });
}
