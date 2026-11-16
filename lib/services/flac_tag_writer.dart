import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/music_models.dart';
import 'audio_file_format.dart';

typedef _Block = ({int type, Uint8List bytes});

/// FLAC uses UTF-8 Vorbis comments and PICTURE blocks, never an ID3 prefix.
class FlacTagWriter {
  static Future<bool> injectMetadata({
    required String filePath,
    required Song song,
    Uint8List? coverBytes,
    String? lyricsText,
  }) async {
    final temporary = File('$filePath.tag.tmp');
    try {
      final format = await inspectAudioFile(filePath);
      if (format.format != AudioFileFormat.flac) return false;
      final file = File(filePath);
      final reader = await file.open();
      final blocks = <_Block>[];
      late int audioOffset;
      try {
        final fileLength = await reader.length();
        await reader.setPosition(format.offset + 4);
        var last = false;
        while (!last) {
          if (await reader.position() + 4 > fileLength) {
            throw const FormatException('Truncated FLAC metadata header');
          }
          final header = await reader.read(4);
          last = header[0] & 0x80 != 0;
          final type = header[0] & 0x7f;
          final length = (header[1] << 16) | (header[2] << 8) | header[3];
          if (type == 127 ||
              await reader.position() + length > fileLength ||
              blocks.length >= 1024) {
            throw const FormatException('Invalid FLAC metadata block');
          }
          blocks.add((type: type, bytes: await reader.read(length)));
        }
        audioOffset = await reader.position();
      } finally {
        await reader.close();
      }
      if (blocks.isEmpty ||
          blocks.first.type != 0 ||
          blocks.first.bytes.length != 34) {
        throw const FormatException('FLAC STREAMINFO must be first');
      }

      final replacements = <String, String>{
        if (song.title.isNotEmpty) 'TITLE': song.title,
        if (song.artist.isNotEmpty) 'ARTIST': song.artist,
        if (song.albumName?.isNotEmpty == true) 'ALBUM': song.albumName!,
        if (lyricsText?.isNotEmpty == true) 'LYRICS': lyricsText!,
      };
      var vendor = 'KA Music';
      final comments = <String>[];
      for (final block in blocks.where((block) => block.type == 4)) {
        final original = _readComments(block.bytes);
        vendor = original.vendor;
        comments.addAll(
          original.comments.where((comment) {
            final key = comment.split('=').first.toUpperCase();
            return !replacements.containsKey(key) &&
                !(replacements.containsKey('LYRICS') &&
                    (key == 'UNSYNCEDLYRICS' || key == 'LYRIC'));
          }),
        );
      }
      comments.addAll(
        replacements.entries.map((entry) => '${entry.key}=${entry.value}'),
      );
      final newBlocks = <_Block>[
        blocks.first,
        (type: 4, bytes: _writeComments(vendor, comments)),
        for (final block in blocks.skip(1))
          if (block.type != 4 &&
              !(coverBytes != null &&
                  block.type == 6 &&
                  block.bytes.length >= 4 &&
                  ByteData.sublistView(block.bytes).getUint32(0) == 3))
            block,
        if (coverBytes != null) (type: 6, bytes: _writePicture(coverBytes)),
      ];
      final sink = temporary.openWrite();
      try {
        sink.add(ascii.encode('fLaC'));
        for (var index = 0; index < newBlocks.length; index++) {
          final block = newBlocks[index];
          final length = block.bytes.length;
          if (length > 0xffffff) {
            throw const FormatException('FLAC metadata block too large');
          }
          sink.add([
            block.type | (index == newBlocks.length - 1 ? 0x80 : 0),
            (length >> 16) & 0xff,
            (length >> 8) & 0xff,
            length & 0xff,
          ]);
          sink.add(block.bytes);
        }
        // Stream the audio frames unchanged, including large lossless files.
        await sink.addStream(file.openRead(audioOffset));
        await sink.flush();
      } finally {
        await sink.close();
      }
      await temporary.rename(filePath);
      return true;
    } catch (error) {
      debugPrint('[FlacTagWriter] Could not write metadata: $error');
      return false;
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
  }

  static ({String vendor, List<String> comments}) _readComments(
    Uint8List bytes,
  ) {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    int readLength() {
      if (offset + 4 > bytes.length) {
        throw const FormatException('Invalid comments');
      }
      final length = data.getUint32(offset, Endian.little);
      offset += 4;
      return length;
    }

    String readString() {
      final length = readLength();
      if (offset + length > bytes.length) {
        throw const FormatException('Invalid comment length');
      }
      // Invalid legacy text must not prevent replacing a broken album tag.
      final text = utf8.decode(
        bytes.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      return text;
    }

    final vendor = readString();
    final count = readLength();
    if (count > (bytes.length - offset) ~/ 4) {
      throw const FormatException('Invalid comment count');
    }
    return (
      vendor: vendor,
      comments: [for (var i = 0; i < count; i++) readString()],
    );
  }

  static Uint8List _writeComments(String vendor, List<String> comments) {
    final builder = BytesBuilder();
    void addString(String value) {
      final encoded = utf8.encode(value);
      builder.add(_uint32(encoded.length, Endian.little));
      builder.add(encoded);
    }

    addString(vendor);
    builder.add(_uint32(comments.length, Endian.little));
    for (final comment in comments) {
      addString(comment);
    }
    return builder.takeBytes();
  }

  static Uint8List _writePicture(Uint8List bytes) {
    final png = bytes.length >= 24 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final mime = ascii.encode(png ? 'image/png' : 'image/jpeg');
    final builder = BytesBuilder();
    builder.add(_uint32(3)); // Front cover.
    builder.add(_uint32(mime.length));
    builder.add(mime);
    builder.add(_uint32(0)); // Empty description.
    final dimensions = _pictureDimensions(bytes, png: png);
    builder.add(_uint32(dimensions.width));
    builder.add(_uint32(dimensions.height));
    builder.add(_uint32(dimensions.depth));
    builder.add(_uint32(dimensions.colors));
    builder.add(_uint32(bytes.length));
    builder.add(bytes);
    return builder.takeBytes();
  }

  static ({int width, int height, int depth, int colors}) _pictureDimensions(
    Uint8List bytes, {
    required bool png,
  }) {
    final data = ByteData.sublistView(bytes);
    if (png) {
      final colorType = bytes.length > 25 ? bytes[25] : 0;
      final channels = switch (colorType) {
        2 => 3,
        4 => 2,
        6 => 4,
        _ => 1,
      };
      final bits = bytes.length > 24 ? bytes[24] : 0;
      return (
        width: data.getUint32(16),
        height: data.getUint32(20),
        depth: bits * channels,
        colors: colorType == 3 ? 1 << bits : 0,
      );
    }
    // JPEG dimensions live in a Start Of Frame marker, after optional APP/EXIF
    // segments. Include them for players that validate FLAC PICTURE headers.
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset++] != 0xff) break;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd9 || marker == 0xda) break;
      if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd8) continue;
      if (offset + 2 > bytes.length) break;
      final length = data.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc &&
          length >= 8) {
        return (
          width: data.getUint16(offset + 5),
          height: data.getUint16(offset + 3),
          depth: bytes[offset + 2] * bytes[offset + 7],
          colors: 0,
        );
      }
      offset += length;
    }
    return (width: 0, height: 0, depth: 0, colors: 0);
  }

  static Uint8List _uint32(int value, [Endian endian = Endian.big]) =>
      (ByteData(4)..setUint32(0, value, endian)).buffer.asUint8List();
}
