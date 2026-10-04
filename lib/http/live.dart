import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/live/live_contribution_rank_type.dart';
import 'package:PiliPlus/models/common/live/live_search_type.dart';
import 'package:PiliPlus/models_new/live/live_area_list/area_item.dart';
import 'package:PiliPlus/models_new/live/live_area_list/area_list.dart';
import 'package:PiliPlus/models_new/live/live_contribution_rank/data.dart';
import 'package:PiliPlus/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:PiliPlus/models_new/live/live_dm_block/data.dart';
import 'package:PiliPlus/models_new/live/live_dm_block/shield_info.dart';
import 'package:PiliPlus/models_new/live/live_dm_block/shield_user_list.dart';
import 'package:PiliPlus/models_new/live/live_dm_info/data.dart';
import 'package:PiliPlus/models_new/live/live_emote/data.dart';
import 'package:PiliPlus/models_new/live/live_emote/datum.dart';
import 'package:PiliPlus/models_new/live/live_feed_index/data.dart';
import 'package:PiliPlus/models_new/live/live_follow/data.dart';
import 'package:PiliPlus/models_new/live/live_medal_wall/data.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/data.dart';
import 'package:PiliPlus/models_new/live/live_search/data.dart';
import 'package:PiliPlus/models_new/live/live_second_list/data.dart';
import 'package:PiliPlus/models_new/live/live_superchat/data.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

abstract final class LiveHttp {
  /// 账号绑定的请求档案（平台 + 设备，登录时确定）。
  static AppRequestProfile get _appProfile => recommend.appRequestProfile;

  static Account get recommend => Accounts.get(AccountType.recommend);

  /// 按账号档案构造 app 端公共字段（平台 + 设备）。
  ///
  /// 不要在同一请求里混用档案字段与 `Constants.*` 里的版本常量：那会生成一个
  /// 自相矛盾的客户端（例如 `build=8.43.0` 配 9.13.0 的 UA）。字段一律取自
  /// [Account.appRequestProfile]。
  static Map<String, dynamic> appQueryFields(
    AppRequestProfile profile, {
    bool channel = false,
    bool device = false,
    bool forceDevice = false,
  }) => {
    'build': profile.build,
    if (channel) 'channel': profile.channel,
    'version': profile.versionName,
    'c_locale': Constants.cLocale,
    if (forceDevice || device) 'device': profile.requestDevice,
    'mobi_app': profile.mobiApp,
    'platform': profile.platform,
    's_locale': Constants.sLocale,
    'statistics': profile.statistics,
  };

  /// app 请求头（UA + 身份头），与参数同源于账号档案。
  static Map<String, String> appRequestHeaders(Account account) => {
    'user-agent': account.appRequestProfile.userAgent,
    ...appIdentityHeaders(account),
  };

  @visibleForTesting
  static Map<String, dynamic> liveFeedIndexQueryParameters({
    required Account account,
    required int pn,
    bool moduleSelect = false,
  }) {
    // 账号绑定的平台 + 设备（登录时确定）。
    final appProfile = account.appRequestProfile;
    return {
      'access_key': ?account.accessKey,
      'channel': appProfile.channel,
      'actionKey': 'appkey',
      'build': appProfile.build,
      'version': appProfile.versionName,
      'c_locale': Constants.cLocale,
      'device': appProfile.requestDevice,
      'device_name': appProfile.deviceName,
      'device_type': 0,
      'fnval': 912,
      'disable_rcmd': 0,
      'https_url_req': 1,
      if (moduleSelect) 'module_select': 1,
      'mobi_app': appProfile.mobiApp,
      'network': 'wifi',
      'page': pn,
      'platform': appProfile.platform,
      if (account.isLogin) 'relation_page': 1,
      's_locale': Constants.sLocale,
      'scale': 2,
      'statistics': appProfile.statistics,
    };
  }

