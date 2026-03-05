import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_client/src/protocol/frame_builder.dart';

void main() {
  group('FrameBuilder', () {
    test('terminates app start payload with null byte', () {
      final frame = FrameBuilder.buildAppStart(appName: 'MeshCore SAR');

      expect(frame.last, 0);
    });

    test('terminates direct text messages with null byte', () {
      final frame = FrameBuilder.buildSendTxtMsg(
        contactPublicKey: Uint8List.fromList(List<int>.filled(32, 0xAB)),
        text: 'status',
      );

      expect(frame.last, 0);
    });

    test('terminates channel text messages with null byte', () {
      final frame = FrameBuilder.buildSendChannelTxtMsg(
        channelIdx: 0,
        text: 'public update',
      );

      expect(frame.last, 0);
    });

    test('terminates login payload with null byte', () {
      final frame = FrameBuilder.buildSendLogin(
        roomPublicKey: Uint8List.fromList(List<int>.filled(32, 0xCD)),
        password: 'secret',
      );

      expect(frame.last, 0);
    });
  });
}
