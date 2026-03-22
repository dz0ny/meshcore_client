import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'models/contact.dart';
import 'models/message.dart';
import 'models/ble_packet_log.dart';
import 'ble/ble_connection_manager.dart';
import 'ble/ble_command_sender.dart';
import 'ble/ble_response_handler.dart';
import 'protocol/frame_builder.dart';
import 'meshcore_constants.dart';
import 'meshcore_service_base.dart';

/// Callback types for MeshCore events
typedef OnContactCallback = void Function(Contact contact);
typedef OnContactsCompleteCallback = void Function(List<Contact> contacts);
typedef OnMessageCallback = void Function(Message message);
typedef OnTelemetryCallback =
    void Function(Uint8List publicKey, Uint8List lppData);
typedef OnSelfInfoCallback = void Function(Map<String, dynamic> selfInfo);
typedef OnDeviceInfoCallback = void Function(Map<String, dynamic> deviceInfo);
typedef OnNoMoreMessagesCallback = void Function();
typedef OnMessageWaitingCallback = void Function();
typedef OnLoginSuccessCallback =
    void Function(
      Uint8List publicKeyPrefix,
      int permissions,
      bool isAdmin,
      int tag,
    );
typedef OnLoginFailCallback = void Function(Uint8List publicKeyPrefix);
typedef OnAdvertReceivedCallback = void Function(Uint8List publicKey);
typedef OnPathUpdatedCallback = void Function(Uint8List publicKey);
typedef OnMessageSentCallback =
    void Function(
      int expectedAckTag,
      int suggestedTimeoutMs,
      bool isFloodMode,
      Uint8List? contactPublicKey,
    );
typedef OnMessageDeliveredCallback =
    void Function(int ackCode, int roundTripTimeMs);
typedef OnMessageEchoDetectedCallback =
    void Function(String messageId, int echoCount, int snrRaw, int rssiDbm);
typedef OnStatusResponseCallback =
    void Function(Uint8List publicKeyPrefix, Uint8List statusData);
typedef OnBinaryResponseCallback =
    void Function(Uint8List publicKeyPrefix, int tag, Uint8List responseData);
typedef OnControlDataCallback =
    void Function(Uint8List payload, int snrRaw, int rssiDbm, int pathLen);
typedef OnBatteryAndStorageCallback =
    void Function(int millivolts, int? usedKb, int? totalKb);
typedef OnErrorCallback = void Function(String error, {int? errorCode});
typedef OnContactNotFoundCallback = void Function(Uint8List? contactPublicKey);
typedef OnAllowedRepeatFreqCallback =
    void Function(List<({int lower, int upper})> ranges);
typedef OnChannelInfoCallback =
    void Function(
      int channelIdx,
      String channelName,
      Uint8List secret,
      int? flags,
    );
typedef OnConnectionStateCallback = void Function(bool isConnected);
typedef OnReconnectionAttemptCallback =
    void Function(int attemptNumber, int maxAttempts);
typedef OnRssiUpdateCallback = void Function(int rssi);

/// MeshCore BLE Service - coordinates BLE communication components
class MeshCoreBleService extends MeshCoreServiceBase {
  // Keep limits aligned with companion frame/payload constraints.
  static const int _maxContactMessageBytes = 150;
  static const int _maxChannelMessageBytes = 160;

  /// App name reported to the device during handshake (CMD_APP_START).
  /// Override with your application's name so the device can identify it.
  final String appName;

  // Component instances
  final BleConnectionManager _connectionManager = BleConnectionManager();
  final BleCommandSender _commandSender = BleCommandSender();
  final BleResponseHandler _responseHandler = BleResponseHandler();

  // Keepalive timer for iOS background mode
  Timer? _keepaliveTimer;
  static const Duration _keepaliveInterval = Duration(seconds: 20);
  bool _isSessionReady = false;
  bool _isBurstSyncActive = false;
  Completer<Map<String, dynamic>>? _pendingDeviceInfoCompleter;
  Completer<Map<String, dynamic>>? _pendingSelfInfoCompleter;

