import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/music_models.dart';
import 'audio_file_format.dart';

/// 为下载的音频文件（MP3）注入标准 ID3v2.3 标签（歌曲名、歌手、专辑、封面图片及内嵌歌词）。
class Id3TagWriter {
  /// 向目标 MP3 文件写入 ID3v2.3 元数据。
  static Future<bool> injectMetadata({
    required String filePath,
    required Song song,
    Uint8List? coverBytes,
    String? lyricsText,
    bool fetchCover = true,
  }) async {
    final file = File(filePath);
    final tmpFile = File('$filePath.tag.tmp');
    if (!await file.exists()) {
      return false;
    }

    try {
      // Never prepend ID3 to FLAC/AAC bytes, even when named .mp3 by a quality
      // fallback. The container-specific writer must handle those instead.
      final format = await inspectAudioFile(filePath);
      if (format.format != AudioFileFormat.mp3) return false;
      Uint8List? imageBytes = coverBytes;
      if (fetchCover &&
          imageBytes == null &&
          song.coverUrl != null &&
          song.coverUrl!.isNotEmpty) {
        imageBytes = await _downloadCover(song.coverUrl!);
      }

      final frames = <int>[];

      // TIT2: 歌曲名
      if (song.title.isNotEmpty) {
        frames.addAll(_buildTextFrame('TIT2', song.title));
      }

      // TPE1: 歌手
      if (song.artist.isNotEmpty) {
        frames.addAll(_buildTextFrame('TPE1', song.artist));
      }

      // TALB: 专辑
      if (song.albumName != null && song.albumName!.isNotEmpty) {
        frames.addAll(_buildTextFrame('TALB', song.albumName!));
      }

      // APIC: 封面图片
      if (imageBytes != null && imageBytes.isNotEmpty) {
        frames.addAll(_buildApicFrame(imageBytes));
      }

      // USLT: 内嵌歌词
      if (lyricsText != null && lyricsText.isNotEmpty) {
        frames.addAll(_buildUsltFrame(lyricsText));
      }

      if (frames.isEmpty) {
        return false;
      }

      // 组装 ID3v2.3 头部（10 字节）
      final header = _buildId3Header(frames.length);
      final newTagBytes = Uint8List.fromList([...header, ...frames]);

      // 读取原文件并跳过可能存在的旧 ID3v2 标签
      final sourceBytes = await file.readAsBytes();
      final audioOffset = format.offset;
      // ID3v1 has no Unicode encoding marker; stale GBK/Latin-1 album names in
      // that trailer can override the new Unicode tags in other music players.
      var audioEnd = sourceBytes.length;
      if (audioEnd - audioOffset >= 128 &&
          ascii.decode(
                sourceBytes.sublist(audioEnd - 128, audioEnd - 125),
                allowInvalid: true,
              ) ==
              'TAG') {
        audioEnd -= 128;
      }

      // 写入临时文件后重命名
      final sink = tmpFile.openWrite();
      try {
        sink.add(newTagBytes);
        sink.add(sourceBytes.sublist(audioOffset, audioEnd));
        await sink.flush();
      } finally {
        await sink.close();
      }

      await tmpFile.rename(filePath);
      return true;
    } catch (e) {
      debugPrint('[Id3TagWriter] Failed to write ID3 tag: $e');
      return false;
    } finally {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
    }
  }

  /// 构建 ID3v2.3 头部（10 字节）。
  static List<int> _buildId3Header(int framesLength) {
    return [
      0x49, 0x44, 0x33, // 'ID3'
      0x03, 0x00, // Version 2.3
      0x00, // Flags
      (framesLength >> 21) & 0x7F,
      (framesLength >> 14) & 0x7F,
      (framesLength >> 7) & 0x7F,
      framesLength & 0x7F,
    ];
  }

  /// 构建通用文本帧（UTF-16LE with BOM 编码，ID3v2.3 标准支持）。
  static List<int> _buildTextFrame(String frameId, String text) {
    final utf16Bytes = _encodeUtf16LeWithBom(text);
    // 编码标识字节 0x01 (UTF-16 with BOM) + 内容
    final payload = [0x01, ...utf16Bytes];
    return _packFrame(frameId, payload);
  }

  /// 构建 APIC 封面图片帧。
  static List<int> _buildApicFrame(Uint8List imageBytes) {
    final isPng =
        imageBytes.length >= 8 &&
        imageBytes[0] == 0x89 &&
        imageBytes[1] == 0x50 &&
        imageBytes[2] == 0x4E &&
        imageBytes[3] == 0x47;
    final mimeType = isPng ? 'image/png' : 'image/jpeg';
    final mimeBytes = ascii.encode(mimeType);

    final payload = <int>[
      0x00, // 0x00: ISO-8859-1 for MIME and description
      ...mimeBytes, 0x00, // MIME + null terminator
      0x03, // Picture type: Cover (front)
      0x00, // Description: empty + null terminator
      ...imageBytes,
    ];

    return _packFrame('APIC', payload);
  }

  /// 构建 USLT 内嵌非同步歌词帧。
  static List<int> _buildUsltFrame(String lyrics) {
    final utf16Lyrics = _encodeUtf16LeWithBom(lyrics);
    final payload = <int>[
      0x01, // UTF-16 with BOM
      0x7A, 0x68, 0x6F, // Language: 'zho'
      0xFF, 0xFE, 0x00, 0x00, // Empty descriptor (BOM + UTF-16 null)
      ...utf16Lyrics,
    ];

    return _packFrame('USLT', payload);
  }

  /// 打包 ID3v2 帧：[4 字节 ID] + [4 字节大小] + [2 字节标志] + [负载数据]。
  static List<int> _packFrame(String frameId, List<int> payload) {
    final idBytes = ascii.encode(frameId);
    final size = payload.length;
    return [
      ...idBytes,
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      0x00, 0x00, // Flags
      ...payload,
    ];
  }

  /// 将字符串编码为 UTF-16LE 字节流（开头含 0xFF 0xFE BOM）。
  static List<int> _encodeUtf16LeWithBom(String text) {
    final bytes = <int>[0xFF, 0xFE]; // BOM (Little Endian)
    for (final unit in text.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return bytes;
  }

  /// 超时下载网络封面图。
  static Future<Uint8List?> _downloadCover(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
    } catch (_) {}
    return null;
  }
}
