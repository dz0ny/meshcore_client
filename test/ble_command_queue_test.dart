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

    test('completes data commands with the expected response code', () async {
      final queue = BleCommandQueue();

      final future = queue.enqueue<String>(
        data: Uint8List.fromList([0x16]),
        commandCode: 0x16,
        responseType: CommandResponseType.data,
        expectedResponseCode: 0x0D,
        timeout: const Duration(seconds: 1),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      queue.completeCommand<String>(0x0D, 'device-info');

      await expectLater(future, completion('device-info'));
      expect(queue.pendingResponseCount, 0);
    });

    test('activates data commands before the response can arrive', () async {
      final queue = BleCommandQueue();

      final handle = queue.enqueueCommand<String>(
        data: Uint8List.fromList([0x01]),
        commandCode: 0x01,
        responseType: CommandResponseType.data,
        expectedResponseCode: MeshCoreConstants.respSelfInfo,
        timeout: const Duration(seconds: 1),
      );

      await handle.active;
      queue.completeCommand<String>(MeshCoreConstants.respSelfInfo, 'self-info');

      await expectLater(handle.completion, completion('self-info'));
      expect(queue.pendingResponseCount, 0);
    });

    test('propagates current-command errors for ACK commands', () async {
      final queue = BleCommandQueue();

      final future = queue.enqueue<void>(
        data: Uint8List.fromList([0x03]),
        commandCode: 0x03,
        responseType: CommandResponseType.ack,
        timeout: const Duration(seconds: 1),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      queue.completeCurrentCommandWithError('bad state', errorCode: 4);

      await expectLater(future, throwsA(isA<Exception>()));
      expect(queue.pendingResponseCount, 0);
    });

    test('clear fails pending commands and empties queue state', () async {
      final queue = BleCommandQueue();

      final future = queue.enqueue<void>(
        data: Uint8List.fromList([0x03]),
        commandCode: 0x03,
        responseType: CommandResponseType.ack,
        timeout: const Duration(seconds: 1),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      queue.clear();

      await expectLater(future, throwsA(isA<Exception>()));
      expect(queue.queueSize, 0);
      expect(queue.pendingResponseCount, 0);
    });
  });
}
