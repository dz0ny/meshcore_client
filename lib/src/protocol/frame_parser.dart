import 'dart:convert';
import 'dart:typed_data';
import '../models/contact.dart';
import '../models/message.dart';
import '../buffer_reader.dart';
import '../helpers/smaz.dart';
import '../meshcore_constants.dart';

/// Parses incoming BLE frames from the MeshCore device
class FrameParser {
  /// Parse ContactsStart response
  static int parseContactsStart(BufferReader reader) {
    return reader.readUInt32LE();
  }

  /// Parse Contact response
  static Contact parseContact(BufferReader reader) {
    final publicKey = reader.readBytes(32);
    final typeByte = reader.readByte();
    final type = ContactType.fromValue(typeByte);
    final flags = reader.readByte();
    final outPathLen = reader.readByte();
    final outPath = reader.readBytes(64);
    final advName = reader.readCString(32);
    final lastAdvert = reader.readUInt32LE();
    final advLat = reader.readInt32LE();
    final advLon = reader.readInt32LE();
    final lastMod = reader.readUInt32LE();

    return Contact(
      publicKey: publicKey,
      type: type,
      flags: flags,
      outPathLen: outPathLen,
      outPath: outPath,
      advName: advName,
      lastAdvert: lastAdvert,
      advLat: advLat,
      advLon: advLon,
      lastMod: lastMod,
    );
  }

  /// Parse Sent confirmation response
  static Map<String, dynamic> parseSentConfirmation(BufferReader reader) {
    if (reader.remainingBytesCount >= 9) {
      final sendType = reader.readByte();
      final isFloodMode = sendType == 1;
      final expectedAckOrTagBytes = reader.readBytes(4);
      final expectedAckTag = ByteData.sublistView(
        Uint8List.fromList(expectedAckOrTagBytes),
      ).getUint32(0, Endian.little);
      final suggestedTimeout = reader.readUInt32LE();

      return {
        'expectedAckTag': expectedAckTag,
        'suggestedTimeout': suggestedTimeout,
        'isFloodMode': isFloodMode,
      };
    }
    return {};
  }

  /// Parse ContactMessage V3 response (firmware ver >= 3)
  /// V3 prepends 3 bytes: [snr_scaled(int8)][reserved][reserved]
  /// snr_dB = snr_scaled / 4.0
  static Message parseContactMessageV3(BufferReader reader) {
    reader.readInt8(); // snr scaled by 4 (ignored for now)
    reader.readBytes(2); // reserved
    return parseContactMessage(reader);
  }

