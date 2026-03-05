import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/ble/ble_response_handler.dart';
import 'package:meshcore_client/src/meshcore_constants.dart';

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

    test('correlates ERR_NOT_FOUND to the oldest queued direct-message contact', () {
      final handler = BleResponseHandler();
      final first = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final second = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
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
  });
}
