import 'dart:convert';
import 'dart:typed_data';
import '../models/contact.dart';
import '../buffer_writer.dart';
import '../meshcore_constants.dart';

/// Builds outgoing BLE frames for the MeshCore device
class FrameBuilder {
  /// Build DeviceQuery command
  static Uint8List buildDeviceQuery() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdDeviceQuery);
    writer.writeByte(MeshCoreConstants.supportedCompanionProtocolVersion);
    return writer.toBytes();
  }

  /// Build AppStart command
  ///
  /// [appName] - The name of the companion app sent to the device.
  static Uint8List buildAppStart({String appName = 'MeshCore Client'}) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdAppStart);
    writer.writeByte(1); // appVer
    writer.writeBytes(Uint8List(6)); // reserved
    writer.writeString(appName);
    writer.writeByte(0);
    return writer.toBytes();
  }

  /// Build GetContacts command
  static Uint8List buildGetContacts() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetContacts);
    return writer.toBytes();
  }

  /// Build GetContactByKey command - retrieves a single contact by public key
  static Uint8List buildGetContactByKey(Uint8List publicKey) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetContactByKey); // 0x1E (30)
    writer.writeBytes(publicKey); // 32 bytes
    return writer.toBytes();
  }

  /// Build AddUpdateContact command
  static Uint8List buildAddUpdateContact(Contact contact) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdAddUpdateContact); // 0x09
    writer.writeBytes(contact.publicKey); // 32 bytes
    writer.writeByte(contact.type.value); // ADV_TYPE_*
    writer.writeByte(contact.flags); // flags
    writer.writeByte(contact.outPathLen & 0xFF); // raw path descriptor
    writer.writeBytes(contact.outPath); // 64 bytes

    // Write name as null-terminated string in 32-byte field
    final nameBytes = Uint8List(32);
    final encoded = utf8.encode(contact.advName);
    final copyLen = encoded.length > 31 ? 31 : encoded.length;
    nameBytes.setRange(0, copyLen, encoded);
    writer.writeBytes(nameBytes);

    writer.writeUInt32LE(contact.lastAdvert); // timestamp
    writer.writeInt32LE(contact.advLat); // latitude * 1E6
    writer.writeInt32LE(contact.advLon); // longitude * 1E6

    return writer.toBytes();
  }

  /// Build SendTxtMsg command
  static Uint8List buildSendTxtMsg({
    required Uint8List contactPublicKey,
    required String text,
    int textType = 0,
    int attempt = 0,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendTxtMsg); // 0x02
    writer.writeByte(textType); // TXT_TYPE_*
    writer.writeByte(attempt); // 0-3
    writer.writeUInt32LE(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    writer.writeBytes(contactPublicKey.sublist(0, 6));
    writer.writeString(text);
    writer.writeByte(0);
    return writer.toBytes();
  }

  /// Build SendChannelTxtMsg command
  static Uint8List buildSendChannelTxtMsg({
    required int channelIdx,
    required String text,
    int textType = 0,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendChannelTxtMsg); // 0x03
    writer.writeByte(textType); // TXT_TYPE_*
    writer.writeByte(channelIdx); // 0 for 'public' channel
    writer.writeUInt32LE(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    writer.writeString(text);
    writer.writeByte(0);
    return writer.toBytes();
  }

  /// Build SendTelemetryReq command
  /// Requests telemetry (GPS, battery) from a contact
  static Uint8List buildSendTelemetryReq(
    Uint8List contactPublicKey, {
    bool zeroHop = false,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendTelemetryReq);
    writer.writeByte(zeroHop ? 0 : 255);
    writer.writeByte(0); // reserved
    writer.writeByte(0); // reserved
    writer.writeBytes(contactPublicKey);
    return writer.toBytes();
  }

  /// Build self telemetry request — asks the companion device for its own
  /// sensor data (GPS, temperature, battery, etc.)
  static Uint8List buildSelfTelemetryReq() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendTelemetryReq);
    writer.writeByte(0); // zero-hop (self)
    writer.writeByte(0); // reserved
    writer.writeByte(0); // reserved
    // No public key = request own telemetry
    return writer.toBytes();
  }

  /// Build SendRawData command — direct-route binary payload (no base64, no text encoding).
  ///
  /// [path] is the contact's [outPath], [pathLen] is [outPathLen].
  /// [payload] is the raw binary data to send (max ~161 bytes to stay within
  /// the MeshCore MAX_FRAME_SIZE = 172 byte limit).
  ///
  /// Note: flood routing is NOT supported by the firmware for raw data.
  /// This only works with contacts that have a known direct path (outPathLen >= 0).
  static Uint8List buildSendRawData({
    required int pathLen,
    required Uint8List path,
    required Uint8List payload,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendRawData); // 25
    writer.writeByte(pathLen & 0xFF); // raw path descriptor
    final normalized = pathLen & 0xFF;
    final pathByteLen = normalized == 0xFF
        ? 0
        : ((normalized >> 6) == 0)
        ? normalized
        : (normalized & 0x3F) * ((normalized >> 6) + 1);
    writer.writeBytes(path.sublist(0, pathByteLen.clamp(0, path.length)));
    writer.writeBytes(payload);
    return writer.toBytes();
  }

  /// Build SendBinaryReq command
  static Uint8List buildSendBinaryReq({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendBinaryReq); // 0x32 (50)
    writer.writeBytes(contactPublicKey); // 32 bytes
    writer.writeBytes(requestData); // request code + params
    return writer.toBytes();
  }

  /// Build GetBatteryVoltage command
  static Uint8List buildGetBatteryAndStorage() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetBatteryVoltage);
    return writer.toBytes();
  }

  /// Build SyncNextMessage command
  static Uint8List buildSyncNextMessage() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSyncNextMessage);
    return writer.toBytes();
  }

  /// Build GetDeviceTime command
  static Uint8List buildGetDeviceTime() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetDeviceTime);
    return writer.toBytes();
  }

  /// Build SetDeviceTime command
  static Uint8List buildSetDeviceTime() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetDeviceTime);
    writer.writeUInt32LE(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return writer.toBytes();
  }

  /// Build SendSelfAdvert command
  static Uint8List buildSendSelfAdvert({bool floodMode = true}) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendSelfAdvert);
    writer.writeByte(
      floodMode
          ? MeshCoreConstants.selfAdvertFlood
          : MeshCoreConstants.selfAdvertZeroHop,
    );
    return writer.toBytes();
  }

  /// Build SetAdvertName command
  static Uint8List buildSetAdvertName(String name) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetAdvertName);
    writer.writeString(name);
    return writer.toBytes();
  }

  /// Build SetAdvertLatLon command
  static Uint8List buildSetAdvertLatLon({
    required double latitude,
    required double longitude,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetAdvertLatLon);
    writer.writeInt32LE((latitude * 1000000).round());
    writer.writeInt32LE((longitude * 1000000).round());
    return writer.toBytes();
  }

  /// Build SetRadioParams command
  /// [repeat] optional: 1 = enable client repeat (firmware v9+), 0 = disable
  static Uint8List buildSetRadioParams({
    required int frequency,
    required int bandwidth,
    required int spreadingFactor,
    required int codingRate,
    int? repeat,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetRadioParams);
    writer.writeUInt32LE(frequency);
    writer.writeUInt16LE(bandwidth);
    writer.writeByte(spreadingFactor);
    writer.writeByte(codingRate);
    if (repeat != null) {
      writer.writeByte(repeat);
    }
    return writer.toBytes();
  }

  /// Build GetAllowedRepeatFreq command (firmware v9+)
  static Uint8List buildGetAllowedRepeatFreq() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetAllowedRepeatFreq);
    return writer.toBytes();
  }

  static Uint8List buildSendChannelData({
    required int channelIdx,
    required int dataType,
    required Uint8List payload,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendChannelData);
    writer.writeUInt16LE(dataType);
    writer.writeByte(channelIdx);
    writer.writeBytes(payload);
    return writer.toBytes();
  }

  /// Build SetTxPower command
  static Uint8List buildSetTxPower(int powerDbm) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetTxPower);
    writer.writeByte(powerDbm);
    return writer.toBytes();
  }

  /// Build SetOtherParams command
  static Uint8List buildSetOtherParams({
    required int manualAddContacts,
    required int telemetryModes,
    required int advertLocationPolicy,
    int multiAcks = 0,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetOtherParams);
    writer.writeByte(manualAddContacts);
    writer.writeByte(telemetryModes);
    writer.writeByte(advertLocationPolicy);
    writer.writeByte(multiAcks);
    return writer.toBytes();
  }

  static Uint8List buildSetAutoaddConfig({
    required bool autoAddUsers,
    required bool autoAddRepeaters,
    required bool autoAddRoomServers,
    required bool autoAddSensors,
    required bool overwriteOldest,
    int maxHops = 0,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetAutoaddConfig);
    var flags = 0;
    if (overwriteOldest) flags |= 0x01;
    if (autoAddUsers) flags |= 0x02;
    if (autoAddRepeaters) flags |= 0x04;
    if (autoAddRoomServers) flags |= 0x08;
    if (autoAddSensors) flags |= 0x10;
    writer.writeByte(flags);
    writer.writeByte(maxHops);
    return writer.toBytes();
  }

  static Uint8List buildGetAutoaddConfig() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetAutoaddConfig);
    return writer.toBytes();
  }

  static Uint8List buildSetPathHashMode(int mode) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetPathHashMode);
    writer.writeByte(0); // reserved
    writer.writeByte(mode);
    return writer.toBytes();
  }

  /// Build SendLogin command
  static Uint8List buildSendLogin({
    required Uint8List roomPublicKey,
    required String password,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendLogin); // 0x1A
    writer.writeBytes(roomPublicKey); // 32 bytes
    writer.writeString(password);
    writer.writeByte(0);
    return writer.toBytes();
  }

  /// Build SendStatusReq command
  static Uint8List buildSendStatusReq(Uint8List contactPublicKey) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendStatusReq); // 0x1B
    writer.writeBytes(contactPublicKey); // 32 bytes
    return writer.toBytes();
  }

  /// Build SendAnonReq command
  static Uint8List buildSendAnonReq({
    required Uint8List contactPublicKey,
    required Uint8List requestData,
  }) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendAnonReq);
    writer.writeBytes(contactPublicKey);
    writer.writeBytes(requestData);
    return writer.toBytes();
  }

  /// Build SetFloodScope command (firmware v8+)
  ///
  /// Sets the transport scope key used for all subsequent flood sends.
  /// [scopeKey] must be exactly 16 bytes (SHA256(region_name)[0:16]).
  /// Repeaters only forward packets whose scope matches their allowed regions.
  static Uint8List buildSetFloodScope(Uint8List scopeKey) {
    if (scopeKey.length != 16) {
      throw ArgumentError(
        'Flood scope key must be exactly 16 bytes (got ${scopeKey.length})',
      );
    }
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetFloodScope); // 54
    writer.writeByte(0); // sub-command (always 0)
    writer.writeBytes(scopeKey);
    return writer.toBytes();
  }

  /// Build ClearFloodScope command (firmware v8+)
  ///
  /// Clears the transport scope so subsequent flood sends are unscoped.
  static Uint8List buildClearFloodScope() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetFloodScope); // 54
    writer.writeByte(0); // sub-command (always 0)
    return writer.toBytes();
  }

  /// Build SendControlData command (firmware v8+)
  static Uint8List buildSendControlData(Uint8List payload) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendControlData);
    writer.writeBytes(payload);
    return writer.toBytes();
  }

  /// Build SendTracePath command (ping) — sends a trace/ping to a contact.
  ///
  /// [nonce] random 32-bit value used to correlate the response.
  /// [prefixSize] number of public key bytes to send (1, 2, 4, or 8).
  ///   Determines hop type: 1→0 (zero-hop), 2→1, 4→2, 8→3.
  /// [contactPublicKey] full public key (first [prefixSize] bytes are sent).
  static Uint8List buildSendTracePath({
    required int nonce,
    int prefixSize = 1,
    required Uint8List contactPublicKey,
  }) {
    // Map prefix size → hop type
    // 1 byte → 0 (zero-hop), 2 → 1, 4 → 2, 8 → 3
    const prefixToHop = {1: 0, 2: 1, 4: 2, 8: 3};
    final hopType = prefixToHop[prefixSize] ?? 0;
    final keyLen = (prefixToHop.containsKey(prefixSize) ? prefixSize : 1)
        .clamp(1, contactPublicKey.length);
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSendTracePath); // 36
    writer.writeUInt32LE(nonce);
    writer.writeUInt32LE(0); // reserved
    writer.writeByte(hopType);
    writer.writeBytes(contactPublicKey.sublist(0, keyLen));
    return writer.toBytes();
  }

  /// Build ResetPath command - clears learned path for a contact
  static Uint8List buildResetPath(Uint8List contactPublicKey) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdResetPath); // 0x0D (13)
    writer.writeBytes(contactPublicKey); // 32 bytes
    return writer.toBytes();
  }

  /// Build ImportContact command - imports an exported advert/contact blob
  static Uint8List buildImportContact(Uint8List contactAdvertFrame) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdImportContact); // 0x12 (18)
    writer.writeBytes(contactAdvertFrame);
    return writer.toBytes();
  }

  /// Build GetAdvertPath command - imports a received advert by public key
  /// and returns the advert's routing path.
  ///
  /// This tells the firmware to look up a recently received advert in its
  /// internal buffer, store the contact, and return the routing path.
  /// After this call, [buildGetContactByKey] will return the full contact
  /// including name, type, location, etc.
  static Uint8List buildGetAdvertPath(Uint8List publicKey) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetAdvertPath); // 0x2A (42)
    writer.writeByte(0); // sub-command: import from received advert buffer
    writer.writeBytes(publicKey); // 32 bytes
    return writer.toBytes();
  }

  /// Build ExportContact command — exports a contact as a 64-byte advert frame
  static Uint8List buildExportContact(Uint8List? publicKey) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdExportContact); // 0x11 (17)
    if (publicKey != null) {
      writer.writeBytes(publicKey); // 32 bytes — export specific contact
    }
    // Without publicKey: exports self
    return writer.toBytes();
  }

  /// Build GetCustomVars command — reads device custom variables (e.g. GPS mode)
  static Uint8List buildGetCustomVars() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetCustomVars); // 0x28 (40)
    return writer.toBytes();
  }

  /// Build SetCustomVar command — sets a single custom variable
  ///
  /// Format: [cmd(1)]["key:value" as UTF-8 string]
  /// Example: key="gps", value="1" → sends [0x29][gps:1]
  static Uint8List buildSetCustomVar(String key, String value) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetCustomVar); // 0x29 (41)
    writer.writeString('$key:$value');
    return writer.toBytes();
  }

  /// Build FactoryReset command - erases device data and restores defaults
  static Uint8List buildFactoryReset() {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdFactoryReset); // 0x33 (51)
    return writer.toBytes();
  }

  /// Build RemoveContact command - removes a contact from the device
  static Uint8List buildRemoveContact(Uint8List contactPublicKey) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdRemoveContact); // 0x0F (15)
    writer.writeBytes(contactPublicKey); // 32 bytes
    return writer.toBytes();
  }

  /// Build GetChannel command - retrieves information for a specific channel
  static Uint8List buildGetChannel(int channelIdx) {
    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdGetChannel); // 0x1F (31)
    writer.writeByte(channelIdx); // 0-39 typically
    return writer.toBytes();
  }

  /// Build SetChannel command - sets the name and secret for a specific channel
  ///
  /// Format: [cmd(1)][channel_idx(1)][name(32)][secret(16)]
  /// Secret must be exactly 16 bytes (128-bit key)
  static Uint8List buildSetChannel({
    required int channelIdx,
    required String channelName,
    required List<int> secret,
  }) {
    if (secret.length != 16) {
      throw ArgumentError(
        'Channel secret must be exactly 16 bytes (got ${secret.length})',
      );
    }

    final writer = BufferWriter();
    writer.writeByte(MeshCoreConstants.cmdSetChannel); // 0x20 (32)
    writer.writeByte(channelIdx); // 0-39 typically

    // Write channel name as null-terminated string in 32-byte field
    final nameBytes = Uint8List(32);
    final encoded = utf8.encode(channelName);
    final copyLen = encoded.length > 31 ? 31 : encoded.length;
    nameBytes.setRange(0, copyLen, encoded);
    writer.writeBytes(nameBytes);

    // Write 16-byte secret
    writer.writeBytes(Uint8List.fromList(secret));

    return writer.toBytes();
  }
}
