import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/music_models.dart';
import 'audio_file_format.dart';
import 'flac_tag_writer.dart';
import 'id3_tag_writer.dart';

class DownloadMetadataResult {
  const DownloadMetadataResult({
    required this.tagsWritten,
    required this.lyricsEmbedded,
    required this.sidecarWritten,
  });

  final bool tagsWritten;
  final bool lyricsEmbedded;
  final bool sidecarWritten;
}

/// Finalize user downloads before publishing them in the download index.
class DownloadMetadataWriter {
  static Future<DownloadMetadataResult> write({
    required String filePath,
    required Song song,
    String? lyricsText,
    bool saveLyricsFile = false,
    Uint8List? coverBytes,
  }) async {
    var tagsWritten = false;
    var effectiveSong = song;
    var effectiveLyrics = lyricsText;
    Uint8List? cover = coverBytes;
    try {
      final format = await inspectAudioFile(filePath);
      if (format.format != AudioFileFormat.unsupported &&
          cover == null &&
          song.coverUrl?.isNotEmpty == true) {
        try {
          final response = await http
              .get(Uri.parse(song.coverUrl!))
              .timeout(const Duration(seconds: 4));
          if (response.statusCode == 200) cover = response.bodyBytes;
        } catch (_) {
          // Cover availability must not suppress tags or lyrics.
        }
      }
      if (cover != null && !_isCoverImage(cover)) cover = null;
      // Keep useful tags supplied in the audio file when enrichment is offline.
      // Reading pictures/lyrics in an isolate avoids blocking the UI on file IO.
      if (effectiveLyrics?.trim().isNotEmpty != true ||
          cover == null ||
          effectiveSong.albumName?.isNotEmpty != true) {
        try {
          final original = await Isolate.run(() {
            final tags = readMetadata(File(filePath), getImage: true);
            return (
              album: tags.album,
              lyrics: tags.lyrics,
              cover: tags.pictures.isEmpty ? null : tags.pictures.first.bytes,
            );
          });
          if (effectiveLyrics?.trim().isNotEmpty != true) {
            effectiveLyrics = original.lyrics;
          }
          cover ??= original.cover;
          if (cover != null && !_isCoverImage(cover)) cover = null;
          if (effectiveSong.albumName?.isNotEmpty != true &&
              original.album?.isNotEmpty == true) {
            effectiveSong = Song(
              id: song.id,
              title: song.title,
              artist: song.artist,
              hash: song.hash,
              albumName: original.album,
              albumId: song.albumId,
              albumAudioId: song.albumAudioId,
              coverUrl: song.coverUrl,
              duration: song.duration,
              releaseDate: song.releaseDate,
              artists: song.artists,
              source: song.source,
              isCloudDrive: song.isCloudDrive,
            );
          }
        } catch (_) {
          // A missing or malformed existing tag does not block writing new ones.
        }
      }
      switch (format.format) {
        case AudioFileFormat.mp3:
          tagsWritten = await Id3TagWriter.injectMetadata(
            filePath: filePath,
            song: effectiveSong,
            coverBytes: cover,
            lyricsText: effectiveLyrics,
            fetchCover: false,
          );
        case AudioFileFormat.flac:
          tagsWritten = await FlacTagWriter.injectMetadata(
            filePath: filePath,
            song: effectiveSong,
            coverBytes: cover,
            lyricsText: effectiveLyrics,
          );
        case AudioFileFormat.unsupported:
          // Keep AAC, APE, WAV, etc. intact; LRC remains usable beside them.
          break;
      }
    } catch (error) {
      debugPrint('[Download] Could not embed metadata: $error');
    }

    final hasLyrics = effectiveLyrics?.trim().isNotEmpty == true;
    var sidecarWritten = false;
    if (hasLyrics && (saveLyricsFile || !tagsWritten)) {
      final sidecar = File(lyricsFilePath(filePath));
      final temporary = File('${sidecar.path}.tmp');
      try {
        await temporary.writeAsString(
          effectiveLyrics!,
          encoding: utf8,
          flush: true,
        );
        await temporary.rename(sidecar.path);
        sidecarWritten = true;
      } catch (error) {
        debugPrint('[Download] Could not save LRC: $error');
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }
    return DownloadMetadataResult(
      tagsWritten: tagsWritten,
      lyricsEmbedded: hasLyrics && tagsWritten,
      sidecarWritten: sidecarWritten,
    );
  }

  static String lyricsFilePath(String filePath) {
    final slash = filePath.lastIndexOf(RegExp(r'[/\\]'));
    final dot = filePath.lastIndexOf('.');
    final stem = dot > slash ? filePath.substring(0, dot) : filePath;
    return '$stem.lrc';
  }

  static bool _isCoverImage(Uint8List bytes) =>
      (bytes.length >= 24 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0d &&
          bytes[5] == 0x0a &&
          bytes[6] == 0x1a &&
          bytes[7] == 0x0a) ||
      (bytes.length >= 4 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff);
}

/// Keep timestamps (including hour-long tracks) and translations in exported LRC.
String downloadLyricsText(List<LyricLine> lyrics) {
  final lines = <String>[];
  for (final line in lyrics) {
    final ms = line.time.inMilliseconds < 0 ? 0 : line.time.inMilliseconds;
    final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
    final centiseconds = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
    final stamp = '[$minutes:$seconds.$centiseconds]';
    for (final text in [line.text, line.translation]) {
      if (text == null || text.trim().isEmpty) continue;
      lines.add('$stamp${text.replaceAll(RegExp(r'[\r\n]+'), ' ')}');
    }
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}
