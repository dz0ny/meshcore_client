import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../meshcore_opcode_names.dart';
import '../models/ble_packet_log.dart';
import 'ble_command_queue.dart';

/// Callback types for sender events
typedef OnErrorCallback = void Function(String error);

/// Sends commands to the BLE device (or TCP socket via callback)
class BleCommandSender {
  BluetoothCharacteristic? _rxCharacteristic;

  /// Optional TCP write callback - when set, overrides BLE characteristic writes.
  Future<void> Function(Uint8List)? _tcpWriteCallback;

  int _txPacketCount = 0;
  final List<BlePacketLog> _packetLogs = [];
  static const int _maxLogSize = 1000;

  // Command queue for serialization and response waiting
  final BleCommandQueue _commandQueue = BleCommandQueue();

  // Callbacks
  OnErrorCallback? onError;
  VoidCallback? onTxActivity;

  // Getters
  int get txPacketCount => _txPacketCount;
  List<BlePacketLog> get packetLogs => List.unmodifiable(_packetLogs);
  BleCommandQueue get commandQueue => _commandQueue;

  /// Set the RX characteristic to write to (BLE transport)
  void setRxCharacteristic(BluetoothCharacteristic? characteristic) {
    _rxCharacteristic = characteristic;
    _tcpWriteCallback = null;
  }

  /// Set a TCP write callback (overrides BLE characteristic)
  void setTcpWriteCallback(Future<void> Function(Uint8List) callback) {
    _tcpWriteCallback = callback;
    _rxCharacteristic = null;
  }

  bool get _isReady => _rxCharacteristic != null || _tcpWriteCallback != null;

  /// Write data (fire-and-forget, no response expected)
  Future<void> writeData(Uint8List data) async {
    if (!_isReady) {
      throw Exception('Not connected');
    }

    final commandCode = data.isNotEmpty ? data[0] : 0;

    // Enqueue the command (fire-and-forget)
    final handle = _commandQueue.enqueueCommand<void>(
      data: data,
      commandCode: commandCode,
      responseType: CommandResponseType.none,
    );
    await handle.active;

    // Actually send the data
    await _sendToDevice(data);
  }

  /// Write data and wait for ACK (RESP_CODE_OK or RESP_CODE_ERR)
  ///
  /// This method should be used for setup commands that return RESP_CODE_OK (0)
  /// on success or RESP_CODE_ERR (1) on failure.
  ///
  /// Examples: setAdvertLatLon, setAdvertName, setRadioParams, etc.
  Future<void> writeDataAndWaitForAck(Uint8List data) async {
    if (!_isReady) {
      throw Exception('Not connected');
    }

    final commandCode = data.isNotEmpty ? data[0] : 0;

    // Enqueue command but don't await yet — data must be sent to the device
    // before it can respond with an ACK. Awaiting before send would deadlock.
    final handle = _commandQueue.enqueueCommand<void>(
      data: data,
      commandCode: commandCode,
      responseType: CommandResponseType.ack,
    );
    await handle.active;

    // Actually send the data
    await _sendToDevice(data);

    // Now wait for the ACK response
    return handle.completion;
  }

  /// Write data and wait for specific response
  ///
  /// This method should be used for query commands that return specific data.
  ///
  /// Examples:
  /// - CMD_DEVICE_QUERY → RESP_CODE_DEVICE_INFO
  /// - CMD_APP_START → RESP_CODE_SELF_INFO
  /// - CMD_GET_CONTACTS → RESP_CODE_CONTACTS_START
  Future<T> writeDataAndWaitForResponse<T>(
    Uint8List data,
    int expectedResponseCode, {
    Duration? timeout,
  }) async {
    if (!_isReady) {
      throw Exception('Not connected');
    }

    final commandCode = data.isNotEmpty ? data[0] : 0;

    // Enqueue the command (wait for specific response)
    final handle = _commandQueue.enqueueCommand<T>(
      data: data,
      commandCode: commandCode,
      responseType: CommandResponseType.data,
      expectedResponseCode: expectedResponseCode,
      timeout: timeout,
    );
    await handle.active;

    // Actually send the data
    await _sendToDevice(data);

    // Wait for response
    return handle.completion;
  }

