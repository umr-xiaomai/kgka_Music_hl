import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/audio_file_format.dart';
import 'package:kgka_music_hl/services/download_metadata_writer.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/id3_tag_writer.dart';

const song = Song(
  id: 'test',
  hash: 'hash',
  title: '晴天 ☀️',
  artist: '周杰伦',
  albumName: '叶惠美・紀念版',
);
const lrc = '[00:01.25]故事的小黄花\n[00:02.00]从出生那年就飘着\n';
final cover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8l8AAAAASUVORK5CYII=',
);

class _DirectoryDownloadService extends DownloadService {
  _DirectoryDownloadService(this.directory);
  final Directory directory;

  @override
  Future<Directory> downloadDir() async => directory;
}

({List<({int type, Uint8List bytes})> blocks, Uint8List audio}) flacParts(
  Uint8List bytes,
) {
  var offset = 4;
  final blocks = <({int type, Uint8List bytes})>[];
  var last = false;
  while (!last) {
    last = bytes[offset] & 0x80 != 0;
    final length =
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    blocks.add((
      type: bytes[offset] & 0x7f,
      bytes: bytes.sublist(offset + 4, offset + 4 + length),
    ));
    offset += 4 + length;
  }
  return (blocks: blocks, audio: bytes.sublist(offset));
}

