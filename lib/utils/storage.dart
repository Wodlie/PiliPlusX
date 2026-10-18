import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/models/common/home_tab_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models/user/danmaku_rule_adapter.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account_adapter.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/account_type_adapter.dart';
import 'package:PiliPlus/utils/accounts/cookie_jar_adapter.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/set_int_adapter.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

abstract final class GStorage {
  static late final Box<UserInfoData> userInfo;
  static late final Box<dynamic> historyWord;
  static late final Box<dynamic> localCache;
  static late final Box<dynamic> setting;
  static late final Box<dynamic> video;
  static late final Box<int> watchProgress;
  static late final Box<Uint8List>? reply;

  static Future<void> init() async {
    Hive.init(path.join(appSupportDirPath, 'hive'));
    regAdapter();

    await Future.wait([
      // 登录用户信息
      Hive.openBox<UserInfoData>(
        'userInfo',
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 2;
        },
      ).then((res) => userInfo = res),
      // 本地缓存
      Hive.openBox(
        'localCache',
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 4;
        },
      ).then((res) => localCache = res),
      // 设置
      Hive.openBox('setting').then((res) => setting = res),
      // 搜索历史
      Hive.openBox(
        'historyWord',
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 10;
        },
      ).then((res) => historyWord = res),
      // 视频设置
      Hive.openBox('video').then((res) => video = res),
      Accounts.init(),
      Hive.openBox<int>(
        'watchProgress',
        keyComparator: _intStrDescKeyComparator,
        compactionStrategy: (entries, deletedEntries) {
          return deletedEntries > 4;
        },
      ).then((res) => watchProgress = res),
    ]);

    if (Pref.saveReply) {
      reply = await Hive.openBox<Uint8List>(
        'reply',
        keyComparator: _intStrDescKeyComparator,
        compactionStrategy: (entries, deletedEntries) {
          return deletedEntries > 10;
        },
      );
    } else {
      reply = null;
    }
  }

  static String exportAllSettings() {
    return Utils.jsonEncoder.convert({
      setting.name: setting.toMap(),
      video.name: video.toMap(),
    });
  }

  static Future<void> importAllSettings(String data) =>
      importAllJsonSettings(jsonDecode(data));

  static Future<void> importAllJsonSettings(Object? input) async {
    if (input is! Map) throw const FormatException('设置文件顶层必须是对象');
    final settingMap = _validateSettingsBox(input, setting.name);
    final videoMap = _validateSettingsBox(input, video.name);
    final settingSnapshot = Map<dynamic, dynamic>.from(setting.toMap());
    final videoSnapshot = Map<dynamic, dynamic>.from(video.toMap());
    try {
      await setting.clear();
      await setting.putAll(settingMap);
      await video.clear();
      await video.putAll(videoMap);
    } catch (error) {
      try {
        await Future.wait([
          _restoreBox(setting, settingSnapshot),
          _restoreBox(video, videoSnapshot),
        ]);
      } catch (restoreError) {
        throw FormatException('设置导入失败，恢复原设置失败: $restoreError');
      }
      throw FormatException('设置导入失败，已恢复原设置: $error');
    }
  }

  static Map<dynamic, dynamic> _validateSettingsBox(Map input, String name) {
    final value = input[name];
    if (value is! Map) throw FormatException('$name 必须是对象');
    final result = Map<dynamic, dynamic>.from(value);
    final box = name == setting.name ? setting : video;
    for (final entry in result.entries) {
      final current = box.get(entry.key);
      if (current != null && !_matchesSettingType(current, entry.value)) {
        throw FormatException('$name.${entry.key} 类型无效');
      }
    }
    _validateListIndex(result, 'tabBarSort', HomeTabType.values.length);
    _validateListIndex(result, 'navBarSort', NavigationBarType.values.length);
    _validateIndex(result, 'defaultHomePage', NavigationBarType.values.length);
    for (final key in result.keys) {
      if (key.toString().contains('banWord')) {
        final pattern = result[key];
        if (pattern is! String) {
          throw FormatException('$name.$key 必须是字符串');
        }
        try {
          RegExp(pattern, caseSensitive: false);
        } on FormatException {
          throw FormatException('$name.$key 正则格式无效');
        }
      }
    }
    return result;
  }

  static bool _matchesSettingType(Object current, Object? value) {
    if (current is List) return value is List;
    if (current is Map) return value is Map;
    if (current is String) return value is String;
    if (current is bool) return value is bool;
    if (current is int) return value is int;
    if (current is double) return value is double;
    return current.runtimeType == value.runtimeType;
  }

  static void _validateListIndex(Map map, String key, int length) {
    final value = map[key];
    if (value != null &&
        (value is! List ||
            value.isEmpty ||
            value.any((item) => item is! int || item < 0 || item >= length))) {
      throw FormatException('$key 包含无效值');
    }
  }

  static void _validateIndex(Map map, String key, int length) {
    final value = map[key];
    if (value != null && (value is! int || value < 0 || value >= length)) {
      throw FormatException('$key 包含无效值');
    }
  }

  static Future<void> _restoreBox(Box box, Map<dynamic, dynamic> snapshot) async {
    await box.clear();
    await box.putAll(snapshot);
  }

  static void regAdapter() {
    Hive
      ..registerAdapter(OwnerAdapter())
      ..registerAdapter(UserInfoDataAdapter())
      ..registerAdapter(LevelInfoAdapter())
      ..registerAdapter(BiliCookieJarAdapter())
      ..registerAdapter(AppDeviceProfileAdapter())
      ..registerAdapter(LoginAccountAdapter())
      ..registerAdapter(AccountTypeAdapter())
      ..registerAdapter(SetIntAdapter())
      ..registerAdapter(RuleFilterAdapter());
  }

  static Future<List<void>> compact() {
    return Future.wait([
      userInfo.compact(),
      historyWord.compact(),
      localCache.compact(),
      setting.compact(),
      video.compact(),
      Accounts.account.compact(),
      watchProgress.compact(),
      ?reply?.compact(),
    ]);
  }

  static Future<List<void>> close() {
    return Future.wait([
      userInfo.close(),
      historyWord.close(),
      localCache.close(),
      setting.close(),
      video.close(),
      Accounts.account.close(),
      watchProgress.close(),
      ?reply?.close(),
    ]);
  }

  static Future<List<void>> clear() {
    return Future.wait([
      userInfo.clear(),
      historyWord.clear(),
      localCache.clear(),
      setting.clear(),
      video.clear(),
      Accounts.clear(),
      watchProgress.clear(),
      ?reply?.clear(),
    ]);
  }

  static int _intStrDescKeyComparator(dynamic k1, dynamic k2) {
    if (k1 is int) {
      if (k2 is int) {
        return k2.compareTo(k1);
      } else {
        return -1;
      }
    } else if (k2 is String) {
      final lenCompare = k2.length.compareTo((k1 as String).length);
      if (lenCompare == 0) {
        return k2.compareTo(k1);
      } else {
        return lenCompare;
      }
    } else {
      return 1;
    }
  }
}
