import 'dart:async';
import 'package:flutter/foundation.dart';
import 'models/contact.dart';
import 'models/ble_packet_log.dart';
import 'models/spectrum_scan.dart';
import 'ble/ble_command_sender.dart';
import 'ble/ble_response_handler.dart';
import 'protocol/frame_builder.dart';
import 'meshcore_constants.dart';
import 'meshcore_service_base.dart';

/// MeshCore Serial/USB Service
///
/// Uses the same framing as TCP:
///   App → Device : 0x3C ('<') + uint16-LE length + payload
///   Device → App : 0x3E ('>') + uint16-LE length + payload
///
/// Transport-agnostic: provide [writeRaw] and feed data via [feedRawBytes].
/// Works with Android USB OTG (usb_serial) and Web Serial API.
class MeshCoreSerialService extends MeshCoreServiceBase {
  static const int _maxContactMessageBytes = 150;

  final String appName;

  final BleCommandSender _commandSender = BleCommandSender();
  final BleResponseHandler _responseHandler = BleResponseHandler();
  final List<int> _recvBuffer = [];

  bool _isConnected = false;

  /// Raw write function — set by the platform transport.
  Future<void> Function(Uint8List bytes)? writeRaw;

  // Callbacks wired in constructor
  MeshCoreSerialService({this.appName = 'MeshCore Client'}) {
    _setupCallbacks();
  }

  void _setupCallbacks() {
    _commandSender.onError = (error) => onError?.call(error);
    _commandSender.onTxActivity = () => onTxActivity?.call();

    _responseHandler.onContactReceived = (c) => onContactReceived?.call(c);
    _responseHandler.onContactsComplete = (c) => onContactsComplete?.call(c);
    _responseHandler.onMessageReceived = (m) => onMessageReceived?.call(m);
    _responseHandler.onTelemetryReceived = (k, d) =>
        onTelemetryReceived?.call(k, d);
    _responseHandler.onSelfInfoReceived = (info) {
      if (info['publicKey'] != null) {
        final pk = info['publicKey'] as Uint8List;
        if (pk.isNotEmpty) _responseHandler.setOurNodeHash(pk[0]);
      }
      onSelfInfoReceived?.call(info);
    };
    _responseHandler.onDeviceInfoReceived = (info) =>
        onDeviceInfoReceived?.call(info);
    _responseHandler.onNoMoreMessages = () => onNoMoreMessages?.call();
    _responseHandler.onMessageWaiting = () => onMessageWaiting?.call();
    _responseHandler.onLoginSuccess = (pk, p, a, t) =>
        onLoginSuccess?.call(pk, p, a, t);
    _responseHandler.onLoginFail = (pk) => onLoginFail?.call(pk);
    _responseHandler.onAdvertReceived = (pk) => onAdvertReceived?.call(pk);
    _responseHandler.onPathUpdated = (pk) => onPathUpdated?.call(pk);
    _responseHandler.onMessageSent = (tag, timeout, flood, pk) =>
        onMessageSent?.call(tag, timeout, flood, pk);
    _responseHandler.onMessageDelivered = (code, rtt) =>
        onMessageDelivered?.call(code, rtt);
    _responseHandler.onMessageEchoDetected = (id, count, snr, rssi) =>
        onMessageEchoDetected?.call(id, count, snr, rssi);
    _responseHandler.onStatusResponse = (pk, data) =>
        onStatusResponse?.call(pk, data);
    _responseHandler.onBinaryResponse = (pk, tag, data) =>
        onBinaryResponse?.call(pk, tag, data);
    _responseHandler.onControlDataReceived = (p, s, r, l) =>
        onControlDataReceived?.call(p, s, r, l);
    _responseHandler.onBatteryAndStorage = (mv, u, t) =>
        onBatteryAndStorage?.call(mv, u, t);
    _responseHandler.onError = (e, {int? errorCode}) =>
        onError?.call(e, errorCode: errorCode);
    _responseHandler.onContactNotFound = (pk) => onContactNotFound?.call(pk);
    _responseHandler.onChannelInfoReceived = (i, n, s, f) =>
        onChannelInfoReceived?.call(i, n, s, f);
    _responseHandler.onContactDeleted = (pk) => onContactDeleted?.call(pk);
    _responseHandler.onContactsFull = () => onContactsFull?.call();
    _responseHandler.onAllowedRepeatFreqReceived = (r) =>
        onAllowedRepeatFreqReceived?.call(r);
    _responseHandler.onAutoaddConfigReceived = (c) =>
        onAutoaddConfigReceived?.call(c);
    _responseHandler.onRawDataReceived = (p, s, r) =>
        onRawDataReceived?.call(p, s, r);
    _responseHandler.onRxActivity = () => onRxActivity?.call();
  }

