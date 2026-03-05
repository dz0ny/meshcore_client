import 'dart:convert';
import 'dart:typed_data';

class Smaz {
  static const int _verbatimSingle = 254;
  static const int _verbatimRun = 255;

  static const List<String> _rcb = [
    " ",
    "the",
    "e",
    "t",
    "a",
    "of",
    "o",
    "and",
    "i",
    "n",
    "s",
    "e ",
    "r",
    " th",
    " t",
    "in",
    "he",
    "th",
    "h",
    "he ",
    "to",
    "\r\n",
    "l",
    "s ",
    "d",
    " a",
    "an",
    "er",
    "c",
    " o",
    "d ",
    "on",
    " of",
    "re",
    "of ",
    "t ",
    ", ",
    "is",
    "u",
    "at",
    "   ",
    "n ",
    "or",
    "which",
    "f",
    "m",
    "as",
    "it",
    "that",
    "\n",
    "was",
    "en",
    "  ",
    " w",
    "es",
    " an",
    " i",
    "\r",
    "f ",
    "g",
    "p",
    "nd",
    " s",
    "nd ",
    "ed ",
    "w",
    "ed",
    "http://",
    "for",
    "te",
    "ing",
    "y ",
    "The",
    " c",
    "ti",
    "r ",
    "his",
    "st",
    " in",
    "ar",
    "nt",
    ",",
    " to",
    "y",
    "ng",
    " h",
    "with",
    "le",
    "al",
    "to ",
    "b",
    "ou",
    "be",
    "were",
    " b",
    "se",
    "o ",
    "ent",
    "ha",
    "ng ",
    "their",
    "\"",
    "hi",
    "from",
    " f",
    "in ",
    "de",
    "ion",
    "me",
    "v",
    ".",
    "ve",
    "all",
    "re ",
    "ri",
    "ro",
    "is ",
    "co",
    "f t",
    "are",
    "ea",
    ". ",
    "her",
    " m",
    "er ",
    " p",
    "es ",
    "by",
    "they",
    "di",
    "ra",
    "ic",
    "not",
    "s, ",
    "d t",
    "at ",
    "ce",
    "la",
    "h ",
    "ne",
    "as ",
    "tio",
    "on ",
    "n t",
    "io",
    "we",
    " a ",
    "om",
    ", a",
    "s o",
    "ur",
    "li",
    "ll",
    "ch",
    "had",
    "this",
    "e t",
    "g ",
    "e\r\n",
    " wh",
    "ere",
    " co",
    "e o",
    "a ",
    "us",
    " d",
    "ss",
    "\n\r\n",
    "\r\n\r",
    "=\"",
    " be",
    " e",
    "s a",
    "ma",
    "one",
    "t t",
    "or ",
    "but",
    "el",
    "so",
    "l ",
    "e s",
    "s,",
    "no",
    "ter",
    " wa",
    "iv",
    "ho",
    "e a",
    " r",
    "hat",
    "s t",
    "ns",
    "ch ",
    "wh",
    "tr",
    "ut",
    "/",
    "have",
    "ly ",
    "ta",
    " ha",
    " on",
    "tha",
    "-",
    " l",
    "ati",
    "en ",
    "pe",
    " re",
    "there",
    "ass",
    "si",
    " fo",
    "wa",
    "ec",
    "our",
    "who",
    "its",
    "z",
    "fo",
    "rs",
    ">",
    "ot",
    "un",
    "<",
    "im",
    "th ",
    "nc",
    "ate",
    "><",
    "ver",
    "ad",
    " we",
    "ly",
    "ee",
    " n",
    "id",
    " cl",
    "ac",
    "il",
    "</",
    "rt",
    " wi",
    "div",
    "e, ",
    " it",
    "whi",
    " ma",
    "ge",
    "x",
    "e c",
    "men",
    ".com",
  ];

  static final List<Uint8List> _rcbBytes = _rcb
      .map((s) => Uint8List.fromList(ascii.encode(s)))
      .toList(growable: false);

  static String? tryDecodePrefixed(String text) {
    final trimmedLeft = text.trimLeft();
    if (!trimmedLeft.startsWith('s:') || trimmedLeft.length <= 2) return null;
    final encoded = trimmedLeft.substring(2);
    try {
      final compressed = _decodeBase64Flexible(encoded);
      final decompressed = decompressBytes(compressed);
      return utf8.decode(decompressed, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static Uint8List decompressBytes(Uint8List input) {
    final out = BytesBuilder(copy: false);
    int index = 0;

    while (index < input.length) {
      final code = input[index];
      if (code == _verbatimSingle) {
        if (index + 1 >= input.length) {
          throw const FormatException(
            'Invalid SMAZ stream: truncated verbatim byte.',
          );
        }
        out.addByte(input[index + 1]);
        index += 2;
      } else if (code == _verbatimRun) {
        if (index + 1 >= input.length) {
          throw const FormatException(
            'Invalid SMAZ stream: truncated verbatim length.',
          );
        }
        final len = input[index + 1] + 1;
        final end = index + 2 + len;
        if (end > input.length) {
          throw const FormatException(
            'Invalid SMAZ stream: truncated verbatim run.',
          );
        }
        out.add(input.sublist(index + 2, end));
        index = end;
      } else {
        if (code >= _rcbBytes.length) {
          throw const FormatException(
            'Invalid SMAZ stream: code out of range.',
          );
        }
        out.add(_rcbBytes[code]);
        index += 1;
      }
    }

    return out.toBytes();
  }

  static Uint8List _decodeBase64Flexible(String encoded) {
    final trimmed = encoded.trim();
    try {
      return base64Decode(trimmed);
    } catch (_) {
      var normalized = trimmed.replaceAll('-', '+').replaceAll('_', '/');
      final pad = normalized.length % 4;
      if (pad != 0) {
        normalized = normalized.padRight(normalized.length + (4 - pad), '=');
      }
      return base64Decode(normalized);
    }
  }
}
