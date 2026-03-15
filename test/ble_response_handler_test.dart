import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/ble/ble_command_queue.dart';
import 'package:meshcore_client/src/ble/ble_response_handler.dart';
import 'package:meshcore_client/src/meshcore_constants.dart';
import 'package:meshcore_client/src/models/contact.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('BleResponseHandler', () {
    test('correlates RESP_SENT to queued direct-message contacts in order', () {
      final handler = BleResponseHandler();
      final first = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final second = Uint8List.fromList(List<int>.generate(32, (i) => 32 - i));
      final seen = <Uint8List?>[];

      handler.queuePendingDirectMessageContact(first);
      handler.queuePendingDirectMessageContact(second);
      handler.onMessageSent = (tag, timeout, isFloodMode, contactPublicKey) {
        seen.add(contactPublicKey);
      };

      handler.feedData([
        MeshCoreConstants.respSent,
        0x00, // direct send
        0x11, 0x22, 0x33, 0x44,
        0x10, 0x00, 0x00, 0x00,
      ]);
      handler.feedData([
        MeshCoreConstants.respSent,
        0x00, // direct send
        0x55, 0x66, 0x77, 0x88,
        0x20, 0x00, 0x00, 0x00,
      ]);

      expect(seen, hasLength(2));
      expect(seen[0], orderedEquals(first));
      expect(seen[1], orderedEquals(second));
    });

    test(
      'correlates ERR_NOT_FOUND to the oldest queued direct-message contact',
      () {
        final handler = BleResponseHandler();
        final first = Uint8List.fromList(List<int>.generate(32, (i) => i));
        final second = Uint8List.fromList(
          List<int>.generate(32, (i) => 255 - i),
        );
        Uint8List? missingContact;
        Uint8List? sentContact;

        handler.queuePendingDirectMessageContact(first);
        handler.queuePendingDirectMessageContact(second);
        handler.onContactNotFound = (contactPublicKey) {
          missingContact = contactPublicKey;
        };
        handler.onMessageSent = (tag, timeout, isFloodMode, contactPublicKey) {
          sentContact = contactPublicKey;
        };

        handler.feedData([
          MeshCoreConstants.respErr,
          MeshCoreConstants.errNotFound,
        ]);
        handler.feedData([
          MeshCoreConstants.respSent,
          0x00, // direct send
          0x99, 0x88, 0x77, 0x66,
          0x30, 0x00, 0x00, 0x00,
        ]);

        expect(missingContact, orderedEquals(first));
        expect(sentContact, orderedEquals(second));
      },
    );

    test('correlates ERR_NOT_FOUND to the last lookup contact', () {
      final handler = BleResponseHandler();
      final missing = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      Uint8List? missingContact;

      handler.setLastLookupContactPublicKey(missing);
      handler.onContactNotFound = (contactPublicKey) {
        missingContact = contactPublicKey;
      };

      handler.feedData([
        MeshCoreConstants.respErr,
        MeshCoreConstants.errNotFound,
      ]);

      expect(missingContact, orderedEquals(missing));
    });

    test('labels LOG_RX_DATA response packets like meshcore-open', () {
      final payload = Uint8List.fromList([
        0xFE,
        0x5A,
        0x62,
        0x88,
        0xD9,
        0x89,
        0xE5,
        0x07,
        0xC6,
        0x21,
        0x84,
        0x10,
        0xA1,
        0x97,
        0x38,
        0x83,
        0xEF,
        0xD2,
        0x5D,
        0x78,
        0x60,
        0xE8,
        0xB5,
        0xAA,
        0x19,
        0xBA,
        0x22,
        0x40,
        0xFD,
        0x67,
        0xA6,
        0x3B,
        0xCF,
        0x69,
        0x0D,
        0xE2,
      ]);

      expect(BleResponseHandler.logRxPayloadTypeLabel(0x01), 'RESP');
      expect(
        BleResponseHandler.decodeLogRxPayloadSummary(0x01, payload),
        'RESP payload=36 bytes',
      );
    });

    test(
      'emits received channel message from decrypted LOG_RX_DATA GRP_TXT',
      () {
        final handler = BleResponseHandler();
        final secret = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
        MessageRecord? seen;

        handler.onMessageReceived = (message) {
          seen = MessageRecord(
            channelIdx: message.channelIdx,
            senderTimestamp: message.senderTimestamp,
            text: message.text,
            senderName: message.senderName,
          );
        };

        handler.feedData([
          MeshCoreConstants.respChannelInfo,
          0x02,
          ..._fixedCString('#ops', 32),
          ...secret,
        ]);

        final senderTimestamp = 0x01020304;
        final plain = Uint8List.fromList([
          0x04,
          0x03,
          0x02,
          0x01,
          0x00,
          ...'alice: hello team'.codeUnits,
          0x00,
          ...List<int>.filled(32, 0),
        ]);
        final paddedPlain = Uint8List.fromList(plain.sublist(0, 32));
        final encrypted = _aes128EcbEncrypt(secret, paddedPlain);
        final mac = _packetMac(secret, encrypted);
        final channelHash = crypto.sha256.convert(secret).bytes.first;
        final rawPacket = Uint8List.fromList([
          0x15,
          0x01,
          0x55,
          channelHash,
          ...mac,
          ...encrypted,
        ]);

        handler.feedData([
          MeshCoreConstants.pushLogRxData,
          0x10,
          0x9c,
          ...rawPacket,
        ]);

        expect(seen, isNotNull);
        expect(seen!.channelIdx, 2);
        expect(seen!.senderTimestamp, senderTimestamp);
        expect(seen!.senderName, 'alice');
        expect(seen!.text, 'hello team');
      },
    );

    test('does not re-emit our echoed channel message as received', () {
      final handler = BleResponseHandler();
      final secret = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      MessageRecord? seen;
      String? echoedMessageId;
      int? echoedCount;

      handler.setOurNodeHash(0x55);
      handler.trackSentMessage(
        'msg-1',
        null,
        channelIdx: 2,
        plainText: 'hello team',
      );
      handler.onMessageReceived = (message) {
        seen = MessageRecord(
          channelIdx: message.channelIdx,
          senderTimestamp: message.senderTimestamp,
          text: message.text,
          senderName: message.senderName,
        );
      };
      handler.onMessageEchoDetected = (messageId, echoCount, snrRaw, rssiDbm) {
        echoedMessageId = messageId;
        echoedCount = echoCount;
      };

      handler.feedData([
        MeshCoreConstants.respChannelInfo,
        0x02,
        ..._fixedCString('#ops', 32),
        ...secret,
      ]);

      final plain = Uint8List.fromList([
        0x04,
        0x03,
        0x02,
        0x01,
        0x00,
        ...'alice: hello team'.codeUnits,
        0x00,
        ...List<int>.filled(32, 0),
      ]);
      final paddedPlain = Uint8List.fromList(plain.sublist(0, 32));
      final encrypted = _aes128EcbEncrypt(secret, paddedPlain);
      final mac = _packetMac(secret, encrypted);
      final channelHash = crypto.sha256.convert(secret).bytes.first;
      final rawPacket = Uint8List.fromList([
        0x15,
        0x01,
        0x55,
        channelHash,
        ...mac,
        ...encrypted,
      ]);

      handler.feedData([
        MeshCoreConstants.pushLogRxData,
        0x10,
        0x9c,
        ...rawPacket,
      ]);

      expect(seen, isNull);
      expect(echoedMessageId, 'msg-1');
      expect(echoedCount, 1);
    });

    test('completes queued GET_CHANNEL when CHANNEL_INFO arrives', () async {
      final handler = BleResponseHandler();
      final queue = BleCommandQueue();
      handler.setCommandQueue(queue);

      final future = queue.enqueue<Map<String, dynamic>>(
        data: Uint8List.fromList([MeshCoreConstants.cmdGetChannel, 0x02]),
        commandCode: MeshCoreConstants.cmdGetChannel,
        responseType: CommandResponseType.data,
        expectedResponseCode: MeshCoreConstants.respChannelInfo,
        timeout: const Duration(seconds: 1),
      );

      handler.feedData([
        MeshCoreConstants.respChannelInfo,
        0x02,
        ..._fixedCString('#ops', 32),
        ...Uint8List.fromList(List<int>.generate(16, (i) => i + 1)),
      ]);

      await expectLater(
        future,
        completion(
          allOf(
            containsPair('channelIdx', 2),
            containsPair('channelName', '#ops'),
          ),
        ),
      );
      expect(queue.pendingResponseCount, 0);
    });

    test('completes queued GET_CONTACT_BY_KEY when CONTACT arrives', () async {
      final handler = BleResponseHandler();
      final queue = BleCommandQueue();
      handler.setCommandQueue(queue);
      final publicKey = Uint8List.fromList(List<int>.generate(32, (i) => i));

      final future = queue.enqueue<Contact>(
        data: Uint8List.fromList([
          MeshCoreConstants.cmdGetContactByKey,
          ...publicKey,
        ]),
        commandCode: MeshCoreConstants.cmdGetContactByKey,
        responseType: CommandResponseType.data,
        expectedResponseCode: MeshCoreConstants.respContact,
        timeout: const Duration(seconds: 1),
      );

      handler.feedData(_contactFrame(publicKey, name: 'AT-W-St.Marx'));

      await expectLater(
        future,
        completion(
          isA<Contact>()
              .having((contact) => contact.advName, 'advName', 'AT-W-St.Marx')
              .having(
                (contact) => contact.publicKey,
                'publicKey',
                orderedEquals(publicKey),
              ),
        ),
      );
      expect(queue.pendingResponseCount, 0);
    });

    test(
      'completes queued GET_CONTACTS when END_OF_CONTACTS arrives',
      () async {
        final handler = BleResponseHandler();
        final queue = BleCommandQueue();
        handler.setCommandQueue(queue);
        final publicKey = Uint8List.fromList(List<int>.generate(32, (i) => i));

        final future = queue.enqueue<List<Contact>>(
          data: Uint8List.fromList([MeshCoreConstants.cmdGetContacts]),
          commandCode: MeshCoreConstants.cmdGetContacts,
          responseType: CommandResponseType.data,
          expectedResponseCode: MeshCoreConstants.respEndOfContacts,
          timeout: const Duration(seconds: 1),
        );

        handler.feedData([
          MeshCoreConstants.respContactsStart,
          0x01,
          0x00,
          0x00,
          0x00,
        ]);
        handler.feedData(_contactFrame(publicKey, name: 'Relay One'));
        handler.feedData([MeshCoreConstants.respEndOfContacts]);

        await expectLater(future, completion(hasLength(1)));
        expect(queue.pendingResponseCount, 0);
      },
    );
  });
}