  // Event callbacks
  OnConnectionStateCallback? onConnectionStateChanged;
  OnReconnectionAttemptCallback? onReconnectionAttempt;
  OnRssiUpdateCallback? onRssiUpdate;
  OnContactCallback? onContactReceived;
  OnContactsCompleteCallback? onContactsComplete;
  OnMessageCallback? onMessageReceived;
  OnTelemetryCallback? onTelemetryReceived;
  OnSelfInfoCallback? onSelfInfoReceived;
  OnDeviceInfoCallback? onDeviceInfoReceived;
  OnNoMoreMessagesCallback? onNoMoreMessages;
  OnMessageWaitingCallback? onMessageWaiting;
  OnLoginSuccessCallback? onLoginSuccess;
  OnLoginFailCallback? onLoginFail;
  OnAdvertReceivedCallback? onAdvertReceived;
  OnPathUpdatedCallback? onPathUpdated;
  OnMessageSentCallback? onMessageSent;
  OnMessageDeliveredCallback? onMessageDelivered;
  OnMessageEchoDetectedCallback? onMessageEchoDetected;
  OnStatusResponseCallback? onStatusResponse;
  OnBinaryResponseCallback? onBinaryResponse;
  OnControlDataCallback? onControlDataReceived;
  OnBatteryAndStorageCallback? onBatteryAndStorage;
  OnErrorCallback? onError;
  OnContactNotFoundCallback? onContactNotFound;
  OnChannelInfoCallback? onChannelInfoReceived;
  OnAllowedRepeatFreqCallback? onAllowedRepeatFreqReceived;
  void Function(Uint8List publicKey)? onContactDeleted;
  VoidCallback? onContactsFull;
  OnRawDataReceivedCallback? onRawDataReceived;
  OnChannelDataReceivedCallback? onChannelDataReceived;

  // Activity callbacks (for blinking indicators)
  VoidCallback? onRxActivity;
  VoidCallback? onTxActivity;

  // Constructor
  MeshCoreBleService({this.appName = 'MeshCore Client'}) {
    _setupCallbacks();
  }

