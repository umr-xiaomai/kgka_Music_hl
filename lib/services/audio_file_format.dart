import 'dart:io';

enum AudioFileFormat { mp3, flac, unsupported }

/// Identify the bytes, since an unavailable quality can fall back to a different
/// codec while the download still has the requested quality's extension.
Future<({AudioFileFormat format, int offset})> inspectAudioFile(
  String path,
) async {
  final reader = await File(path).open();
  try {
    final length = await reader.length();
    var offset = 0;
    while (offset + 10 <= length) {
      await reader.setPosition(offset);
      final header = await reader.read(10);
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        break;
      }
      if (header[3] < 2 ||
          header[3] > 4 ||
          header.skip(6).any((byte) => byte > 0x7f)) {
        return (format: AudioFileFormat.unsupported, offset: 0);
      }
      final size =
          (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
      offset += 10 + size;
      if (header[3] == 4 && header[5] & 0x10 != 0) offset += 10;
    }
    if (offset + 4 > length) {
      return (format: AudioFileFormat.unsupported, offset: 0);
    }
    await reader.setPosition(offset);
    final signature = await reader.read(4);
    if (signature[0] == 0x66 &&
        signature[1] == 0x4c &&
        signature[2] == 0x61 &&
        signature[3] == 0x43) {
      return (format: AudioFileFormat.flac, offset: offset);
    }
    // MPEG audio frame sync; exclude the AAC ADTS layer value (00).
    if (signature[0] == 0xff &&
        signature[1] & 0xe0 == 0xe0 &&
        signature[1] & 0x06 != 0 &&
        signature[1] & 0x18 != 0x08 &&
        signature[2] & 0xf0 != 0xf0 &&
        signature[2] & 0x0c != 0x0c) {
      return (format: AudioFileFormat.mp3, offset: offset);
    }
    return (format: AudioFileFormat.unsupported, offset: 0);
  } finally {
    await reader.close();
  }
}
