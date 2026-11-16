import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/download_metadata_writer.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDownloadService extends DownloadService {
  _FakeDownloadService(this.fileSizes);

  final Map<String, int> fileSizes;

  @override
  Future<int> fileSize(String path) async => fileSizes[path] ?? 0;
}

class _BlockingDownloadService extends DownloadService {
  @override
  Future<int> fileSize(String path) => Completer<int>().future;
}

class _DownloadApi extends MusicApi {
  _DownloadApi() : super(ApiClient());
  bool metadataFails = false;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async => PlayUrl(url: 'https://example.com/audio', hash: song.hash);

  @override
  Future<Song?> songDetail(Song song) async {
    if (metadataFails) throw const SocketException('offline metadata');
    return Song(
      id: song.id,
      title: song.title,
      artist: song.artist,
      hash: song.hash,
      albumName: '正确的中文专辑',
      albumId: 'album',
    );
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async {
    if (metadataFails) throw const SocketException('offline lyrics');
    return const [LyricLine(time: Duration(milliseconds: 1230), text: '中文歌词')];
  }
}

class _CompletingDownloadService extends DownloadService {
  _CompletingDownloadService(this.directory);
  final Directory directory;
  Completer<void>? finalizeGate;
  final finalizing = Completer<void>();
  int transferCount = 0;
  int finalizeCount = 0;

  @override
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    transferCount++;
    final file = await File(
      'test/fixtures/lyrics.mp3',
    ).copy('${directory.path}/${song.hash}.mp3');
    onProgress(1, 1);
    return file.path;
  }

  @override
  Future<DownloadMetadataResult> writeDownloadMetadata({
    required String filePath,
    required Song song,
    String? lyricsText,
    bool saveLyricsFile = false,
  }) async {
    finalizeCount++;
    if (!finalizing.isCompleted) finalizing.complete();
    await finalizeGate?.future;
    return super.writeDownloadMetadata(
      filePath: filePath,
      song: song,
      lyricsText: lyricsText,
      saveLyricsFile: saveLyricsFile,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancel during tagging cannot publish over or collide with a retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'download_retry_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = _CompletingDownloadService(directory)
        ..finalizeGate = Completer<void>();
      final controller = DownloadController(service, _DownloadApi());
      const song = Song(id: 'retry', hash: 'retry', title: '歌曲', artist: '歌手');
      final first = controller.download(song, AudioQuality.standard);
      await service.finalizing.future;
      await controller.cancelDownload(song);
      final retry = controller.download(song, AudioQuality.lossless);
      await Future<void>.delayed(Duration.zero);
      expect(service.transferCount, 1);
      expect(controller.entryFor(song)!.quality, AudioQuality.lossless);
      expect(controller.entryFor(song)!.status, DownloadStatus.downloading);
      service.finalizeGate!.complete();
      await first;
      await retry;
      expect(service.transferCount, 2);
      expect(service.finalizeCount, 2);
      expect(controller.entryFor(song)!.quality, AudioQuality.lossless);
      expect(controller.entryFor(song)!.status, DownloadStatus.downloaded);
      expect(
        readMetadata(File(controller.entryFor(song)!.filePath!)).album,
        '正确的中文专辑',
      );
    },
  );