  /// Internal method to actually send data to the device (BLE or TCP)
  Future<void> _sendToDevice(Uint8List data) async {
    if (_rxCharacteristic == null && _tcpWriteCallback == null) {
      throw Exception('Not connected');
    }

    try {
      final commandCode = data.isNotEmpty ? data[0] : null;
      final opcodeName = commandCode != null
          ? MeshCoreOpcodeNames.getCommandName(commandCode)
          : 'UNKNOWN';
      final opcodeHex = commandCode != null
          ? '0x${commandCode.toRadixString(16).padLeft(2, '0').toUpperCase()}'
          : 'N/A';

      debugPrint('📤 [TX] Sending command: $opcodeName ($opcodeHex)');
      debugPrint('  Data size: ${data.length} bytes');

      if (_tcpWriteCallback != null) {
        // TCP transport
        await _tcpWriteCallback!(data);
      } else {
        // BLE transport
        final supportsWriteWithoutResponse =
            _rxCharacteristic!.properties.writeWithoutResponse;
        final supportsWrite = _rxCharacteristic!.properties.write;

        if (supportsWriteWithoutResponse) {
          await _rxCharacteristic!.write(data, withoutResponse: true);
        } else if (supportsWrite) {
          await _rxCharacteristic!.write(data, withoutResponse: false);
        } else {
          throw Exception('Characteristic does not support write operations');
        }
      }

      _logPacket(data, PacketDirection.tx, responseCode: commandCode);
      _txPacketCount++;
      onTxActivity?.call();

      debugPrint('✅ [TX] Command sent successfully');
    } catch (e) {
      debugPrint('❌ [TX] Write error: $e');
      onError?.call('Write error: $e');
      rethrow;
    }
  }

  /// Log a packet
  void _logPacket(
    Uint8List data,
    PacketDirection direction, {
    int? responseCode,
  }) {
    // Add new packet
    _packetLogs.add(
      BlePacketLog(
        timestamp: DateTime.now(),
        rawData: data,
        direction: direction,
        responseCode: responseCode,
        description: _getPacketDescription(responseCode),
      ),
    );

    // Limit log size to prevent memory issues
    if (_packetLogs.length > _maxLogSize) {
      _packetLogs.removeAt(0);
    }
  }

  /// Get human-readable description of packet
  String? _getPacketDescription(int? code) {
    // TX packets - command codes
    switch (code) {
      case 4: // cmdGetContacts
        return 'Get Contacts';
      case 2: // cmdSendTxtMsg
        return 'Send Text Message';
      case 3: // cmdSendChannelTxtMsg
        return 'Send Channel Message';
      case 39: // cmdSendTelemetryReq
        return 'Request Telemetry';
      case 22: // cmdDeviceQuery
        return 'Device Query';
      case 1: // cmdAppStart
        return 'App Start';
      case 27: // cmdSendStatusReq
        return 'Status Request';
      default:
        return null;
    }
  }

  /// Reset packet counter
  void resetCounter() {
    _txPacketCount = 0;
  }

  /// Clear packet logs
  void clearPacketLogs() {
    _packetLogs.clear();
  }

  /// Send data directly to the device, bypassing the command queue.
  ///
  /// Use this for bulk/streaming operations (e.g. getContacts, syncAllChannels)
  /// where the caller manages response coordination via callbacks rather than
  /// the queue's request→response pattern.
  ///
  /// The caller is responsible for waiting for responses via the appropriate
  /// callbacks on BleResponseHandler.
  Future<void> writeDataDirect(Uint8List data) async {
    if (!_isReady) {
      throw Exception('Not connected');
    }
    await _sendToDevice(data);
  }

  /// Dispose resources
  void dispose() {
    _commandQueue.dispose();
    _rxCharacteristic = null;
    _packetLogs.clear();
  }
}
