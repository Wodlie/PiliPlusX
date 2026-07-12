import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';

abstract final class BlockedImageStorage {
  static String get dirPath => path.join(appSupportDirPath, 'blocked_images');

  static String filePathFor(String pHash) => path.join(dirPath, '$pHash.jpg');

  static Future<void> ensureDir() async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
  }

  static Future<void> saveImage(String pHash, Uint8List bytes) async {
    await ensureDir();
    await File(filePathFor(pHash)).writeAsBytes(bytes);
  }

  static Future<void> saveImageFromUrl(String pHash, String url) async {
    await ensureDir();
    final response = await Request.dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    await File(filePathFor(pHash)).writeAsBytes(response.data!);
  }

  static File? getFile(String pHash) {
    final file = File(filePathFor(pHash));
    return file.existsSync() ? file : null;
  }

  static bool exists(String pHash) => File(filePathFor(pHash)).existsSync();

  static Future<void> delete(String pHash) async {
    final file = File(filePathFor(pHash));
    await file.tryDel();
  }

  static Future<void> deleteAll() async {
    final dir = Directory(dirPath);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  static Future<void> tryReDownload(String pHash, String url) async {
    try {
      await saveImageFromUrl(pHash, url);
    } catch (_) {}
  }
}