  test(
    'download awaits Unicode tags and lyrics before indexing completion',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'download_controller_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = _CompletingDownloadService(directory)
        ..finalizeGate = Completer<void>();
      final controller = DownloadController(service, _DownloadApi());
      const song = Song(id: '1', hash: 'single', title: '歌曲', artist: '歌手');
      await controller.setSaveLyricsFile(true);
      final download = controller.download(song, AudioQuality.standard);
      await service.finalizing.future;
      expect(controller.entryFor(song)!.status, DownloadStatus.downloading);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'ka_music_downloads_index',
        ),
        isNull,
      );
      service.finalizeGate!.complete();
      await download;
      final entry = controller.entryFor(song)!;
      expect(entry.status, DownloadStatus.downloaded);
      expect(entry.song.albumName, '正确的中文专辑');
      final tags = readMetadata(File(entry.filePath!));
      expect(tags.album, '正确的中文专辑');
      expect(tags.lyrics, '[00:01.23]中文歌词\n');
      expect(
        await File('${directory.path}/single.lrc').readAsString(),
        tags.lyrics,
      );
      final restored = DownloadController(
        _FakeDownloadService({entry.filePath!: 1}),
        _DownloadApi(),
      );
      await restored.initialize();
      expect(restored.saveLyricsFile, isTrue);
      expect(restored.entryFor(song)!.song.albumName, '正确的中文专辑');
    },
  );

  test(
    'batch uses the same metadata and lyric finalization as single downloads',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'download_batch_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = _CompletingDownloadService(directory);
      final controller = DownloadController(service, _DownloadApi());
      const song = Song(id: '2', hash: 'batch', title: '歌曲', artist: '歌手');
      final done = Completer<void>();
      controller.addListener(() {
        if (controller.isDownloaded(song) && !done.isCompleted) done.complete();
      });
      expect(
        (await controller.enqueueBatch([song], AudioQuality.standard)).enqueued,
        1,
      );
      await done.future;
      final tags = readMetadata(File(controller.entryFor(song)!.filePath!));
      expect(tags.album, '正确的中文专辑');
      expect(tags.lyrics, contains('中文歌词'));
    },
  );

  test(
    'metadata and lyric lookup failures preserve a successful audio download',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'download_offline_metadata_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final controller = DownloadController(
        _CompletingDownloadService(directory),
        _DownloadApi()..metadataFails = true,
      );
      const song = Song(
        id: '3',
        hash: 'offline',
        title: '歌曲',
        artist: '歌手',
        albumName: '原始专辑',
      );
      await controller.download(song, AudioQuality.standard);
      expect(controller.isDownloaded(song), isTrue);
      expect(
        readMetadata(File(controller.entryFor(song)!.filePath!)).album,
        '原始专辑',
      );
    },
  );

  test(
    'downloaded file wins regardless of current quality and hash casing',
    () async {
      const downloadedSong = Song(
        id: '1',
        title: '已下载歌曲',
        artist: '歌手',
        hash: 'ABC123',
      );
      const playlistSong = Song(
        id: '1',
        title: '已下载歌曲',
        artist: '歌手',
        hash: 'abc123',
      );
      const path = '/downloads/song.flac';
      SharedPreferences.setMockInitialValues({
        'ka_music_downloads_index': jsonEncode([
          {
            'song': downloadedSong.toCache(),
            'quality': AudioQuality.lossless.apiValue,
            'filePath': path,
            'downloadedAt': '2026-10-26T12:00:00.000',
          },
        ]),
      });

      final controller = DownloadController(
        _FakeDownloadService({path: 1024}),
        MusicApi(ApiClient()),
      );

      expect(
        await controller.localPathFor(playlistSong, AudioQuality.standard),
        path,
      );
      expect(controller.isDownloaded(playlistSong), isTrue);
    },
  );

  test(
    'stalled local file lookup falls back instead of blocking playback',
    () async {
      const song = Song(
        id: '2',
        title: '旧下载歌曲',
        artist: '歌手',
        hash: 'stale-path',
      );
      SharedPreferences.setMockInitialValues({
        'ka_music_downloads_index': jsonEncode([
          {
            'song': song.toCache(),
            'quality': AudioQuality.standard.apiValue,
            'filePath': '/downloads/stalled.mp3',
            'downloadedAt': '2026-10-26T12:00:00.000',
          },
        ]),
      });

      final controller = DownloadController(
        _BlockingDownloadService(),
        MusicApi(ApiClient()),
      );

      final stopwatch = Stopwatch()..start();
      expect(
        await controller.localPathFor(song, AudioQuality.standard),
        isNull,
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(controller.isDownloaded(song), isTrue);
    },
  );
}
