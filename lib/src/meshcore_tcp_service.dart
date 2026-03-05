import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'models/contact.dart';
import 'models/ble_packet_log.dart';
import 'ble/ble_command_sender.dart';
import 'ble/ble_response_handler.dart';
import 'protocol/frame_builder.dart';
import 'meshcore_constants.dart';
import 'meshcore_service_base.dart';

/// MeshCore TCP/WiFi Service
///
/// Connects to a MeshCore device's built-in TCP server (port 5000 by default).
/// Uses the same binary framing protocol as the serial interface:
///   App → Device : 0x3C ('<') + uint16-LE length + payload
///   Device → App : 0x3E ('>') + uint16-LE length + payload
///
/// All command methods and callbacks are identical to [MeshCoreBleService]
/// so [ConnectionProvider] can swap between them transparently.
class MeshCoreTcpService extends MeshCoreServiceBase {
  // Keep limits aligned with companion frame/payload constraints.
  static const int _maxContactMessageBytes = 156;
  static const int _maxChannelMessageBytes = 127;

  final String appName;

  Socket? _socket;
  bool _isConnected = false;
  bool _isReconnecting = false;
  int _reconnectionAttempt = 0;
  bool _reconnectionEnabled = true;

  // Current host/port for reconnection
  String? _host;
  int? _port;

  // Buffer for assembling incoming data
  final List<int> _recvBuffer = [];

  // Reconnection timer
  Timer? _reconnectionTimer;

  // Keepalive timer
  Timer? _keepaliveTimer;
  static const Duration _keepaliveInterval = Duration(seconds: 20);

  static const int _maxReconnectionAttempts = 30;
  static const List<int> _reconnectionDelaysMs = [
    2000,
    3000,
    5000,
    10000,
    15000,
    30000,
    30000,
  ];

  // Internal components (reused from BLE layer)
  final BleCommandSender _commandSender = BleCommandSender();
  final BleResponseHandler _responseHandler = BleResponseHandler();

  MeshCoreTcpService({this.appName = 'MeshCore Client'}) {
    _setupCommandSender();
    _setupResponseHandler();
  }

  // ── Getters ────────────────────────────────────────────────────────────────

  @override
  bool get isConnected => _isConnected;

  @override
  bool get isReconnecting => _isReconnecting;

  @override
  int get reconnectionAttempt => _reconnectionAttempt;

  @override
  int get maxReconnectionAttempts => _maxReconnectionAttempts;

  @override
  int get rxPacketCount => _responseHandler.rxPacketCount;

  @override
  int get txPacketCount => _commandSender.txPacketCount;

  @override
  List<BlePacketLog> get packetLogs {
    final all = [
      ..._commandSender.packetLogs,
      ..._responseHandler.packetLogs,
    ];
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return all;
  }

  // ── Internal setup ─────────────────────────────────────────────────────────

  void _setupCommandSender() {
    // Give the command sender a write callback that wraps data in TCP frames.
    _commandSender.setTcpWriteCallback(_tcpWrite);

    _commandSender.onError = (error) => onError?.call(error);
    _commandSender.onTxActivity = () => onTxActivity?.call();
  }

