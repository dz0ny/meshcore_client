import 'package:flutter/foundation.dart';
import 'models/contact.dart';
import 'models/ble_packet_log.dart';
import 'ble/ble_response_handler.dart';
import 'ble/ble_connection_manager.dart'
    show
        OnConnectionStateCallback,
        OnReconnectionAttemptCallback,
        OnRssiUpdateCallback;

/// Abstract base for both BLE and TCP MeshCore service implementations.
///
/// Defines the shared command API and callback surface used by ConnectionProvider.
/// Transport-specific connection methods (connect / disconnect) are defined in
/// the concrete subclasses.
abstract class MeshCoreServiceBase {
  // ── Callbacks ──────────────────────────────────────────────────────────────

  OnConnectionStateCallback? onConnectionStateChanged;
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
  OnBatteryAndStorageCallback? onBatteryAndStorage;
  OnErrorCallback? onError;
  OnContactNotFoundCallback? onContactNotFound;
  OnChannelInfoCallback? onChannelInfoReceived;
  OnAllowedRepeatFreqCallback? onAllowedRepeatFreqReceived;
  void Function(Uint8List publicKey)? onContactDeleted;
  VoidCallback? onContactsFull;
  OnRawDataReceivedCallback? onRawDataReceived;
  OnChannelDataReceivedCallback? onChannelDataReceived;
  OnControlDataCallback? onControlDataReceived;
  OnAutoaddConfigCallback? onAutoaddConfigReceived;
  VoidCallback? onRxActivity;
  VoidCallback? onTxActivity;
  OnReconnectionAttemptCallback? onReconnectionAttempt;
  OnRssiUpdateCallback? onRssiUpdate;

  // ── State ──────────────────────────────────────────────────────────────────

  bool get isConnected;
  bool get isReconnecting;
  int get reconnectionAttempt;
  int get maxReconnectionAttempts;
  int get rxPacketCount;
  int get txPacketCount;
  List<BlePacketLog> get packetLogs;
  // ── Commands ───────────────────────────────────────────────────────────────

  Future<void> getContacts();
  Future<void> getContactByKey(Uint8List publicKey);
  Future<void> importContact(Uint8List contactAdvertFrame);

  /// Import a recently received advert by public key.
  ///
  /// Tells the firmware to look up the advert in its received-advert buffer,
  /// store the contact, and return the routing path.  After this call,
  /// [getContactByKey] will return the full contact with name, type, etc.
  Future<void> importReceivedAdvert(Uint8List publicKey);
  Future<void> addOrUpdateContact(Contact contact);
  Future<void> removeContact(Uint8List contactPublicKey);
  Future<void> resetPath(Uint8List contactPublicKey);
  Future<void> factoryReset();

  Future<void> sendTextMessage({
    required Uint8List contactPublicKey,
    required String text,
    int textType = 0,
    int attempt = 0,
  });

  Future<void> sendChannelMessage({
    required int channelIdx,
    required String text,
    int textType = 0,
    Uint8List? floodScopeKey,
  });

  void trackSentChannelMessage(
    String messageId, {
    int? channelIdx,
    String? plainText,
  });

  Future<void> sendRawVoicePacket({
    required int contactPathLen,
    required Uint8List contactPath,
    required Uint8List payload,
  });

  Future<void> sendChannelData({
    required int channelIdx,
    required int dataType,
    required Uint8List payload,
    Uint8List? floodScopeKey,
  });

  Future<void> requestTelemetry(
    Uint8List contactPublicKey, {
    bool zeroHop = false,
  });

  Future<void> sendBinaryRequest({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  });

  /// Set the flood scope transport key (firmware v8+).
  /// All subsequent flood sends will be tagged with this scope.
  Future<void> setFloodScope(Uint8List scopeKey);

  /// Clear the flood scope (firmware v8+).
  /// Subsequent flood sends will be unscoped.
  Future<void> clearFloodScope();

  Future<void> sendControlData(Uint8List payload);

  Future<void> syncNextMessage();
  Future<void> getDeviceTime();
  Future<void> setDeviceTime();
  Future<void> sendSelfAdvert({bool floodMode = true});
  Future<void> setAdvertName(String name);
  Future<void> setAdvertLatLon({
    required double latitude,
    required double longitude,
  });

  Future<void> setRadioParams({
    required int frequency,
    required int bandwidth,
    required int spreadingFactor,
    required int codingRate,
    bool? repeat,
  });

  Future<void> getAllowedRepeatFreq();
  Future<void> setTxPower(int powerDbm);
  Future<void> setOtherParams({
    required int manualAddContacts,
    required int telemetryModes,
    required int advertLocationPolicy,
    int multiAcks = 0,
  });
  Future<Map<String, dynamic>> getAutoaddConfig();
  Future<void> setAutoaddConfig({
    required bool autoAddUsers,
    required bool autoAddRepeaters,
    required bool autoAddRoomServers,
    required bool autoAddSensors,
    required bool overwriteOldest,
    int maxHops = 0,
  });
  Future<void> setPathHashMode(int mode);

  Future<Uint8List> exportContact(Uint8List? publicKey);
  Future<Map<String, String>> getCustomVars();
  Future<void> setCustomVar(String key, String value);
  Future<void> refreshDeviceInfo();
  Future<void> getBatteryAndStorage();
  Future<void> loginToRoom({
    required Uint8List roomPublicKey,
    required String password,
  });

  Future<void> sendStatusRequest(Uint8List contactPublicKey);
  Future<({int tag, int suggestedTimeoutMs})> sendAnonRequest({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  });
  Future<void> getChannel(int channelIdx);
  Future<void> setChannel({
    required int channelIdx,
    required String channelName,
    required List<int> secret,
  });

  Future<void> deleteChannel(int channelIdx);
  Future<void> syncAllChannels({int maxChannels = 40});

  void clearPacketLogs();
  void resetCounters();

  void dispose();
}