void main() {
  late Directory temporary;
  setUp(
    () async =>
        temporary = await Directory.systemTemp.createTemp('download_metadata_'),
  );
  tearDown(() async => temporary.delete(recursive: true));

  for (final extension in ['mp3', 'flac']) {
    test(
      'download extension follows actual $extension bytes after quality fallback',
      () async {
        final bytes = await File(
          'test/fixtures/lyrics.$extension',
        ).readAsBytes();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        final service = _DirectoryDownloadService(temporary);
        addTearDown(service.dispose);
        final path = await service.download(
          song: song,
          quality: extension == 'mp3'
              ? AudioQuality.lossless
              : AudioQuality.standard,
          url: 'http://127.0.0.1:${server.port}/audio',
          onProgress: (_, _) {},
        );
        expect(path, endsWith('.$extension'));
        expect(await File(path).readAsBytes(), bytes);
      },
    );

    test(
      '$extension round trips Unicode album, timed lyrics and front cover',
      () async {
        final audio = await File(
          'test/fixtures/lyrics.$extension',
        ).copy('${temporary.path}/song.$extension');
        final before = await audio.readAsBytes();
        final result = await DownloadMetadataWriter.write(
          filePath: audio.path,
          song: song,
          lyricsText: lrc,
          coverBytes: cover,
        );
        expect(result.tagsWritten, isTrue);
        expect(result.lyricsEmbedded, isTrue);
        expect(result.sidecarWritten, isFalse);
        final metadata = readMetadata(audio, getImage: true);
        expect(metadata.title, song.title);
        expect(metadata.artist, song.artist);
        expect(metadata.album, song.albumName);
        expect(metadata.lyrics, lrc);
        expect(metadata.pictures.single.bytes, cover);
        expect(metadata.pictures.single.mimetype, 'image/png');
        if (extension == 'flac') {
          final after = flacParts(await audio.readAsBytes());
          final original = flacParts(before);
          expect(after.audio, original.audio);
          expect(after.blocks.first.bytes, original.blocks.first.bytes);
          for (final block in original.blocks.where(
            (block) => block.type != 4 && block.type != 6,
          )) {
            expect(
              after.blocks.any(
                (other) =>
                    other.type == block.type &&
                    listEquals(other.bytes, block.bytes),
              ),
              isTrue,
            );
          }
        } else {
          final beforeFile = File('${temporary.path}/before.mp3');
          await beforeFile.writeAsBytes(before);
          final beforeOffset = (await inspectAudioFile(beforeFile.path)).offset;
          final afterOffset = (await inspectAudioFile(audio.path)).offset;
          expect(
            (await audio.readAsBytes()).sublist(afterOffset),
            before.sublist(beforeOffset),
          );
        }
      },
    );
  }

  test(
    'offline enrichment preserves original album, lyrics and cover in MP3',
    () async {
      final audio = await File(
        'test/fixtures/lyrics.mp3',
      ).copy('${temporary.path}/offline.mp3');
      await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: song,
        lyricsText: lrc,
        coverBytes: cover,
      );
      final result = await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: const Song(id: 'test', hash: 'hash', title: '新标题', artist: '歌手'),
        saveLyricsFile: true,
      );
      expect(result.lyricsEmbedded, isTrue);
      final tags = readMetadata(audio, getImage: true);
      expect(tags.title, '新标题');
      expect(tags.album, song.albumName);
      expect(tags.lyrics, lrc);
      expect(tags.pictures.single.bytes, cover);
      expect(await File('${temporary.path}/offline.lrc').readAsString(), lrc);
    },
  );

  test(
    'FLAC re-tagging preserves unrelated comments and does not duplicate pictures',
    () async {
      final audio = await File(
        'test/fixtures/lyrics.flac',
      ).copy('${temporary.path}/song.flac');
      final original = readAllMetadata(audio, getImage: true) as VorbisMetadata;
      await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: song,
        lyricsText: lrc,
        coverBytes: cover,
      );
      await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: song,
        lyricsText: lrc,
        coverBytes: cover,
      );
      final tags = readAllMetadata(audio, getImage: true) as VorbisMetadata;
      expect(tags.trackNumber, original.trackNumber);
      expect(tags.genres, original.genres);
      expect(tags.unknowns, original.unknowns);
      expect(readMetadata(audio, getImage: true).pictures, hasLength(1));
    },
  );

  test(
    'format sniffing tags a mislabeled FLAC natively and rejects direct ID3',
    () async {
      final audio = await File(
        'test/fixtures/lyrics.flac',
      ).copy('${temporary.path}/mislabeled.mp3');
      final before = await audio.readAsBytes();
      expect(
        await Id3TagWriter.injectMetadata(filePath: audio.path, song: song),
        isFalse,
      );
      expect(await audio.readAsBytes(), before);
      final result = await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: song,
        lyricsText: lrc,
      );
      expect(result.tagsWritten, isTrue);
      expect(
        ascii.decode((await audio.readAsBytes()).take(4).toList()),
        'fLaC',
      );
      expect(readMetadata(audio).album, song.albumName);
    },
  );

  test('UTF-16 ID3 replaces a stale non-Unicode ID3v1 album trailer', () async {
    final audio = File('${temporary.path}/song.mp3');
    final frames = [0xff, 0xfb, 0x90, 0x64, ...List<int>.filled(32, 0)];
    await audio.writeAsBytes([
      ...frames,
      ...ascii.encode('TAG'),
      ...List<int>.filled(125, 0xff),
    ]);
    await DownloadMetadataWriter.write(filePath: audio.path, song: song);
    final bytes = await audio.readAsBytes();
    final offset = (await inspectAudioFile(audio.path)).offset;
    expect(bytes.sublist(offset), frames);
    expect(readMetadata(audio).album, song.albumName);
  });

  test(
    'unsupported codec stays intact and automatically gets a UTF-8 LRC',
    () async {
      final audio = File('${temporary.path}/song.m4a');
      final original = utf8.encode('unsupported audio bytes');
      await audio.writeAsBytes(original);
      final result = await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: song,
        lyricsText: lrc,
      );
      expect(result.tagsWritten, isFalse);
      expect(result.lyricsEmbedded, isFalse);
      expect(result.sidecarWritten, isTrue);
      expect(await audio.readAsBytes(), original);
      expect(await File('${temporary.path}/song.lrc').readAsString(), lrc);
    },
  );

  test(
    'malformed FLAC is left unchanged while embedding failure saves LRC',
    () async {
      final audio = File('${temporary.path}/broken.flac');
      final original = [...ascii.encode('fLaC'), 0x80, 0, 0, 34, 1, 2];
      await audio.writeAsBytes(original);
      final result = await DownloadMetadataWriter.write(
        filePath: audio.path,
        song: song,
        lyricsText: lrc,
      );
      expect(result.tagsWritten, isFalse);
      expect(result.sidecarWritten, isTrue);
      expect(await audio.readAsBytes(), original);
      expect(await File('${temporary.path}/broken.lrc').readAsString(), lrc);
    },
  );

  test('LRC preference keeps a sidecar even when embedding succeeds', () async {
    final audio = await File(
      'test/fixtures/lyrics.mp3',
    ).copy('${temporary.path}/song.mp3');
    final result = await DownloadMetadataWriter.write(
      filePath: audio.path,
      song: song,
      lyricsText: lrc,
      saveLyricsFile: true,
    );
    expect(result.lyricsEmbedded, isTrue);
    expect(result.sidecarWritten, isTrue);
    expect(await File('${temporary.path}/song.lrc').readAsString(), lrc);
  });

  test('lyric export retains long-track timestamps and translation lines', () {
    final text = downloadLyricsText(const [
      LyricLine(
        time: Duration(hours: 1, seconds: 2, milliseconds: 340),
        text: 'Hello\nworld',
        translation: '你好世界',
      ),
    ]);
    expect(text, '[60:02.34]Hello world\n[60:02.34]你好世界\n');
  });
}

bool listEquals(List<int> left, List<int> right) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => left[index] == right[index],
    ).every((equal) => equal);