  // ── Framing ──────────────────────────────────────────────────────────────

  /// Write a framed packet: 0x3C + uint16-LE length + payload.
  Future<void> _serialWrite(Uint8List data) async {
    if (writeRaw == null || !_isConnected) {
      throw Exception('Serial not connected');
    }
    final frame = Uint8List(3 + data.length);
    frame[0] = 0x3C; // '<'
    frame[1] = data.length & 0xFF;
    frame[2] = (data.length >> 8) & 0xFF;
    frame.setRange(3, 3 + data.length, data);
    await writeRaw!(frame);
  }

  /// Feed raw bytes from the serial port. Call this from the platform transport
  /// whenever data arrives.
  void feedRawBytes(List<int> chunk) {
    _recvBuffer.addAll(chunk);

    while (true) {
      if (_recvBuffer.length < 3) break;

      if (_recvBuffer[0] != 0x3E) {
        debugPrint(
          '⚠️ [Serial] Unexpected frame byte: 0x${_recvBuffer[0].toRadixString(16)}, re-syncing',
        );
        _recvBuffer.removeAt(0);
        continue;
      }

      final frameLen = _recvBuffer[1] | (_recvBuffer[2] << 8);
      if (_recvBuffer.length < 3 + frameLen) break;

      final payload = _recvBuffer.sublist(3, 3 + frameLen);
      _recvBuffer.removeRange(0, 3 + frameLen);

      _responseHandler.feedData(payload);
    }
  }

  // ── Connection lifecycle ──────────────────────────────────────────────────

  /// Mark the serial port as connected and initialize the session.
  ///
  /// Call this after the platform transport has opened the port.
  Future<bool> markConnected() async {
    _isConnected = true;
    _recvBuffer.clear();

    _commandSender.setTcpWriteCallback(_serialWrite);
    _responseHandler.setCommandQueue(_commandSender.commandQueue);

    try {
      await _initializeSession();
      onConnectionStateChanged?.call(true);
      return true;
    } catch (e) {
      debugPrint('❌ [Serial] Session init failed: $e');
      markDisconnected();
      onError?.call('Serial initialization failed: $e');
      return false;
    }
  }

  /// Mark the serial port as disconnected.
  void markDisconnected() {
    _isConnected = false;
    _recvBuffer.clear();
    onConnectionStateChanged?.call(false);
  }

  Future<void> _initializeSession() async {
    // Device query
    await _commandSender.writeData(FrameBuilder.buildDeviceQuery());
    // Small delay for response
    await Future.delayed(const Duration(milliseconds: 300));
    // App start
    await _commandSender.writeData(
      FrameBuilder.buildAppStart(appName: appName),
    );
    await Future.delayed(const Duration(milliseconds: 300));
    // Set clock
    await _commandSender.writeData(FrameBuilder.buildSetDeviceTime());
  }

  // ── State ──────────────────────────────────────────────────────────────────

  @override
  bool get isConnected => _isConnected;
  @override
  bool get isReconnecting => false;
  @override
  int get reconnectionAttempt => 0;
  @override
  int get maxReconnectionAttempts => 0;
  @override
  int get rxPacketCount => _responseHandler.rxPacketCount;
  @override
  int get txPacketCount => _commandSender.txPacketCount;
  @override
  bool get isSpectrumScanActive => false;
  @override
  List<BlePacketLog> get packetLogs {
    final all = [
      ..._commandSender.packetLogs,
      ..._responseHandler.packetLogs,
    ];
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return all;
  }

  // ── Commands (delegate to BleCommandSender + FrameBuilder) ─────────────

  @override
  Future<void> getContacts() =>
      _commandSender.writeData(FrameBuilder.buildGetContacts());

  @override
  Future<void> getContactByKey(Uint8List publicKey) {
    _responseHandler.setLastLookupContactPublicKey(publicKey);
    return _commandSender.writeDataAndWaitForResponse<Contact>(
      FrameBuilder.buildGetContactByKey(publicKey),
      MeshCoreConstants.respContact,
    );
  }

