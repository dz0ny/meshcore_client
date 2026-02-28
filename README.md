# meshcore_client

Flutter/Dart package implementing the MeshCore BLE companion protocol — connection management, command queueing, frame parsing/building, and data models.

## Installation

```yaml
dependencies:
  meshcore_client:
    path: ../meshcore_client
```

## Usage

```dart
import 'package:meshcore_client/meshcore_client.dart';

final ble = MeshCoreBleService(appName: 'My App');

ble.onConnectionState = (connected) { ... };
ble.onContact = (contact) { ... };
ble.onMessage = (message) { ... };

await ble.connect(device);
await ble.sendTextMessage(contact, 'Hello mesh!');
await ble.disconnect();
```

## Architecture

```
MeshCoreBleService          ← public facade
├── BleConnectionManager    ← BLE connect/disconnect/reconnect
├── BleCommandSender        ← serialised writes to BLE characteristic
│   └── BleCommandQueue     ← queues commands; handles ack/response futures
└── BleResponseHandler      ← decodes incoming frames and fires callbacks
    ├── FrameParser         ← binary → typed responses
    └── FrameBuilder        ← typed commands → binary frames
```

## Dependencies

- [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus) — BLE
- [`latlong2`](https://pub.dev/packages/latlong2) — GPS coordinate types