  void _setupResponseHandler() {
    _responseHandler.setCommandQueue(_commandSender.commandQueue);

    _responseHandler.onContactReceived = (c) => onContactReceived?.call(c);
    _responseHandler.onContactsComplete = (cs) => onContactsComplete?.call(cs);
    _responseHandler.onMessageReceived = (m) => onMessageReceived?.call(m);
    _responseHandler.onTelemetryReceived = (pk, lpp) =>
        onTelemetryReceived?.call(pk, lpp);
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
    _responseHandler.onLoginSuccess = (pk, perms, admin, tag) =>
        onLoginSuccess?.call(pk, perms, admin, tag);
    _responseHandler.onLoginFail = (pk) => onLoginFail?.call(pk);
    _responseHandler.onAdvertReceived = (pk) => onAdvertReceived?.call(pk);
    _responseHandler.onPathUpdated = (pk) => onPathUpdated?.call(pk);
    _responseHandler.onMessageSent = (tag, ms, flood, pk) =>
        onMessageSent?.call(tag, ms, flood, pk);
    _responseHandler.onMessageDelivered = (code, rtt) =>
        onMessageDelivered?.call(code, rtt);
    _responseHandler.onMessageEchoDetected = (id, cnt, snr, rssi) =>
        onMessageEchoDetected?.call(id, cnt, snr, rssi);
    _responseHandler.onStatusResponse = (pk, data) =>
        onStatusResponse?.call(pk, data);
    _responseHandler.onBinaryResponse = (pk, tag, data) =>
        onBinaryResponse?.call(pk, tag, data);
    _responseHandler.onBatteryAndStorage = (mv, used, total) =>
        onBatteryAndStorage?.call(mv, used, total);
    _responseHandler.onError = (err, {int? errorCode}) =>
        onError?.call(err, errorCode: errorCode);
    _responseHandler.onContactNotFound = (pk) => onContactNotFound?.call(pk);
    _responseHandler.onChannelInfoReceived = (idx, name, secret, flags) =>
        onChannelInfoReceived?.call(idx, name, secret, flags);
    _responseHandler.onContactDeleted = (pk) => onContactDeleted?.call(pk);
    _responseHandler.onContactsFull = () => onContactsFull?.call();
    _responseHandler.onAllowedRepeatFreqReceived = (ranges) =>
        onAllowedRepeatFreqReceived?.call(ranges);
    _responseHandler.onRawDataReceived = (payload, snr, rssi) =>
        onRawDataReceived?.call(payload, snr, rssi);
    _responseHandler.onRxActivity = () => onRxActivity?.call();
  }

  // ── TCP framing ────────────────────────────────────────────────────────────

  /// Write a framed packet to the socket: 0x3C + uint16-LE length + data.
  Future<void> _tcpWrite(Uint8List data) async {
    if (_socket == null || !_isConnected) {
      throw Exception('TCP not connected');
    }
    final frame = Uint8List(3 + data.length);
    frame[0] = 0x3C; // '<'
    frame[1] = data.length & 0xFF;
    frame[2] = (data.length >> 8) & 0xFF;
    frame.setRange(3, 3 + data.length, data);
    _socket!.add(frame);
  }

  /// Parse incoming bytes and dispatch complete frames to the response handler.
  void _onSocketData(List<int> chunk) {
    _recvBuffer.addAll(chunk);

    while (true) {
      // Need at least the 3-byte header: 0x3E + uint16-LE length
      if (_recvBuffer.length < 3) break;

      if (_recvBuffer[0] != 0x3E) {
        // Out of sync – skip one byte and try again.
        debugPrint('⚠️ [TCP] Unexpected frame byte: 0x${_recvBuffer[0].toRadixString(16)}, re-syncing');
        _recvBuffer.removeAt(0);
        continue;
      }

      final frameLen = _recvBuffer[1] | (_recvBuffer[2] << 8);

      if (_recvBuffer.length < 3 + frameLen) break; // wait for more data

      final payload = _recvBuffer.sublist(3, 3 + frameLen);
      _recvBuffer.removeRange(0, 3 + frameLen);

      _responseHandler.feedData(payload);
    }
  }

  // ── Connection lifecycle ───────────────────────────────────────────────────

  /// Connect to a MeshCore device TCP server.
  Future<bool> connect(String host, int port) async {
    _host = host;
    _port = port;
    _reconnectionEnabled = true;
    _reconnectionAttempt = 0;
    _isReconnecting = false;

    return _doConnect(host, port);
  }

  Future<bool> _doConnect(String host, int port) async {
    try {
      debugPrint('🔌 [TCP] Connecting to $host:$port...');

      _socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));

      _recvBuffer.clear();

      _socket!.listen(
        _onSocketData,
        onError: (error) {
          debugPrint('❌ [TCP] Socket error: $error');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('🔌 [TCP] Socket closed by remote');
          _handleDisconnect();
        },
        cancelOnError: true,
      );

      // Wire command sender to TCP write
      _commandSender.setTcpWriteCallback(_tcpWrite);
      _responseHandler.setCommandQueue(_commandSender.commandQueue);