  @override
  Future<void> importContact(Uint8List contactAdvertFrame) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildImportContact(contactAdvertFrame),
      );

  @override
  Future<void> importReceivedAdvert(Uint8List publicKey) =>
      _commandSender.writeDataAndWaitForResponse<void>(
        FrameBuilder.buildGetAdvertPath(publicKey),
        MeshCoreConstants.respAdvertPath,
        timeout: const Duration(seconds: 5),
      );

  @override
  Future<void> addOrUpdateContact(Contact contact) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildAddUpdateContact(contact),
      );

  @override
  Future<void> sendTextMessage({
    required Uint8List contactPublicKey,
    required String text,
    int textType = 0,
    int attempt = 0,
  }) async {
    if (text.length > _maxContactMessageBytes) {
      throw ArgumentError('Text exceeds $_maxContactMessageBytes bytes');
    }
    _responseHandler.setLastContactPublicKey(contactPublicKey);
    _responseHandler.queuePendingDirectMessageContact(contactPublicKey);
    try {
      await _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
        FrameBuilder.buildSendTxtMsg(
          contactPublicKey: contactPublicKey,
          text: text,
          textType: textType,
          attempt: attempt,
        ),
        MeshCoreConstants.respSent,
      );
    } catch (_) {
      _responseHandler.cancelPendingDirectMessageContact(contactPublicKey);
      rethrow;
    }
  }

  @override
  Future<void> sendChannelMessage({
    required int channelIdx,
    required String text,
    int textType = 0,
  }) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSendChannelTxtMsg(
          channelIdx: channelIdx,
          text: text,
          textType: textType,
        ),
      );

  @override
  void trackSentChannelMessage(
    String messageId, {
    int? channelIdx,
    String? plainText,
  }) =>
      _responseHandler.trackSentMessage(
        messageId,
        null,
        channelIdx: channelIdx,
        plainText: plainText,
      );

  @override
  Future<void> requestTelemetry(
    Uint8List contactPublicKey, {
    bool zeroHop = false,
  }) =>
      _commandSender.writeData(
        FrameBuilder.buildSendTelemetryReq(contactPublicKey, zeroHop: zeroHop),
      );

  @override
  Future<void> sendBinaryRequest({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  }) =>
      _commandSender.writeData(
        FrameBuilder.buildSendBinaryReq(
          contactPublicKey: contactPublicKey,
          requestData: requestData,
        ),
      );

  @override
  Future<void> sendControlData(Uint8List payload) =>
      _commandSender.writeData(FrameBuilder.buildSendControlData(payload));

  @override
  Future<void> sendRawVoicePacket({
    required int contactPathLen,
    required Uint8List contactPath,
    required Uint8List payload,
  }) =>
      _commandSender.writeData(
        FrameBuilder.buildSendRawData(
          pathLen: contactPathLen,
          path: contactPath,
          payload: payload,
        ),
      );

  @override
  Future<void> syncNextMessage() =>
      _commandSender.writeData(FrameBuilder.buildSyncNextMessage());

  @override
  Future<void> getDeviceTime() =>
      _commandSender.writeData(FrameBuilder.buildGetDeviceTime());

  @override
  Future<void> setDeviceTime() =>
      _commandSender.writeData(FrameBuilder.buildSetDeviceTime());

  @override
  Future<void> sendSelfAdvert({bool floodMode = true}) =>
      _commandSender.writeData(
        FrameBuilder.buildSendSelfAdvert(floodMode: floodMode),
      );

  @override
  Future<void> setAdvertName(String name) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetAdvertName(name),
      );

  @override
  Future<void> setAdvertLatLon({
    required double latitude,
    required double longitude,
  }) =>
      _commandSender.writeData(
        FrameBuilder.buildSetAdvertLatLon(
          latitude: latitude,
          longitude: longitude,
        ),
      );

  @override
  Future<void> setRadioParams({
    required int frequency,
    required int bandwidth,
    required int spreadingFactor,
    required int codingRate,
    bool? repeat,
  }) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetRadioParams(
          frequency: frequency,
          bandwidth: bandwidth,
          spreadingFactor: spreadingFactor,
          codingRate: codingRate,
          repeat: repeat == null ? null : (repeat ? 1 : 0),
        ),
      );

  @override
  Future<void> getAllowedRepeatFreq() =>
      _commandSender.writeData(FrameBuilder.buildGetAllowedRepeatFreq());

  @override
  Future<SpectrumScanResult> scanSpectrum({
    required int startFrequencyKhz,
    required int stopFrequencyKhz,
    required int bandwidthKhz,
    required int stepKhz,
    required int dwellMs,
    required int thresholdDb,
  }) =>
      throw UnsupportedError('Spectrum scan not supported over serial');

  @override
  Future<void> setTxPower(int powerDbm) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetTxPower(powerDbm),
      );

  @override
  Future<void> setOtherParams({
    required int manualAddContacts,
    required int telemetryModes,
    required int advertLocationPolicy,
    int multiAcks = 0,
  }) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetOtherParams(
          manualAddContacts: manualAddContacts,
          telemetryModes: telemetryModes,
          advertLocationPolicy: advertLocationPolicy,
          multiAcks: multiAcks,
        ),
      );

  @override
  Future<Map<String, dynamic>> getAutoaddConfig() =>
      _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
        FrameBuilder.buildGetAutoaddConfig(),
        MeshCoreConstants.respAutoaddConfig,
      );

  @override
  Future<void> setAutoaddConfig({
    required bool autoAddUsers,
    required bool autoAddRepeaters,
    required bool autoAddRoomServers,
    required bool autoAddSensors,
    required bool overwriteOldest,
  }) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetAutoaddConfig(
          autoAddUsers: autoAddUsers,
          autoAddRepeaters: autoAddRepeaters,
          autoAddRoomServers: autoAddRoomServers,
          autoAddSensors: autoAddSensors,
          overwriteOldest: overwriteOldest,
        ),
      );

  @override
  Future<void> refreshDeviceInfo() async {
    await _commandSender.writeData(FrameBuilder.buildDeviceQuery());
    await _commandSender.writeData(
      FrameBuilder.buildAppStart(appName: appName),
    );
    await _commandSender.writeData(FrameBuilder.buildSetDeviceTime());
  }

  @override
  Future<void> getBatteryAndStorage() =>
      _commandSender.writeData(FrameBuilder.buildGetBatteryAndStorage());

  @override
  Future<void> loginToRoom({
    required Uint8List roomPublicKey,
    required String password,
  }) =>
      _commandSender.writeData(
        FrameBuilder.buildSendLogin(
          roomPublicKey: roomPublicKey,
          password: password,
        ),
      );

  @override
  Future<void> sendStatusRequest(Uint8List contactPublicKey) =>
      _commandSender.writeData(
        FrameBuilder.buildSendStatusReq(contactPublicKey),
      );

  @override
  Future<({int tag, int suggestedTimeoutMs})> sendAnonRequest({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  }) async {
    final result = await _commandSender
        .writeDataAndWaitForResponse<Map<String, dynamic>>(
          FrameBuilder.buildSendAnonReq(
            contactPublicKey: contactPublicKey,
            requestData: requestData,
          ),
          MeshCoreConstants.respSent,
        );
    return (
      tag: result['expectedAckTag'] as int,
      suggestedTimeoutMs: result['suggestedTimeout'] as int,
    );
  }

  @override
  Future<void> resetPath(Uint8List contactPublicKey) =>
      _commandSender.writeData(
        FrameBuilder.buildResetPath(contactPublicKey),
      );

  @override
  Future<void> factoryReset() =>
      _commandSender.writeData(FrameBuilder.buildFactoryReset());

  @override
  Future<void> removeContact(Uint8List contactPublicKey) =>
      _commandSender.writeData(
        FrameBuilder.buildRemoveContact(contactPublicKey),
      );

  @override
  Future<void> getChannel(int channelIdx) =>
      _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
        FrameBuilder.buildGetChannel(channelIdx),
        MeshCoreConstants.respChannelInfo,
      );

  @override
  Future<void> setChannel({
    required int channelIdx,
    required String channelName,
    required List<int> secret,
  }) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetChannel(
          channelIdx: channelIdx,
          channelName: channelName,
          secret: secret,
        ),
      );

  @override
  Future<void> deleteChannel(int channelIdx) => setChannel(
    channelIdx: channelIdx,
    channelName: '',
    secret: List.filled(16, 0),
  );

  @override
  Future<void> syncAllChannels({int maxChannels = 40}) async {
    for (int i = 1; i < maxChannels; i++) {
      await getChannel(i);
    }
  }

  @override
  Future<Uint8List> exportContact(Uint8List? publicKey) =>
      _commandSender.writeDataAndWaitForResponse<Uint8List>(
        FrameBuilder.buildExportContact(publicKey),
        MeshCoreConstants.respExportContact,
      );

  @override
  Future<Map<String, String>> getCustomVars() =>
      _commandSender.writeDataAndWaitForResponse<Map<String, String>>(
        FrameBuilder.buildGetCustomVars(),
        MeshCoreConstants.respCustomVars,
      );

  @override
  Future<void> setCustomVar(String key, String value) =>
      _commandSender.writeDataAndWaitForAck(
        FrameBuilder.buildSetCustomVar(key, value),
      );

  @override
  void clearPacketLogs() {
    _commandSender.clearPacketLogs();
    _responseHandler.clearPacketLogs();
  }

  @override
  void resetCounters() {
    _commandSender.resetCounter();
    _responseHandler.resetCounter();
  }

  @override
  void setSpectrumScanActive(bool active) {}

  @override
  void dispose() {
    _commandSender.dispose();
    _responseHandler.dispose();
  }
}