  // Setup callbacks between components
  void _setupCallbacks() {
    // Connection manager callbacks
    _connectionManager.onConnectionStateChanged = (isConnected) {
      if (!isConnected) {
        _isSessionReady = false;
        _pendingDeviceInfoCompleter = null;
        _pendingSelfInfoCompleter = null;
        _stopKeepalive();
      } else if (_isSessionReady) {
        _startKeepalive();
      }
      onConnectionStateChanged?.call(isConnected);
    };
    _connectionManager.onError = (error) {
      onError?.call(error);
    };
    _connectionManager.onReconnectionAttempt = (attemptNumber, maxAttempts) {
      debugPrint(
        '🔄 [Service] Reconnection attempt $attemptNumber/$maxAttempts',
      );
      onReconnectionAttempt?.call(attemptNumber, maxAttempts);
    };
    _connectionManager.onRssiUpdate = (rssi) {
      onRssiUpdate?.call(rssi);
    };

    // Command sender callbacks
    _commandSender.onError = (error) {
      onError?.call(error);
    };
    _commandSender.onTxActivity = () {
      onTxActivity?.call();
    };

    // Response handler callbacks
    _responseHandler.onContactReceived = (contact) {
      debugPrint(
        '🔔 [BleService] onContactReceived - "${contact.advName}" - forwarding to ConnectionProvider',
      );
      onContactReceived?.call(contact);
    };
    _responseHandler.onContactsComplete = (contacts) {
      debugPrint(
        '🔔 [BleService] onContactsComplete - ${contacts.length} contacts - forwarding to ConnectionProvider',
      );
      onContactsComplete?.call(contacts);
    };
    _responseHandler.onMessageReceived = (message) {
      debugPrint(
        '🔔 [BleService] onMessageReceived - forwarding to ConnectionProvider',
      );
      onMessageReceived?.call(message);
    };
    _responseHandler.onTelemetryReceived = (publicKey, lppData) {
      debugPrint(
        '🔔 [BleService] onTelemetryReceived - ${lppData.length} bytes - forwarding to ConnectionProvider',
      );
      onTelemetryReceived?.call(publicKey, lppData);
    };
    _responseHandler.onSelfInfoReceived = (selfInfo) {
      // Extract our node hash (first byte of public key) for echo detection
      if (selfInfo['publicKey'] != null) {
        final publicKey = selfInfo['publicKey'] as Uint8List;
        if (publicKey.isNotEmpty) {
          _responseHandler.setOurNodeHash(publicKey[0]);
        }
      }
      final completer = _pendingSelfInfoCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(selfInfo);
      }
      onSelfInfoReceived?.call(selfInfo);
    };
    _responseHandler.onDeviceInfoReceived = (deviceInfo) {
      final completer = _pendingDeviceInfoCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(deviceInfo);
      }
      onDeviceInfoReceived?.call(deviceInfo);
    };
    _responseHandler.onNoMoreMessages = () {
      onNoMoreMessages?.call();
    };
    _responseHandler.onMessageWaiting = () {
      onMessageWaiting?.call();
    };
    _responseHandler.onLoginSuccess =
        (publicKeyPrefix, permissions, isAdmin, tag) {
          onLoginSuccess?.call(publicKeyPrefix, permissions, isAdmin, tag);
        };
    _responseHandler.onLoginFail = (publicKeyPrefix) {
      onLoginFail?.call(publicKeyPrefix);
    };
    _responseHandler.onAdvertReceived = (publicKey) {
      debugPrint(
        '🔔 [BleService] onAdvertReceived - forwarding to ConnectionProvider',
      );
      onAdvertReceived?.call(publicKey);
    };
    _responseHandler.onPathUpdated = (publicKey) {
      debugPrint(
        '🔔 [BleService] onPathUpdated - forwarding to ConnectionProvider',
      );
      onPathUpdated?.call(publicKey);
    };
    _responseHandler.onMessageSent =
        (expectedAckTag, suggestedTimeoutMs, isFloodMode, contactPublicKey) {
          onMessageSent?.call(
            expectedAckTag,
            suggestedTimeoutMs,
            isFloodMode,
            contactPublicKey,
          );
        };
    _responseHandler.onMessageDelivered = (ackCode, roundTripTimeMs) {
      onMessageDelivered?.call(ackCode, roundTripTimeMs);
    };
    _responseHandler.onMessageEchoDetected =
        (messageId, echoCount, snrRaw, rssiDbm) {
          onMessageEchoDetected?.call(messageId, echoCount, snrRaw, rssiDbm);
        };
    _responseHandler.onStatusResponse = (publicKeyPrefix, statusData) {
      onStatusResponse?.call(publicKeyPrefix, statusData);
    };
    _responseHandler.onBinaryResponse = (publicKeyPrefix, tag, responseData) {
      onBinaryResponse?.call(publicKeyPrefix, tag, responseData);
    };
    _responseHandler.onControlDataReceived =
        (payload, snrRaw, rssiDbm, pathLen) {
          onControlDataReceived?.call(payload, snrRaw, rssiDbm, pathLen);
        };
    _responseHandler.onBatteryAndStorage = (millivolts, usedKb, totalKb) {
      onBatteryAndStorage?.call(millivolts, usedKb, totalKb);
    };
    _responseHandler.onError = (error, {int? errorCode}) {
      onError?.call(error, errorCode: errorCode);
    };
    _responseHandler.onContactNotFound = (contactPublicKey) {
      onContactNotFound?.call(contactPublicKey);
    };
    _responseHandler.onChannelInfoReceived =
        (int channelIdx, String channelName, Uint8List secret, int? flags) {
          onChannelInfoReceived?.call(channelIdx, channelName, secret, flags);
        };
    _responseHandler.onContactDeleted = (publicKey) {
      onContactDeleted?.call(publicKey);
    };
    _responseHandler.onContactsFull = () {
      onContactsFull?.call();
    };
    _responseHandler.onAllowedRepeatFreqReceived = (ranges) {
      onAllowedRepeatFreqReceived?.call(ranges);
    };
    _responseHandler.onAutoaddConfigReceived = (config) {
      onAutoaddConfigReceived?.call(config);
    };
    _responseHandler.onRawDataReceived = (payload, snrRaw, rssiDbm) {
      onRawDataReceived?.call(payload, snrRaw, rssiDbm);
    };
    _responseHandler.onChannelDataReceived =
        (channelIdx, pathLen, dataType, payload, snrRaw, rssiDbm) {
          onChannelDataReceived?.call(
            channelIdx,
            pathLen,
            dataType,
            payload,
            snrRaw,
            rssiDbm,
          );
        };
    _responseHandler.onRxActivity = () {
      onRxActivity?.call();
    };
  }

  // Getters
  bool get isConnected => _connectionManager.isConnected;
  bool get isReconnecting => _connectionManager.isReconnecting;
  int get reconnectionAttempt => _connectionManager.reconnectionAttempt;
  int get maxReconnectionAttempts => _connectionManager.maxReconnectionAttempts;
  int get rxPacketCount => _responseHandler.rxPacketCount;
  int get txPacketCount => _commandSender.txPacketCount;
  List<BlePacketLog> get packetLogs {
    // Merge logs from both sender and handler
    final allLogs = [
      ..._commandSender.packetLogs,
      ..._responseHandler.packetLogs,
    ];
    allLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return allLogs;
  }

  /// Scan for MeshCore devices
  Stream<ScanResult> scanForDevices({
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _connectionManager.scanForDevices(timeout: timeout);
  }

  /// Connect to a MeshCore device
  Future<bool> connect(BluetoothDevice device) async {
    _isSessionReady = false;
    _pendingDeviceInfoCompleter = null;
    _pendingSelfInfoCompleter = null;
    final success = await _connectionManager.connect(device);
    if (success) {
      try {
        // Setup command sender with RX characteristic
        _commandSender.setRxCharacteristic(_connectionManager.rxCharacteristic);

        // Wire up command queue between sender and response handler
        _responseHandler.setCommandQueue(_commandSender.commandQueue);

        // Setup response handler with TX characteristic
        if (_connectionManager.txCharacteristic != null) {
          _responseHandler.subscribeToNotifications(
            _connectionManager.txCharacteristic!,
          );
        }

        // Bootstrap the MeshCore app session after BLE transport is ready.
        await _initializeSession();

        _isSessionReady = true;
        _startKeepalive();
        debugPrint('✅ [Service] Device initialization complete');
        return true;
      } catch (e) {
        debugPrint('❌ [Service] Device initialization failed: $e');
        _isSessionReady = false;
        // Disconnect on initialization failure
        await disconnect();
        onError?.call('Device initialization failed: $e');
        return false;
      }
    }
    return success;
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    _isSessionReady = false;
    _pendingDeviceInfoCompleter = null;
    _pendingSelfInfoCompleter = null;
    await _connectionManager.disconnect();
  }

  Future<void> _initializeSession() async {
    await _requestDeviceInfoWithRetry();
    await _requestSelfInfoWithRetry();

    debugPrint('⏰ [Service] Setting device clock (CMD_SET_DEVICE_TIME)...');
    await _commandSender.writeData(FrameBuilder.buildSetDeviceTime());
    debugPrint('✅ [Service] Device clock sent (no ACK expected)');
  }

  Future<void> _requestDeviceInfoWithRetry() async {
    debugPrint(
      '🔍 [Service] Querying device information (CMD_DEVICE_QUERY)...',
    );
    final deviceInfo = await _sendAndAwaitDeviceInfo();
    debugPrint(
      '✅ [Service] Device info received: firmware=${deviceInfo['firmwareVersion']}',
    );
  }

  Future<void> _requestSelfInfoWithRetry() async {
    debugPrint('🚀 [Service] Sending app start (CMD_APP_START)...');
    await _sendAndAwaitSelfInfo();
    debugPrint('✅ [Service] Self info received: node initialized');
  }

  /// Refresh device info (public method)
  Future<void> refreshDeviceInfo() async {
    await _initializeSession();
  }

  /// Get contacts from device.
  ///
  /// Bypasses the command queue so the device can burst-stream all contacts
  /// without queue serialization overhead.  Individual contacts arrive via
  /// [onContactReceived]; the full list arrives via [onContactsComplete].
  @override
  Future<void> getContacts() async {
    _isBurstSyncActive = true;
    final completer = Completer<void>();
    final prevCallback = _responseHandler.onContactsComplete;

    void finish() {
      _isBurstSyncActive = false;
      _responseHandler.onContactsComplete = prevCallback;
      if (!completer.isCompleted) completer.complete();
    }

    _responseHandler.onContactsComplete = (contacts) {
      finish();
      prevCallback?.call(contacts);
    };

    await _commandSender.writeDataDirect(FrameBuilder.buildGetContacts());

    // Wait for endOfContacts, with a generous timeout
    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        finish();
        debugPrint('⚠️ [Service] getContacts timed out after 15s');
      },
    );
  }

  /// Get a single contact by public key from device
  ///
  /// This is more efficient than getContacts() when you only need to refresh
  /// one specific contact (e.g., after receiving an advertisement).
  ///
  /// The contact will be delivered via the onContactReceived callback.
  Future<void> getContactByKey(Uint8List publicKey) async {
    // Wait for any burst sync to finish to avoid response misrouting
    while (_isBurstSyncActive) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    debugPrint('🔍 [BLE] Requesting single contact by key:');
    debugPrint(
      '    Public key prefix: ${publicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}...',
    );
    _responseHandler.setLastLookupContactPublicKey(publicKey);
    await _commandSender.writeDataAndWaitForResponse<Contact>(
      FrameBuilder.buildGetContactByKey(publicKey),
      MeshCoreConstants.respContact,
    );
  }

  @override
  Future<void> importReceivedAdvert(Uint8List publicKey) async {
    await _commandSender.writeDataAndWaitForResponse<void>(
      FrameBuilder.buildGetAdvertPath(publicKey),
      MeshCoreConstants.respAdvertPath,
      timeout: const Duration(seconds: 5),
    );
  }

  @override
  Future<void> importContact(Uint8List contactAdvertFrame) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildImportContact(contactAdvertFrame),
    );
  }

  /// Manually add or update a contact on the companion radio
  Future<void> addOrUpdateContact(Contact contact) async {
    debugPrint('📝 [BLE] Adding/updating contact on companion radio:');
    debugPrint('    Name: ${contact.advName}');
    debugPrint(
      '    Public key prefix: ${contact.publicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
    );
    debugPrint('    Type: ${contact.type} (${contact.type.value})');

    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildAddUpdateContact(contact),
    );

    debugPrint('✅ [BLE] CMD_ADD_UPDATE_CONTACT acknowledged');
  }

  /// Send text message to contact (DM)
  Future<void> sendTextMessage({
    required Uint8List contactPublicKey,
    required String text,
    int textType = 0,
    int attempt = 0,
  }) async {
    if (utf8.encode(text).length > _maxContactMessageBytes) {
      throw ArgumentError(
        'Text message exceeds $_maxContactMessageBytes UTF-8 bytes',
      );
    }

    // Track the last contact for auto-recovery if contact not found
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

  /// Send flood-mode text message to channel
  /// Track a sent channel message for echo detection
  void trackSentChannelMessage(
    String messageId, {
    int? channelIdx,
    String? plainText,
  }) {
    debugPrint(
      '🔵 [MeshCoreBleService] trackSentChannelMessage called for: $messageId',
    );
    _responseHandler.trackSentMessage(
      messageId,
      null,
      channelIdx: channelIdx,
      plainText: plainText,
    );
  }

  /// Send a text message to a channel (flood-mode broadcast)
  ///
  /// Channel messages are ephemeral and use flood routing (no ACKs).
  /// Use channel 0 for the default public channel.
  Future<void> sendChannelMessage({
    required int channelIdx,
    required String text,
    int textType = 0,
  }) async {
    if (utf8.encode(text).length > _maxChannelMessageBytes) {
      throw ArgumentError(
        'Channel message exceeds $_maxChannelMessageBytes UTF-8 bytes',
      );
    }

    // Wait for generic ACK/ERR from firmware so invalid channel sends
    // (e.g. missing channel slot) are surfaced to callers.
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSendChannelTxtMsg(
        channelIdx: channelIdx,
        text: text,
        textType: textType,
      ),
    );
  }

  @override
  Future<void> sendChannelData({
    required int channelIdx,
    required int dataType,
    required Uint8List payload,
  }) async {
    if (dataType == 0) {
      throw ArgumentError.value(dataType, 'dataType', 'must be non-zero');
    }
    if (payload.length > MeshCoreConstants.maxChannelDataLength) {
      throw ArgumentError(
        'Channel datagram exceeds ${MeshCoreConstants.maxChannelDataLength} bytes',
      );
    }
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSendChannelData(
        channelIdx: channelIdx,
        dataType: dataType,
        payload: payload,
      ),
    );
  }

  /// Request telemetry (GPS, battery) from contact
  Future<void> requestTelemetry(
    Uint8List contactPublicKey, {
    bool zeroHop = false,
  }) async {
    await _commandSender.writeData(
      FrameBuilder.buildSendTelemetryReq(contactPublicKey, zeroHop: zeroHop),
    );
  }

  /// Send binary request to contact
  Future<void> sendBinaryRequest({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  }) async {
    await _commandSender.writeData(
      FrameBuilder.buildSendBinaryReq(
        contactPublicKey: contactPublicKey,
        requestData: requestData,
      ),
    );
  }

  /// Send control/discovery packet (firmware v8+).
  Future<void> sendControlData(Uint8List payload) async {
    await _commandSender.writeData(FrameBuilder.buildSendControlData(payload));
  }

  /// Send a raw binary packet to a direct contact.
  ///
  /// Uses [cmdSendRawData] (25) which sends binary payload over PAYLOAD_TYPE_RAW_CUSTOM.
  /// The receiver gets a [pushRawData] (0x84) push notification with the raw bytes.
  ///
  /// [contactPathLen] and [contactPath] come from [Contact.outPathLen] and [Contact.outPath].
  /// [payload] is the raw voice packet (8-byte header + Codec2 data, max ~161 bytes).
  ///
  /// Note: flood/channel mode is NOT supported by firmware for raw data.
  Future<void> sendRawVoicePacket({
    required int contactPathLen,
    required Uint8List contactPath,
    required Uint8List payload,
  }) async {
    await _commandSender.writeData(
      FrameBuilder.buildSendRawData(
        pathLen: contactPathLen,
        path: contactPath,
        payload: payload,
      ),
    );
  }

  /// Get battery voltage and storage information
  Future<void> getBatteryAndStorage() async {
    await _commandSender.writeData(FrameBuilder.buildGetBatteryAndStorage());
  }

  /// Legacy method name for backward compatibility
  @Deprecated('Use getBatteryAndStorage() instead')
  Future<void> getBatteryVoltage() async {
    await getBatteryAndStorage();
  }

  /// Sync next message from device queue
  Future<void> syncNextMessage() async {
    await _commandSender.writeData(FrameBuilder.buildSyncNextMessage());
  }

  /// Export a contact as a raw advert frame (for sharing as meshcore:// URL).
  /// Pass null to export self.
  Future<Uint8List> exportContact(Uint8List? publicKey) async {
    return _commandSender.writeDataAndWaitForResponse<Uint8List>(
      FrameBuilder.buildExportContact(publicKey),
      MeshCoreConstants.respExportContact,
    );
  }

  /// Read custom variables from device (GPS mode, sensor settings, etc.)
  Future<Map<String, String>> getCustomVars() async {
    return _commandSender.writeDataAndWaitForResponse<Map<String, String>>(
      FrameBuilder.buildGetCustomVars(),
      MeshCoreConstants.respCustomVars,
    );
  }

  /// Set a custom variable on the device
  Future<void> setCustomVar(String key, String value) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetCustomVar(key, value),
    );
  }

  /// Get device time from companion radio
  Future<void> getDeviceTime() async {
    await _commandSender.writeData(FrameBuilder.buildGetDeviceTime());
  }

  /// Set device time
  Future<void> setDeviceTime() async {
    await _commandSender.writeData(FrameBuilder.buildSetDeviceTime());
  }

  /// Send self advertisement packet to mesh network
  Future<void> sendSelfAdvert({bool floodMode = true}) async {
    await _commandSender.writeData(
      FrameBuilder.buildSendSelfAdvert(floodMode: floodMode),
    );
  }

  /// Set advertised name
  Future<void> setAdvertName(String name) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetAdvertName(name),
    );
  }

  /// Set advertised latitude and longitude
  Future<void> setAdvertLatLon({
    required double latitude,
    required double longitude,
  }) async {
    // This command updates device's advertised location
    // Fire-and-forget - no ACK needed since actual broadcast happens via sendSelfAdvert
    await _commandSender.writeData(
      FrameBuilder.buildSetAdvertLatLon(
        latitude: latitude,
        longitude: longitude,
      ),
    );
  }

  /// Set radio parameters
  /// [repeat] optional: true = enable client repeat (firmware v9+)
  Future<void> setRadioParams({
    required int frequency,
    required int bandwidth,
    required int spreadingFactor,
    required int codingRate,
    bool? repeat,
  }) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetRadioParams(
        frequency: frequency,
        bandwidth: bandwidth,
        spreadingFactor: spreadingFactor,
        codingRate: codingRate,
        repeat: repeat == null ? null : (repeat ? 1 : 0),
      ),
    );
  }

  /// Query allowed repeat frequencies (firmware v9+)
  Future<void> getAllowedRepeatFreq() async {
    await _commandSender.writeData(FrameBuilder.buildGetAllowedRepeatFreq());
  }

  /// Set transmit power
  Future<void> setTxPower(int powerDbm) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetTxPower(powerDbm),
    );
  }

  /// Set other parameters
  Future<void> setOtherParams({
    required int manualAddContacts,
    required int telemetryModes,
    required int advertLocationPolicy,
    int multiAcks = 0,
  }) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetOtherParams(
        manualAddContacts: manualAddContacts,
        telemetryModes: telemetryModes,
        advertLocationPolicy: advertLocationPolicy,
        multiAcks: multiAcks,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> getAutoaddConfig() {
    return _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
      FrameBuilder.buildGetAutoaddConfig(),
      MeshCoreConstants.respAutoaddConfig,
    );
  }

  @override
  Future<void> setAutoaddConfig({
    required bool autoAddUsers,
    required bool autoAddRepeaters,
    required bool autoAddRoomServers,
    required bool autoAddSensors,
    required bool overwriteOldest,
    int maxHops = 0,
  }) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetAutoaddConfig(
        autoAddUsers: autoAddUsers,
        autoAddRepeaters: autoAddRepeaters,
        autoAddRoomServers: autoAddRoomServers,
        autoAddSensors: autoAddSensors,
        overwriteOldest: overwriteOldest,
        maxHops: maxHops,
      ),
    );
  }

  @override
  Future<void> setPathHashMode(int mode) async {
    await _commandSender.writeDataAndWaitForAck(
      FrameBuilder.buildSetPathHashMode(mode),
    );
  }

  /// Send login request to room or repeater
  Future<void> loginToRoom({
    required Uint8List roomPublicKey,
    required String password,
  }) async {
    if (password.length > 15) {
      throw ArgumentError('Password exceeds 15 character limit');
    }

    debugPrint('🔐 [BLE] Preparing login request:');
    debugPrint(
      '    Room public key prefix: ${roomPublicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
    );
    debugPrint(
      '    Password: ${"*" * password.length} (${password.length} chars)',
    );

    await _commandSender.writeData(
      FrameBuilder.buildSendLogin(
        roomPublicKey: roomPublicKey,
        password: password,
      ),
    );
  }

  /// Send status request to repeater or sensor node
  Future<void> sendStatusRequest(Uint8List contactPublicKey) async {
    debugPrint('📊 [BLE] Preparing status request:');
    debugPrint(
      '    Target node public key prefix: ${contactPublicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
    );

    await _commandSender.writeData(
      FrameBuilder.buildSendStatusReq(contactPublicKey),
    );
  }

  @override
  Future<({int tag, int suggestedTimeoutMs})> sendAnonRequest({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  }) async {
    debugPrint('🕵️ [BLE] Preparing anonymous request:');
    debugPrint(
      '    Target node public key prefix: ${contactPublicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
    );

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

  /// Reset path for a contact - forces next message to flood and re-learn route
  Future<void> resetPath(Uint8List contactPublicKey) async {
    debugPrint('🔄 [BLE] Resetting path for contact:');
    debugPrint(
      '    Contact public key prefix: ${contactPublicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
    );

    await _commandSender.writeData(
      FrameBuilder.buildResetPath(contactPublicKey),
    );
  }

  @override
  Future<void> factoryReset() async {
    debugPrint('💥 [BLE] Sending factory reset command');
    await _commandSender.writeData(FrameBuilder.buildFactoryReset());
  }

  /// Remove a contact from the companion radio
  Future<void> removeContact(Uint8List contactPublicKey) async {
    debugPrint('🗑️ [BLE] Removing contact from companion radio:');
    debugPrint(
      '    Public key prefix: ${contactPublicKey.sublist(0, 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
    );

    await _commandSender.writeData(
      FrameBuilder.buildRemoveContact(contactPublicKey),
    );
    debugPrint('✅ [BLE] CMD_REMOVE_CONTACT sent');
  }

  /// Get information for a specific channel
  Future<void> getChannel(int channelIdx) async {
    // Wait for any burst sync to finish to avoid response misrouting
    while (_isBurstSyncActive) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await _commandSender.writeDataAndWaitForResponse<Map<String, dynamic>>(
      FrameBuilder.buildGetChannel(channelIdx),
      MeshCoreConstants.respChannelInfo,
    );
  }

  /// Set the name and secret for a specific channel
  ///
  /// The secret must be exactly 16 bytes (128-bit encryption key).
  /// For the default public channel (channel 0), use [MeshCoreConstants.defaultPublicChannelSecret].
  ///
  /// Set or update a channel on the companion radio.
  ///
  /// Firmware replies with RESP_CODE_OK on success or RESP_CODE_ERR on failure
  /// (e.g. invalid channel index).
  Future<void> setChannel({
    required int channelIdx,
    required String channelName,
    required List<int> secret,
  }) async {
    debugPrint('📻 [BLE] Setting channel:');
    debugPrint('    Channel index: $channelIdx');
    debugPrint('    Channel name: $channelName');
    debugPrint('    Secret length: ${secret.length} bytes');
    debugPrint(
      '    Secret hex: ${secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}',
    );

    final setChannelData = FrameBuilder.buildSetChannel(
      channelIdx: channelIdx,
      channelName: channelName,
      secret: secret,
    );
    debugPrint(
      '    SET_CHANNEL data (${setChannelData.length} bytes): ${setChannelData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
    );

    await _commandSender.writeDataAndWaitForAck(setChannelData);
    debugPrint('✅ [BLE] CMD_SET_CHANNEL acknowledged');
  }

  /// Delete a channel by clearing its slot
  ///
  /// This removes the channel from the device by setting it to an empty name and zeroed secret.
  /// The channel slot becomes available for reuse.
  ///
  /// Note: Channel 0 (public channel) cannot be deleted.
  Future<void> deleteChannel(int channelIdx) async {
    if (channelIdx == 0) {
      throw ArgumentError('Cannot delete channel 0 (public channel)');
    }

    debugPrint('🗑️  [BLE] Deleting channel $channelIdx...');

    // Clear channel by setting empty name and zeroed secret
    await setChannel(
      channelIdx: channelIdx,
      channelName: '',
      secret: List.filled(16, 0),
    );

    debugPrint('✅ [BLE] Channel $channelIdx deleted');
  }

  /// Sync all channels from the device (channels 1-39).
  ///
  /// Fires all getChannel requests in rapid succession (bypassing queue
  /// serialization) and collects responses via the channelInfo callback.
  /// Stops on first error response (= no more channel slots), matching the
  /// official MeshCore app behaviour.
  @override
  Future<void> syncAllChannels({int maxChannels = 40}) async {
    debugPrint(
      '📻 [Service] Syncing channels (1-${maxChannels - 1}) in burst...',
    );
    _isBurstSyncActive = true;

    final completer = Completer<void>();
    int received = 0;
    int sent = 0;
    final prevChannelCallback = _responseHandler.onChannelInfoReceived;
    final prevErrorCallback = _responseHandler.onError;

    void finish() {
      _isBurstSyncActive = false;
      _responseHandler.onChannelInfoReceived = prevChannelCallback;
      _responseHandler.onError = prevErrorCallback;
      if (!completer.isCompleted) completer.complete();
    }

    _responseHandler.onChannelInfoReceived =
        (int channelIdx, String channelName, Uint8List secret, int? flags) {
          received++;
          // Forward to the original callback
          prevChannelCallback?.call(channelIdx, channelName, secret, flags);
          if (received >= sent && !completer.isCompleted) {
            finish();
          }
        };

    _responseHandler.onError = (String error, {int? errorCode}) {
      // Forward the error
      prevErrorCallback?.call(error, errorCode: errorCode);
      // ERR_CODE_NOT_FOUND (2) means we hit the end of valid channel slots.
      // Other errors are forwarded but don't abort the sync.
      if (errorCode == 2) {
        finish();
      }
    };

    // Fire all requests without waiting for individual responses
    for (int i = 1; i < maxChannels; i++) {
      try {
        await _commandSender.writeDataDirect(FrameBuilder.buildGetChannel(i));
        sent++;
      } catch (e) {
        debugPrint('⚠️ [Service] Channel sync write failed at slot $i: $e');
        break;
      }
    }

    if (sent == 0) {
      finish();
      return;
    }

    // Wait for all responses (or error/timeout)
    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        debugPrint(
          '⚠️ [Service] Channel sync timed out after 15s (received $received/$sent)',
        );
        finish();
      },
    );

    debugPrint(
      '✅ [Service] Channel sync complete ($received channels received)',
    );
  }

  /// Clear packet logs
  void clearPacketLogs() {
    _commandSender.clearPacketLogs();
    _responseHandler.clearPacketLogs();
  }

  /// Reset packet counters
  void resetCounters() {
    _commandSender.resetCounter();
    _responseHandler.resetCounter();
  }

  /// Start keepalive timer for iOS background mode
  /// Periodically syncs messages to keep BLE connection alive and check for new messages
  /// This serves dual purpose: prevents iOS from killing idle BLE connections AND
  /// provides fallback message sync when push notifications (PUSH_CODE_MSG_WAITING) don't trigger
  void _startKeepalive() {
    _stopKeepalive(); // Stop any existing timer

    debugPrint(
      '🔄 [BLE] Starting keepalive timer (${_keepaliveInterval.inSeconds}s interval)',
    );

    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (timer) async {
      if (!isConnected) {
        debugPrint('⚠️ [BLE] Keepalive: Not connected, stopping timer');
        _stopKeepalive();
        return;
      }

      try {
        // Sync messages to keep connection alive AND check for new messages
        // This is a fallback in case PUSH_CODE_MSG_WAITING doesn't fire
        // If no messages waiting, device responds with RESP_CODE_NO_MORE_MSG
        await syncNextMessage();
        debugPrint(
          '💚 [BLE] Keepalive: Connection maintained & messages synced',
        );
      } catch (e) {
        debugPrint('⚠️ [BLE] Keepalive error: $e');
        // Don't stop timer on error - iOS might throttle commands temporarily
      }
    });
  }

  /// Stop keepalive timer
  void _stopKeepalive() {
    if (_keepaliveTimer != null) {
      debugPrint('🛑 [BLE] Stopping keepalive timer');
      _keepaliveTimer?.cancel();
      _keepaliveTimer = null;
    }
  }

  /// Dispose resources
  void dispose() {
    _stopKeepalive(); // Clean up keepalive timer
    _connectionManager.dispose();
    _commandSender.dispose();
    _responseHandler.dispose();
  }

  Future<Map<String, dynamic>> _sendAndAwaitDeviceInfo() async {
    const maxAttempts = 2;
    final timeout = kIsWeb
        ? const Duration(seconds: 20)
        : const Duration(seconds: 10);

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      _pendingDeviceInfoCompleter = Completer<Map<String, dynamic>>();
      await _commandSender.writeData(FrameBuilder.buildDeviceQuery());

      try {
        return await _pendingDeviceInfoCompleter!.future.timeout(timeout);
      } on TimeoutException {
        debugPrint(
          '⚠️ [Service] Device info attempt ${attempt + 1}/$maxAttempts timed out after ${timeout.inSeconds}s',
        );
        if (attempt == maxAttempts - 1) rethrow;
      } finally {
        _pendingDeviceInfoCompleter = null;
      }
    }

    throw TimeoutException('Device info request failed');
  }

  Future<Map<String, dynamic>> _sendAndAwaitSelfInfo() async {
    const maxAttempts = 3;
    final timeout = kIsWeb
        ? const Duration(seconds: 8)
        : const Duration(seconds: 5);

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      _pendingSelfInfoCompleter = Completer<Map<String, dynamic>>();
      await _commandSender.writeData(
        FrameBuilder.buildAppStart(appName: appName),
      );

      try {
        return await _pendingSelfInfoCompleter!.future.timeout(timeout);
      } on TimeoutException {
        debugPrint(
          '⚠️ [Service] Self info attempt ${attempt + 1}/$maxAttempts timed out after ${timeout.inSeconds}s',
        );
        if (attempt == maxAttempts - 1) rethrow;
      } finally {
        _pendingSelfInfoCompleter = null;
      }
    }

    throw TimeoutException('Self info request failed');
  }
}