      _isConnected = true;
      _isReconnecting = false;
      _reconnectionAttempt = 0;

      onConnectionStateChanged?.call(true);
      _startKeepalive();

      await _sendDeviceQuery();

      debugPrint('✅ [TCP] Connected and initialised');
      return true;
    } catch (e) {
      debugPrint('❌ [TCP] Connection failed: $e');
      _isConnected = false;
      onError?.call('TCP connection failed: $e');
      _scheduleReconnect();
      return false;
    }
  }

  void _handleDisconnect() {
    if (!_isConnected) return;
    _isConnected = false;
    _socket?.destroy();
    _socket = null;
    _stopKeepalive();
    onConnectionStateChanged?.call(false);
    if (_reconnectionEnabled) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_reconnectionEnabled) return;
    if (_reconnectionAttempt >= _maxReconnectionAttempts) {
      debugPrint('❌ [TCP] Max reconnection attempts reached');
      _isReconnecting = false;
      return;
    }

    _isReconnecting = true;
    _reconnectionAttempt++;

    final delayIndex = (_reconnectionAttempt - 1)
        .clamp(0, _reconnectionDelaysMs.length - 1);
    final delayMs = _reconnectionDelaysMs[delayIndex];

    debugPrint(
        '🔄 [TCP] Reconnecting in ${delayMs}ms (attempt $_reconnectionAttempt/$_maxReconnectionAttempts)');
    onReconnectionAttempt?.call(_reconnectionAttempt, _maxReconnectionAttempts);

    _reconnectionTimer?.cancel();
    _reconnectionTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!_reconnectionEnabled || _host == null || _port == null) return;
      await _doConnect(_host!, _port!);
    });
  }

  /// Disconnect cleanly.
  Future<void> disconnect() async {
    _reconnectionEnabled = false;
    _reconnectionTimer?.cancel();
    _stopKeepalive();

    _isConnected = false;
    _socket?.destroy();
    _socket = null;

    onConnectionStateChanged?.call(false);
  }

  // ── Device initialisation (same sequence as BLE) ───────────────────────────

  Future<void> _sendDeviceQuery() async {
    final deviceInfo =
        await _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
      FrameBuilder.buildDeviceQuery(),
      MeshCoreConstants.respDeviceInfo,
    );
    debugPrint(
        '✅ [TCP] Device info: firmware=${deviceInfo['firmwareVersion']}');

    await _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
      FrameBuilder.buildAppStart(appName: appName),
      MeshCoreConstants.respSelfInfo,
    );
    debugPrint('✅ [TCP] Self info received');

    await _commandSender.writeData(FrameBuilder.buildSetDeviceTime());
    await syncNextMessage();
  }

  // ── Keepalive ──────────────────────────────────────────────────────────────

  void _startKeepalive() {
    _stopKeepalive();
    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) async {
      if (!_isConnected) {
        _stopKeepalive();
        return;
      }
      try {
        await syncNextMessage();
      } catch (e) {
        debugPrint('⚠️ [TCP] Keepalive error: $e');
      }
    });
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  // ── Commands (delegate to BleCommandSender + FrameBuilder) ─────────────────

  @override
  Future<void> getContacts() =>
      _commandSender.writeData(FrameBuilder.buildGetContacts());

  @override
  Future<void> getContactByKey(Uint8List publicKey) =>
      _commandSender.writeData(FrameBuilder.buildGetContactByKey(publicKey));

  @override
  Future<void> addOrUpdateContact(Contact contact) =>
      _commandSender.writeData(FrameBuilder.buildAddUpdateContact(contact));

  @override
  Future<void> removeContact(Uint8List contactPublicKey) =>
      _commandSender.writeData(FrameBuilder.buildRemoveContact(contactPublicKey));

  @override
  Future<void> resetPath(Uint8List contactPublicKey) =>
      _commandSender.writeData(FrameBuilder.buildResetPath(contactPublicKey));

  @override
  Future<void> sendTextMessage({
    required Uint8List contactPublicKey,
    required String text,
    int textType = 0,
    int attempt = 0,
  }) {
    if (utf8.encode(text).length > _maxContactMessageBytes) {
      throw ArgumentError(
        'Text message exceeds $_maxContactMessageBytes UTF-8 bytes',
      );
    }
    _responseHandler.setLastContactPublicKey(contactPublicKey);
    _responseHandler.queuePendingDirectMessageContact(contactPublicKey);
    return _commandSender
        .writeDataAndWaitForResponse<Map<String, dynamic>>(
          FrameBuilder.buildSendTxtMsg(
            contactPublicKey: contactPublicKey,
            text: text,
            textType: textType,
            attempt: attempt,
          ),
          MeshCoreConstants.respSent,
        )
        .catchError((error) {
          _responseHandler.cancelPendingDirectMessageContact(contactPublicKey);
          throw error;
        });
  }

  @override
  Future<void> sendChannelMessage({
    required int channelIdx,
    required String text,
    int textType = 0,
  }) {
    if (utf8.encode(text).length > _maxChannelMessageBytes) {
      throw ArgumentError(
        'Channel message exceeds $_maxChannelMessageBytes UTF-8 bytes',
      );
    }
    return _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSendChannelTxtMsg(
        channelIdx: channelIdx,
        text: text,
        textType: textType,
      ),
    );
  }

  @override
  void trackSentChannelMessage(
    String messageId, {
    int? channelIdx,
    String? plainText,
  }) {
    _responseHandler.trackSentMessage(messageId, null,
        channelIdx: channelIdx, plainText: plainText);
  }

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
      _commandSender.writeData(FrameBuilder.buildSendSelfAdvert(floodMode: floodMode));

  @override
  Future<void> setAdvertName(String name) =>
      _commandSender.writeDataAndWaitForAck(FrameBuilder.buildSetAdvertName(name));

  @override
  Future<void> setAdvertLatLon({
    required double latitude,
    required double longitude,
  }) =>
      _commandSender.writeData(
        FrameBuilder.buildSetAdvertLatLon(latitude: latitude, longitude: longitude),
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
  Future<void> setTxPower(int powerDbm) =>
      _commandSender.writeDataAndWaitForAck(FrameBuilder.buildSetTxPower(powerDbm));

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
  Future<void> refreshDeviceInfo() => _sendDeviceQuery();

  @override
  Future<void> getBatteryAndStorage() =>
      _commandSender.writeData(FrameBuilder.buildGetBatteryAndStorage());

  @override
  Future<void> loginToRoom({
    required Uint8List roomPublicKey,
    required String password,
  }) {
    if (password.length > 15) throw ArgumentError('Password too long');
    return _commandSender.writeData(
      FrameBuilder.buildSendLogin(
        roomPublicKey: roomPublicKey,
        password: password,
      ),
    );
  }

  @override
  Future<void> sendStatusRequest(Uint8List contactPublicKey) =>
      _commandSender.writeData(FrameBuilder.buildSendStatusReq(contactPublicKey));

  @override
  Future<void> getChannel(int channelIdx) =>
      _commandSender.writeData(FrameBuilder.buildGetChannel(channelIdx));

  @override
  Future<void> setChannel({
    required int channelIdx,
    required String channelName,
    required List<int> secret,
  }) async {
    await _commandSender.writeData(
      FrameBuilder.buildSetChannel(
        channelIdx: channelIdx,
        channelName: channelName,
        secret: secret,
      ),
    );
    await Future.delayed(const Duration(milliseconds: 200));
    await getChannel(channelIdx);
  }

  @override
  Future<void> deleteChannel(int channelIdx) async {
    if (channelIdx == 0) throw ArgumentError('Cannot delete channel 0');
    await setChannel(
      channelIdx: channelIdx,
      channelName: '',
      secret: List.filled(16, 0),
    );
  }

  @override
  Future<void> syncAllChannels({int maxChannels = 40}) async {
    for (int i = 1; i < maxChannels; i++) {
      await getChannel(i);
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

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
  void dispose() {
    _reconnectionEnabled = false;
    _reconnectionTimer?.cancel();
    _stopKeepalive();
    _socket?.destroy();
    _socket = null;
    _commandSender.dispose();
    _responseHandler.dispose();
  }
}