  /// Parse ChannelMessage V3 response (firmware ver >= 3)
  /// V3 prepends 3 bytes: [snr_scaled(int8)][reserved][reserved]
  static Message parseChannelMessageV3(BufferReader reader) {
    reader.readInt8(); // snr scaled by 4 (ignored for now)
    final flags = reader.readByte();
    reader.readByte(); // reserved

    final channelIdx = reader.readByte();
    final pathDescriptor = reader.readByte();
    final pathByteLen = _pathByteLength(pathDescriptor);
    final pathHopCount = _pathHopCount(pathDescriptor);

    final canFitPath =
        pathByteLen > 0 && reader.remainingBytesCount >= pathByteLen + 5;
    if (canFitPath) {
      final nextByte = reader.peekByte();
      final hasValidTxtType = _parseTextType(nextByte) != null;
      final hasPathBytesFlag = (flags & 0x01) != 0;
      if (hasPathBytesFlag || !hasValidTxtType) {
        reader.readBytes(pathByteLen);
      }
    }

    final txtTypeByte = reader.readByte();
    final txtType = _parseTextType(txtTypeByte) ?? MessageTextType.plain;
    final senderTimestamp = reader.readUInt32LE();
    final text = reader.hasRemaining ? reader.readString() : '';
    final parsed = _decodeChannelText(text, parseSender: true);

    return Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_ch$channelIdx',
      messageType: MessageType.channel,
      channelIdx: channelIdx,
      pathLen: pathHopCount,
      textType: txtType,
      senderTimestamp: senderTimestamp,
      text: parsed.$2,
      senderName: parsed.$1,
      receivedAt: DateTime.now(),
    );
  }

  /// Parse ContactMessage response
  static Message parseContactMessage(BufferReader reader) {
    final pubKeyPrefix = reader.readBytes(6);
    final pathDescriptor = reader.readByte();
    final txtTypeByte = reader.readByte();
    final txtType = _parseTextType(txtTypeByte) ?? MessageTextType.plain;
    final senderTimestamp = reader.readUInt32LE();

    String text;
    Uint8List? roomPostAuthorPrefix;
    if (txtType == MessageTextType.signedPlain) {
      // Signed message format: [4-byte room post author prefix][UTF-8 text]
      // The author prefix identifies who originally posted in a room.
      if (reader.remainingBytesCount >= 4) {
        roomPostAuthorPrefix = Uint8List.fromList(reader.readBytes(4));
        text = reader.hasRemaining ? reader.readString() : '';
      } else {
        text = reader.readString();
      }
    } else {
      text = reader.readString();
    }

    final decodedText = txtType == MessageTextType.cliData
        ? text
        : (Smaz.tryDecodePrefixed(text) ?? text);

    return Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_${pubKeyPrefix.map((b) => b.toRadixString(16)).join()}',
      messageType: MessageType.contact,
      senderPublicKeyPrefix: pubKeyPrefix,
      roomPostAuthorPrefix: roomPostAuthorPrefix,
      pathLen: _pathHopCount(pathDescriptor),
      textType: txtType,
      senderTimestamp: senderTimestamp,
      text: decodedText,
      receivedAt: DateTime.now(),
    );
  }

  /// Parse ChannelMessage response
  static Message parseChannelMessage(BufferReader reader) {
    final channelIdx = reader.readByte(); // unsigned 0-255, not signed
    final pathDescriptor = reader.readByte();
    final txtTypeByte = reader.readByte();
    final txtType = _parseTextType(txtTypeByte) ?? MessageTextType.plain;
    final senderTimestamp = reader.readUInt32LE();

    String text;
    if (txtType == MessageTextType.signedPlain) {
      if (reader.remainingBytesCount >= 4) {
        reader.readBytes(4); // Skip extra sender prefix
        text = reader.hasRemaining ? reader.readString() : '';
      } else {
        text = reader.readString();
      }
    } else {
      text = reader.readString();
    }

    final parsed = _decodeChannelText(text, parseSender: true);
    final senderName = parsed.$1;
    final actualMessage = parsed.$2;

    return Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_ch$channelIdx',
      messageType: MessageType.channel,
      channelIdx: channelIdx,
      pathLen: _pathHopCount(pathDescriptor),
      textType: txtType,
      senderTimestamp: senderTimestamp,
      text: actualMessage, // Store the actual message without sender prefix
      senderName: senderName, // Store extracted sender name
      receivedAt: DateTime.now(),
    );
  }

  static MessageTextType? _parseTextType(int rawValue) {
    final direct = MessageTextType.values.where((t) => t.value == rawValue);
    if (direct.isNotEmpty) return direct.first;

    final shifted = rawValue >> 2;
    final shiftedMatch = MessageTextType.values.where(
      (t) => t.value == shifted,
    );
    if (shiftedMatch.isNotEmpty) return shiftedMatch.first;

    return null;
  }

  static int _pathHopCount(int descriptor) {
    final normalized = descriptor & 0xFF;
    if (normalized == 0xFF) return 255;
    return normalized & 0x3F;
  }

  static int _pathByteLength(int descriptor) {
    final normalized = descriptor & 0xFF;
    if (normalized == 0xFF) return 0;
    final hashMode = normalized >> 6;
    if (hashMode == 0) return normalized;
    final hashSize = hashMode + 1;
    return (normalized & 0x3F) * hashSize;
  }

  static (String?, String) _decodeChannelText(
    String text, {
    required bool parseSender,
  }) {
    final decodedText = Smaz.tryDecodePrefixed(text) ?? text;
    if (!parseSender) return (null, decodedText);

    final colonIndex = text.indexOf(':');
    if (colonIndex <= 0 || colonIndex >= text.length - 1 || colonIndex >= 50) {
      return (null, decodedText);
    }

    final potentialSender = text.substring(0, colonIndex);
    if (RegExp(r'[:\[\]]').hasMatch(potentialSender)) {
      return (null, decodedText);
    }

    final offset = (colonIndex + 1 < text.length && text[colonIndex + 1] == ' ')
        ? colonIndex + 2
        : colonIndex + 1;
    final body = text.substring(offset);
    final decodedBody = Smaz.tryDecodePrefixed(body) ?? body;
    return (potentialSender, decodedBody);
  }

  /// Parse TelemetryResponse push
  static Map<String, dynamic> parseTelemetryResponse(BufferReader reader) {
    reader.readByte(); // reserved
    final pubKeyPrefix = reader.readBytes(6);
    final lppSensorData = reader.readRemainingBytes();

    return {'publicKeyPrefix': pubKeyPrefix, 'lppSensorData': lppSensorData};
  }

  /// Parse BinaryResponse push
  static Map<String, dynamic> parseBinaryResponse(BufferReader reader) {
    reader.readByte(); // reserved
    final tag = reader.readUInt32LE();
    final responseData = reader.readRemainingBytes();

    return {
      'publicKeyPrefix': Uint8List(6), // Empty prefix
      'tag': tag,
      'responseData': responseData,
    };
  }

  /// Parse DeviceInfo response
  static Map<String, dynamic> parseDeviceInfo(BufferReader reader) {
    if (reader.remainingBytesCount < 1) {
      return {};
    }

    final firmwareVersion = reader.readByte();

    int? maxContacts;
    int? maxChannels;
    int? blePin;
    if (reader.remainingBytesCount >= 6) {
      final maxContactsDiv2 = reader.readByte();
      maxContacts = maxContactsDiv2 * 2;
      maxChannels = reader.readByte();
      blePin = reader.readUInt32LE();
    }

    String? firmwareBuildDate;
    if (reader.remainingBytesCount >= 12) {
      final buildDateBytes = reader.readBytes(12);
      firmwareBuildDate = String.fromCharCodes(
        buildDateBytes.takeWhile((b) => b != 0),
      );
    }

    String? manufacturerModel;
    if (reader.remainingBytesCount >= 40) {
      final modelBytes = reader.readBytes(40);
      manufacturerModel = String.fromCharCodes(
        modelBytes.takeWhile((b) => b != 0),
      );
    }

    String? semanticVersion;
    if (reader.remainingBytesCount >= 20) {
      final versionBytes = reader.readBytes(20);
      semanticVersion = String.fromCharCodes(
        versionBytes.takeWhile((b) => b != 0),
      );
    }

    bool? clientRepeat;
    if (reader.hasRemaining) {
      clientRepeat = reader.readByte() != 0;
    }

    int? pathHashMode;
    if (reader.hasRemaining) {
      pathHashMode = reader.readByte();
    }

    return {
      'firmwareVersion': firmwareVersion,
      'maxContacts': maxContacts,
      'maxChannels': maxChannels,
      'blePin': blePin,
      'firmwareBuildDate': firmwareBuildDate,
      'manufacturerModel': manufacturerModel,
      'semanticVersion': semanticVersion,
      'clientRepeat': clientRepeat,
      'pathHashMode': pathHashMode,
    };
  }

  /// Parse AllowedRepeatFreq response
  /// Returns list of frequency ranges as (lower, upper) pairs in kHz.
  static List<({int lower, int upper})> parseAllowedRepeatFreq(
    BufferReader reader,
  ) {
    final ranges = <({int lower, int upper})>[];
    while (reader.remainingBytesCount >= 8) {
      final lower = reader.readUInt32LE();
      final upper = reader.readUInt32LE();
      ranges.add((lower: lower, upper: upper));
    }
    return ranges;
  }

  /// Parse SelfInfo response
  static Map<String, dynamic> parseSelfInfo(BufferReader reader) {
    if (reader.remainingBytesCount < 54) {
      reader.readRemainingBytes();
      return {};
    }

    final deviceType = reader.readByte();
    final txPower = reader.readByte();
    final maxTxPower = reader.readByte();
    final publicKey = reader.readBytes(32);

    final advLatBytes = reader.readBytes(4);
    final advLat = ByteData.sublistView(
      Uint8List.fromList(advLatBytes),
    ).getInt32(0, Endian.little);

    final advLonBytes = reader.readBytes(4);
    final advLon = ByteData.sublistView(
      Uint8List.fromList(advLonBytes),
    ).getInt32(0, Endian.little);

    final multiAcks = reader.readByte();
    final advertLocPolicy = reader.readByte();
    final telemetryModes = reader.readByte();
    final manualAddContacts = reader.readByte();

    final radioFreqBytes = reader.readBytes(4);
    final radioFreq = ByteData.sublistView(
      Uint8List.fromList(radioFreqBytes),
    ).getUint32(0, Endian.little);

    final radioBwBytes = reader.readBytes(4);
    final radioBw = ByteData.sublistView(
      Uint8List.fromList(radioBwBytes),
    ).getUint32(0, Endian.little);

    final radioSf = reader.readByte();
    final radioCr = reader.readByte();

    String? selfName;
    if (reader.hasRemaining) {
      final nameBytes = reader.readRemainingBytes();
      selfName = utf8.decode(nameBytes.takeWhile((b) => b != 0).toList());
    }

    return {
      'deviceType': deviceType,
      'txPower': txPower,
      'maxTxPower': maxTxPower,
      'publicKey': publicKey,
      'advLat': advLat,
      'advLon': advLon,
      'multiAcks': multiAcks,
      'advertLocPolicy': advertLocPolicy,
      'telemetryModes': telemetryModes,
      'manualAddContacts': manualAddContacts == 1,
      'radioFreq': radioFreq,
      'radioBw': radioBw,
      'radioSf': radioSf,
      'radioCr': radioCr,
      'selfName': selfName,
    };
  }

  static Map<String, dynamic> parseAutoaddConfig(BufferReader reader) {
    final flags = reader.readByte();
    final maxHops = reader.hasRemaining ? reader.readByte() : 0;
    return {
      'autoAddUsers': (flags & 0x02) != 0,
      'autoAddRepeaters': (flags & 0x04) != 0,
      'autoAddRoomServers': (flags & 0x08) != 0,
      'autoAddSensors': (flags & 0x10) != 0,
      'autoAddOverwriteOldest': (flags & 0x01) != 0,
      'autoAddMaxHops': maxHops,
    };
  }

  /// Parse Advert push
  static Uint8List? parseAdvert(BufferReader reader) {
    if (reader.remainingBytesCount >= 32) {
      return reader.readBytes(32);
    }
    return null;
  }

  /// Parse PathUpdated push
  static Uint8List? parsePathUpdated(BufferReader reader) {
    if (reader.remainingBytesCount >= 32) {
      return reader.readBytes(32);
    }
    return null;
  }

  /// Parse SendConfirmed push
  static Map<String, dynamic> parseSendConfirmed(BufferReader reader) {
    if (reader.remainingBytesCount >= 8) {
      final ackCodeBytes = reader.readBytes(4);
      final ackCode = ByteData.sublistView(
        Uint8List.fromList(ackCodeBytes),
      ).getUint32(0, Endian.little);
      final roundTripTime = reader.readUInt32LE();

      return {'ackCode': ackCode, 'roundTripTime': roundTripTime};
    }
    return {};
  }

  /// Parse LoginSuccess push
  static Map<String, dynamic> parseLoginSuccess(BufferReader reader) {
    if (reader.remainingBytesCount >= 11) {
      final permissions = reader.readByte();
      final isAdmin = (permissions & 0x01) != 0;
      final publicKeyPrefix = reader.readBytes(6);
      final tag = reader.readInt32LE();

      int? newPermissions;
      if (reader.hasRemaining) {
        newPermissions = reader.readByte();
      }

      return {
        'publicKeyPrefix': publicKeyPrefix,
        'permissions': permissions,
        'isAdmin': isAdmin,
        'tag': tag,
        'newPermissions': newPermissions,
      };
    }
    return {};
  }

  /// Parse LoginFail push
  static Uint8List? parseLoginFail(BufferReader reader) {
    if (reader.remainingBytesCount >= 7) {
      reader.readByte(); // reserved
      return reader.readBytes(6);
    }
    return null;
  }

  /// Parse StatusResponse push
  static Map<String, dynamic> parseStatusResponse(BufferReader reader) {
    if (reader.remainingBytesCount >= 7) {
      reader.readByte(); // reserved
      final publicKeyPrefix = reader.readBytes(6);
      final statusData = reader.readRemainingBytes();

      return {'publicKeyPrefix': publicKeyPrefix, 'statusData': statusData};
    }
    return {};
  }

  /// Parse CurrentTime response
  static int? parseCurrentTime(BufferReader reader) {
    if (reader.remainingBytesCount >= 4) {
      return reader.readUInt32LE();
    }
    return null;
  }

  /// Parse BatteryAndStorage response
  static Map<String, dynamic> parseBatteryAndStorage(BufferReader reader) {
    if (reader.remainingBytesCount >= 2) {
      final millivolts = reader.readUInt16LE();

      int? usedKb;
      int? totalKb;

      if (reader.remainingBytesCount >= 8) {
        usedKb = reader.readUInt32LE();
        totalKb = reader.readUInt32LE();
      } else if (reader.remainingBytesCount >= 4) {
        usedKb = reader.readUInt32LE();
      }

      return {'millivolts': millivolts, 'usedKb': usedKb, 'totalKb': totalKb};
    }
    return {};
  }

  /// Parse Error response
  static int? parseError(BufferReader reader) {
    if (reader.hasRemaining) {
      return reader.readByte();
    }
    return null;
  }

  /// Parse ChannelInfo response
  static Map<String, dynamic> parseChannelInfo(BufferReader reader) {
    // Format: [channel_idx(1)][name(32)][secret(16)][flags(1)?]
    // Minimum: 1 + 32 + 16 = 49 bytes (flags is optional)
    if (reader.remainingBytesCount < 49) {
      return {};
    }

    final channelIdx = reader.readByte();
    final channelName = reader.readCString(32);
    final secret = reader.readBytes(16);

    // Flags field is optional (some firmware versions don't include it)
    int? flags;
    if (reader.remainingBytesCount >= 1) {
      flags = reader.readByte();
    }

    return {
      'channelIdx': channelIdx,
      'channelName': channelName,
      'secret': secret,
      'flags': flags,
    };
  }

  /// Get error message from error code
  static String getErrorMessage(int errorCode) {
    switch (errorCode) {
      case MeshCoreConstants.errUnsupportedCmd:
        return 'Unsupported command';
      case MeshCoreConstants.errNotFound:
        return 'Not found';
      case MeshCoreConstants.errTableFull:
        return 'Table full';
      case MeshCoreConstants.errBadState:
        return 'Bad state';
      case MeshCoreConstants.errFileIoError:
        return 'File I/O error';
      case MeshCoreConstants.errIllegalArg:
        return 'Illegal argument';
      default:
        return 'Error code: $errorCode';
    }
  }
}