  static Map<String, String> appIdentityHeaders(Account account) {
    final userAgent = account.appRequestProfile.userAgent;
    final identity = RequestIdentityAdapter.fromAccount(
      account: account,
      userAgent: userAgent,
    );
    return {
      ...identity.appHeaders(userAgent: userAgent),
      ...identity.appIdentityHeaders,
    };
  }

  static Future<LoadingState<void>> sendLiveMsg({
    required Object roomId,
    required Object msg,
    Object? dmType,
    Object? emoticonOptions,
    int replyMid = 0,
    String replayDmid = '',
  }) async {
    String csrf = Accounts.main.csrf;
    final res = await Request().post(
      Api.sendLiveMsg,
      queryParameters: await WbiSign.makSign({'web_location': 444.8}),
      data: FormData.fromMap({
        'bubble': 0,
        'msg': msg,
        'color': 16777215,
        'mode': 1,
        'dm_type': ?dmType,
        if (emoticonOptions != null)
          'emoticonOptions': emoticonOptions
        else ...{
          'room_type': 0,
          'jumpfrom': 0,
          'reply_mid': replyMid,
          'reply_attr': 0,
          'replay_dmid': replayDmid,
          'statistics': '{"appId":100,"platform":5}',
          'reply_type': 0,
          'reply_uname': '',
        },
        'fontsize': 25,
        'rnd': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'roomid': roomId,
        'csrf': csrf,
        'csrf_token': csrf,
      }),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<RoomPlayInfoData>> liveRoomInfo({
    required Object roomId,
    Object? qn,
    bool onlyAudio = false,
  }) async {
    final res = await Request().get(
      Api.liveRoomInfo,
      queryParameters: await WbiSign.makSign({
        'room_id': roomId,
        'protocol': '0,1',
        'format': '0,1,2',
        'codec': '0,1,2',
        'qn': ?qn,
        'platform': 'web',
        'ptype': 8,
        'dolby': 5,
        'panorama': 1,
        if (onlyAudio) 'only_audio': 1,
        'web_location': 444.8,
      }),
    );
    if (res.data['code'] == 0) {
      try {
        return Success(RoomPlayInfoData.fromJson(res.data['data']));
      } catch (e) {
        return Error(e.toString());
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<RoomInfoH5Data>> liveRoomInfoH5({
    required Object roomId,
  }) async {
    final res = await Request().get(
      Api.liveRoomInfoH5,
      queryParameters: {'room_id': roomId},
    );
    if (res.data['code'] == 0) {
      return Success(RoomInfoH5Data.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<DanmakuMsg>?>> liveRoomDmPrefetch({
    required Object roomId,
  }) async {
    final res = await Request().get(
      Api.liveRoomDmPrefetch,
      queryParameters: {'roomid': roomId},
      options: Options(
        headers: {
          'referer': 'https://live.bilibili.com/$roomId',
          'user-agent': BrowserUa.pc,
        },
      ),
    );
    if (res.data['code'] == 0) {
      try {
        return Success(
          (res.data['data']?['room'] as List?)
              ?.map((e) => DanmakuMsg.fromPrefetch(e))
              .toList(),
        );
      } catch (e) {
        return Error(e.toString());
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LiveDmInfoData>> liveRoomGetDanmakuToken({
    required Object roomId,
  }) async {
    final res = await Request().get(
      Api.liveRoomDmToken,
      queryParameters: await WbiSign.makSign({
        'id': roomId,
        'web_location': 444.8,
      }),
    );
    if (res.data['code'] == 0) {
      try {
        return Success(LiveDmInfoData.fromJson(res.data['data']));
      } catch (e) {
        return Error(e.toString());
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<LiveEmoteDatum>?>> getLiveEmoticons({
    required int roomId,
  }) async {
    final res = await Request().get(
      Api.getLiveEmoticons,
      queryParameters: {
        'platform': 'pc',
        'room_id': roomId,
      },
    );
    if (res.data['code'] == 0) {
      return Success(LiveEmoteData.fromJson(res.data['data']).data);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LiveIndexData>> liveFeedIndex({
    required int pn,
    bool moduleSelect = false,
  }) async {
    final account = recommend;
    final params = liveFeedIndexQueryParameters(
      account: account,
      pn: pn,
      moduleSelect: moduleSelect,
    );
    AppSign.appSign(params);
    final res = await Request().get(
      Api.liveFeedIndex,
      queryParameters: params,
      options: Options(
        headers: appIdentityHeaders(account),
      ),
    );
    if (res.data['code'] == 0) {
      return Success(LiveIndexData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LiveFollowData>> liveFollow(int page) async {
    final res = await Request().get(
      Api.liveFollow,
      queryParameters: {
        'page': page,
        'page_size': 9,
        'ignoreRecord': 1,
        'hit_ab': true,
      },
    );
    if (res.data['code'] == 0) {
      return Success(LiveFollowData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LiveSecondData>> liveSecondList({
    required int pn,
    required Object? areaId,
    required Object? parentAreaId,
    String? sortType,
  }) async {
    final account = recommend;
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'channel': _appProfile.channel,
      'area_id': ?areaId,
      'parent_area_id': ?parentAreaId,
      'build': _appProfile.build,
      'version': _appProfile.versionName,
      'c_locale': Constants.cLocale,
      'device': _appProfile.requestDevice,
      'device_name': _appProfile.deviceName,
      'device_type': 0,
      'fnval': 912,
      'disable_rcmd': 0,
      'https_url_req': 1,
      'mobi_app': _appProfile.mobiApp,
      'module_select': 0,
      'network': 'wifi',
      'page': pn,
      'page_size': 20,
      'platform': _appProfile.platform,
      'qn': 0,
      'sort_type': ?sortType,
      'tag_version': 1,
      's_locale': Constants.sLocale,
      'scale': 2,
      'statistics': _appProfile.statistics,
    };
    AppSign.appSign(params);
    final res = await Request().get(
      Api.liveSecondList,
      queryParameters: params,
      options: Options(
        headers: appIdentityHeaders(account),
      ),
    );
    if (res.data['code'] == 0) {
      return Success(LiveSecondData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<AreaList>?>> liveAreaList() async {
    final params = {
      'access_key': ?recommend.accessKey,
      'actionKey': 'appkey',
      'build': _appProfile.build,
      'channel': _appProfile.channel,
      'version': _appProfile.versionName,
      'c_locale': Constants.cLocale,
      'device': _appProfile.requestDevice,
      'disable_rcmd': 0,
      'mobi_app': _appProfile.mobiApp,
      'platform': _appProfile.platform,
      's_locale': Constants.sLocale,
      'statistics': _appProfile.statistics,
    };
    AppSign.appSign(params);
    final res = await Request().get(
      Api.liveAreaList,
      queryParameters: params,
    );
    if (res.data['code'] == 0) {
      return Success(
        (res.data['data']?['list'] as List?)
            ?.map((e) => AreaList.fromJson(e))
            .toList(),
      );
    } else {
      return Error(res.data['message']);
    }
  }

  /// 直播收藏分区的公共参数。
  ///
  /// 凭证与客户端字段必须来自**同一个账号**：这两个接口是主账号的收藏操作
  /// （[getLiveFavTag] / [setLiveFavTag]），不能拿主账号的 access_key 配上
  /// 推荐账号的设备/平台档案 —— 那会让 access_key、mobi_app、app-key 头与
  /// 签名 key 分属两套身份。
  @visibleForTesting
  static Map<String, dynamic> liveFavTagQueryParameters(Account account) {
    final appProfile = account.appRequestProfile;
    return {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': appProfile.build,
      'channel': appProfile.channel,
      'version': appProfile.versionName,
      'c_locale': Constants.cLocale,
      'device': appProfile.requestDevice,
      'disable_rcmd': 0,
      'mobi_app': appProfile.mobiApp,
      'platform': appProfile.platform,
      's_locale': Constants.sLocale,
      'statistics': appProfile.statistics,
    };
  }

  static Future<LoadingState<List<AreaItem>>> getLiveFavTag() async {
    final account = Accounts.main;
    final params = liveFavTagQueryParameters(account);
    AppSign.appSign(params);
    final res = await Request().get(
      Api.getLiveFavTag,
      queryParameters: params,
      options: Options(
        headers: appRequestHeaders(account),
        // 显式绑定发起账号，使 Cookie 注入/回写与上面的凭证、档案同源。
        extra: {'account': account},
      ),
    );

    if (res.data['code'] == 0) {
      return Success(
        (res.data['data']?['tags'] as List?)
                ?.map((e) => AreaItem.fromJson(e))
                .toList() ??
            <AreaItem>[],
      );
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> setLiveFavTag({
    required String ids,
  }) async {
    final account = Accounts.main;
    final data = <String, dynamic>{
      'tags': ids,
      ...liveFavTagQueryParameters(account),
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.setLiveFavTag,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: appRequestHeaders(account),
        extra: {'account': account},
      ),
    );

    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<AreaItem>?>> liveRoomAreaList({
    required Object parentid,
  }) async {
    final params = {
      'access_key': ?recommend.accessKey,
      'actionKey': 'appkey',
      'build': _appProfile.build,
      'channel': _appProfile.channel,
      'version': _appProfile.versionName,
      'c_locale': Constants.cLocale,
      'device': _appProfile.requestDevice,
      'disable_rcmd': 0,
      'need_entrance': 1,
      'parent_id': parentid,
      'source_id': 2,
      'mobi_app': _appProfile.mobiApp,
      'platform': _appProfile.platform,
      's_locale': Constants.sLocale,
      'statistics': _appProfile.statistics,
    };
    AppSign.appSign(params);
    final res = await Request().get(
      Api.liveRoomAreaList,
      queryParameters: params,
    );
    if (res.data['code'] == 0) {
      return Success(
        (res.data['data'] as List?)?.map((e) => AreaItem.fromJson(e)).toList(),
      );
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LiveSearchData>> liveSearch({
    required int page,
    required String keyword,
    required LiveSearchType type,
  }) async {
    final params = {
      'access_key': ?recommend.accessKey,
      'actionKey': 'appkey',
      'build': _appProfile.build,
      'channel': _appProfile.channel,
      'version': _appProfile.versionName,
      'c_locale': Constants.cLocale,
      'device': _appProfile.requestDevice,
      'page': page,
      'pagesize': 30,
      'keyword': keyword,
      'disable_rcmd': 0,
      'mobi_app': _appProfile.mobiApp,
      'platform': _appProfile.platform,
      's_locale': Constants.sLocale,
      'statistics': _appProfile.statistics,
      'type': type.name,
    };
    AppSign.appSign(params);
    final res = await Request().get(
      Api.liveSearch,
      queryParameters: params,
    );
    if (res.data['code'] == 0) {
      return Success(LiveSearchData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<ShieldInfo?>> getLiveInfoByUser(
    Object roomId,
  ) async {
    final res = await Request().get(
      Api.getLiveInfoByUser,
      queryParameters: await WbiSign.makSign({
        'room_id': roomId,
        'from': 0,
        'not_mock_enter_effect': 1,
        'web_location': 444.8,
      }),
    );
    if (res.data['code'] == 0) {
      return Success(LiveDmBlockData.fromJson(res.data['data']).shieldInfo);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> liveSetSilent({
    required String type,
    required int level,
  }) async {
    final csrf = Accounts.main.csrf;
    final res = await Request().post(
      Api.liveSetSilent,
      data: {
        'type': type,
        'level': level,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> addShieldKeyword({
    required String keyword,
  }) async {
    final csrf = Accounts.main.csrf;
    final res = await Request().post(
      Api.addShieldKeyword,
      data: {
        'keyword': keyword,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> delShieldKeyword({
    required String keyword,
  }) async {
    final csrf = Accounts.main.csrf;
    final res = await Request().post(
      Api.delShieldKeyword,
      data: {
        'keyword': keyword,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<ShieldUserList>> liveShieldUser({
    required Object uid,
    required Object roomid,
    required int type,
  }) async {
    final csrf = Accounts.main.csrf;
    final res = await Request().post(
      Api.liveShieldUser,
      data: {
        'uid': uid,
        'roomid': roomid,
        'type': type,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return Success(ShieldUserList.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> liveLikeReport({
    required int clickTime,
    required Object roomId,
    required Object uid,
    Object? anchorId,
  }) async {
    final res = await Request().post(
      Api.liveLikeReport,
      data: await WbiSign.makSign({
        'click_time': clickTime,
        'room_id': roomId,
        'uid': uid,
        'anchor_id': ?anchorId,
        'web_location': 444.8,
        'csrf': Accounts.heartbeat.csrf,
      }),
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<SuperChatData>> superChatMsg(
    int roomId,
  ) async {
    final res = await Request().get(
      Api.superChatMsg,
      queryParameters: {
        'room_id': roomId,
      },
    );
    if (res.data['code'] == 0) {
      try {
        return Success(SuperChatData.fromJson(res.data['data'], roomId));
      } catch (e, s) {
        return Error('$e\n\n$s');
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> liveDmReport({
    required int roomId,
    required Object mid,
    required String msg,
    required String reason,
    required int reasonId,
    required int dmType,
    required Object idStr,
    required Object ts,
    required Object sign,
  }) async {
    final csrf = Accounts.main.csrf;
    final data = {
      'id': 0,
      'roomid': roomId,
      'tuid': mid,
      'msg': msg,
      'reason': reason,
      'ts': ts,
      'sign': sign,
      'reason_id': reasonId,
      'token': '',
      'dm_type': dmType,
      'id_str': idStr,
      'csrf_token': csrf,
      'csrf': csrf,
      'visit_id': '',
    };
    final res = await Request().post(
      Api.liveDmReport,
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LiveContributionRankData>> liveContributionRank({
    required Object ruid,
    required Object roomId,
    required int page,
    required LiveContributionRankType type,
  }) async {
    final res = await Request().get(
      Api.liveContributionRank,
      queryParameters: await WbiSign.makSign({
        'ruid': ruid,
        'room_id': roomId,
        'page': page,
        'page_size': 100,
        'type': type.name,
        'switch': type.sw1tch,
        'platform': 'web',
        'web_location': 444.8,
      }),
    );
    if (res.data['code'] == 0) {
      try {
        return Success(LiveContributionRankData.fromJson(res.data['data']));
      } catch (e, s) {
        return Error('$e\n\n$s');
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> superChatReport({
    required int id,
    required Object roomId,
    required Object uid,
    required String msg,
    required String reason,
    required int ts,
    required String token,
  }) async {
    final csrf = Accounts.main.csrf;
    final res = await Request().post(
      Api.superChatReport,
      data: {
        'id': id,
        'roomid': roomId,
        'uid': uid,
        'msg': msg,
        'reason': reason,
        'ts': ts,
        'sign': '',
        'reason_id': reason,
        'token': token,
        'id_str': id.toString(),
        'csrf_token': csrf,
        'csrf': csrf,
        'visit_id': '',
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<MedalWallData>> liveMedalWall({
    required Object mid,
  }) async {
    final res = await Request().get(
      Api.liveMedalWall,
      queryParameters: {'target_id': mid},
    );
    if (res.data['code'] == 0) {
      return Success(MedalWallData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> liveFeedback(
    Object roomId,
    Object id,
    String type, {
    int page = 1,
  }) async {
    final account = recommend;
    final params = <String, dynamic>{
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      ...appQueryFields(account.appRequestProfile, channel: true, device: true),
      'disable_rcmd': 0,
      'id': id,
      'id_type': type,
      'room_id': roomId,
      'type': 'dislike',
      'page': page,
    };
    AppSign.appSign(params);
    final res = await Request().get(
      Api.liveFeedback,
      queryParameters: params,
      options: Options(
        headers: appRequestHeaders(account),
        extra: {'account': account},
      ),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }
}
