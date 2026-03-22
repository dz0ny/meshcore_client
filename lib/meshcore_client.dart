/// MeshCore BLE companion protocol client library.
///
/// Provides BLE connection management, command queueing, protocol
/// frame parsing/building, and data models for communicating with
/// MeshCore companion radio devices.
///
/// Primary entry point: [MeshCoreBleService]
library meshcore_client;

// Constants & opcode names
export 'src/meshcore_constants.dart';
export 'src/meshcore_opcode_names.dart';

// Binary I/O utilities
export 'src/buffer_reader.dart';
export 'src/buffer_writer.dart';

// Data models
export 'src/models/advert_location.dart';
export 'src/models/contact.dart';
export 'src/models/contact_telemetry.dart';
export 'src/models/ble_packet_log.dart';
export 'src/models/message.dart';
export 'src/models/sent_message_tracker.dart';

// Protocol frame parsing / building
export 'src/protocol/frame_parser.dart';
export 'src/protocol/frame_builder.dart';

// High-level service facade
export 'src/meshcore_service_base.dart';
export 'src/meshcore_ble_service.dart';
export 'src/meshcore_tcp_service.dart';
export 'src/meshcore_serial_service.dart';

// BLE layer callback types (needed for onRawDataReceived wiring)
export 'src/ble/ble_response_handler.dart'
    show OnChannelDataReceivedCallback, OnRawDataReceivedCallback;
