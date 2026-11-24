import 'dart:convert';
import 'dart:typed_data';

import '../models/music_models.dart';

/// Default name for the TXT file in the system save dialog.
String playlistExportFileName(String title) {
  final stem = title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (stem.isEmpty) return '歌单.txt';
  // Keep even non-ASCII names within the common 255-byte filename limit.
  return '歌单 - ${String.fromCharCodes(stem.runes.take(60))}.txt';
}

/// UTF-8 text with tab-separated fields, one row per track in playlist order.
Uint8List encodePlaylistExport(Iterable<Song> songs) {
  final text = StringBuffer('序号\t歌名\t歌手\t时长\r\n');
  var index = 0;
  for (final song in songs) {
    text
      ..write(++index)
      ..write('\t${_escapeField(song.title)}')
      ..write('\t${_escapeField(song.artist)}')
      ..write('\t${_formatDuration(song.duration)}\r\n');
  }
  return utf8.encode(text.toString());
}

String _escapeField(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('\t', r'\t')
    .replaceAll('\r', r'\r')
    .replaceAll('\n', r'\n');

String _formatDuration(Duration? duration) {
  if (duration == null || duration.isNegative) return '--:--';
  final hours = duration.inHours;
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  final time = hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  final milliseconds = duration.inMilliseconds % 1000;
  return milliseconds == 0
      ? time
      : '$time.${milliseconds.toString().padLeft(3, '0')}';
}
