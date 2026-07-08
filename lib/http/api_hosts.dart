import 'package:PiliPlus/http/constants.dart';

class ApiHostEntry {
  final String label;
  final String settingKey;
  final String defaultHost;

  const ApiHostEntry({
    required this.label,
    required this.settingKey,
    required this.defaultHost,
  });
}

/// All configurable bilibili API hosts.
/// label: Chinese label shown in config page.
/// settingKey: SettingBoxKey constant name (without the value prefix).
/// defaultHost: The official bilibili host used as fallback.
const List<ApiHostEntry> apiHostEntries = [
  ApiHostEntry(
    label: '主站',
    settingKey: 'customBaseUrl',
    defaultHost: HttpString.baseUrl,
  ),
  ApiHostEntry(
    label: '主API',
    settingKey: 'customApiBaseUrl',
    defaultHost: HttpString.apiBaseUrl,
  ),
  ApiHostEntry(
    label: '动态/私信API',
    settingKey: 'customTUrl',
    defaultHost: HttpString.tUrl,
  ),
  ApiHostEntry(
    label: 'App API',
    settingKey: 'customAppBaseUrl',
    defaultHost: HttpString.appBaseUrl,
  ),
  ApiHostEntry(
    label: '直播API',
    settingKey: 'customLiveBaseUrl',
    defaultHost: HttpString.liveBaseUrl,
  ),
  ApiHostEntry(
    label: '登录API',
    settingKey: 'customPassBaseUrl',
    defaultHost: HttpString.passBaseUrl,
  ),
  ApiHostEntry(
    label: '消息通知API',
    settingKey: 'customMessageBaseUrl',
    defaultHost: HttpString.messageBaseUrl,
  ),
  ApiHostEntry(
    label: '动态分享',
    settingKey: 'customDynamicShareBaseUrl',
    defaultHost: HttpString.dynamicShareBaseUrl,
  ),
  ApiHostEntry(
    label: '空间API',
    settingKey: 'customSpaceBaseUrl',
    defaultHost: HttpString.spaceBaseUrl,
  ),
  ApiHostEntry(
    label: '账户API',
    settingKey: 'customAccountBaseUrl',
    defaultHost: HttpString.accountBaseUrl,
  ),
  ApiHostEntry(
    label: '商城API',
    settingKey: 'customMallBaseUrl',
    defaultHost: HttpString.mallBaseUrl,
  ),
  ApiHostEntry(
    label: '搜索API',
    settingKey: 'customSearchBaseUrl',
    defaultHost: 'https://s.search.bilibili.com',
  ),
];
