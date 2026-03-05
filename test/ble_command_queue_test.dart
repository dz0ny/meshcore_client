import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/ble/ble_command_queue.dart';
import 'package:meshcore_client/src/meshcore_constants.dart';

void main() {
  group('BleCommandQueue', () {
    test('serializes ACK commands until the prior ACK completes', () async {
      final queue = BleCommandQueue();

      final first = queue.enqueue<void>(
        data: Uint8List.fromList([0x03]),
        commandCode: 0x03,
        responseType: CommandResponseType.ack,
        timeout: const Duration(seconds: 1),
      );
      final second = queue.enqueue<void>(
        data: Uint8List.fromList([0x20]),
        commandCode: 0x20,
        responseType: CommandResponseType.ack,
        timeout: const Duration(seconds: 1),
      );

      var secondCompleted = false;
      unawaited(second.then((_) {
        secondCompleted = true;
      }));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      queue.completeCommand<void>(MeshCoreConstants.respOk, null);
      await first;

      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(secondCompleted, isFalse);

      queue.completeCommand<void>(MeshCoreConstants.respOk, null);
      await second;
      expect(secondCompleted, isTrue);
    });

    test('cleans up pending ACK state after timeout', () async {
      final queue = BleCommandQueue();

      expect(
        () => queue.enqueue<void>(
          data: Uint8List.fromList([0x03]),
          commandCode: 0x03,
          responseType: CommandResponseType.ack,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(queue.pendingResponseCount, 0);
    });
  });
}