class MessageRecord {
  final int? channelIdx;
  final int senderTimestamp;
  final String text;
  final String? senderName;

  MessageRecord({
    required this.channelIdx,
    required this.senderTimestamp,
    required this.text,
    required this.senderName,
  });
}

List<int> _fixedCString(String value, int size) {
  final bytes = Uint8List(size);
  final encoded = value.codeUnits;
  bytes.setRange(0, encoded.length, encoded);
  return bytes;
}

List<int> _contactFrame(
  Uint8List publicKey, {
  required String name,
  int type = 2,
  int flags = 0,
  int outPathLen = 0xFF,
  int lastAdvert = 0x01020304,
  int advLat = 0,
  int advLon = 0,
  int lastMod = 0x05060708,
}) {
  final outPath = Uint8List(64);
  final lastAdvertBytes = ByteData(4)..setUint32(0, lastAdvert, Endian.little);
  final advLatBytes = ByteData(4)..setInt32(0, advLat, Endian.little);
  final advLonBytes = ByteData(4)..setInt32(0, advLon, Endian.little);
  final lastModBytes = ByteData(4)..setUint32(0, lastMod, Endian.little);

  return [
    MeshCoreConstants.respContact,
    ...publicKey,
    type,
    flags,
    outPathLen & 0xFF,
    ...outPath,
    ..._fixedCString(name, 32),
    ...lastAdvertBytes.buffer.asUint8List(),
    ...advLatBytes.buffer.asUint8List(),
    ...advLonBytes.buffer.asUint8List(),
    ...lastModBytes.buffer.asUint8List(),
  ];
}

Uint8List _aes128EcbEncrypt(Uint8List secret16, Uint8List plain) {
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(secret16));
  final out = Uint8List(plain.length);
  for (int i = 0; i < plain.length; i += 16) {
    cipher.processBlock(plain, i, out, i);
  }
  return out;
}

Uint8List _packetMac(Uint8List secret16, Uint8List encrypted) {
  final key32 = Uint8List(32)..setRange(0, 16, secret16);
  final digest = crypto.Hmac(crypto.sha256, key32).convert(encrypted).bytes;
  return Uint8List.fromList(digest.sublist(0, 2));
}
