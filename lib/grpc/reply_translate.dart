// Manually added protobuf types for reply translate.
//
// These correspond to the TranslateReply RPC on the
// bilibili.main.community.reply.v1.Reply service:
//   - TranslateReplyReq  (type, oid, rpids)
//   - TranslateReplyResp (map<int64, ReplyInfo>)
//
// Added because the generated v1.pb.dart predates this API.

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');

class TranslateReplyReq extends $pb.GeneratedMessage {
  factory TranslateReplyReq({
    $fixnum.Int64? type,
    $fixnum.Int64? oid,
    $core.Iterable<$fixnum.Int64>? rpids,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (oid != null) result.oid = oid;
    if (rpids != null) result.rpids.addAll(rpids);
    return result;
  }

  TranslateReplyReq._();

  factory TranslateReplyReq.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranslateReplyReq.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranslateReplyReq',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'bilibili.main.community.reply.v1'),
      createEmptyInstance: create)
    ..aInt64(1, _omitFieldNames ? '' : 'type')
    ..aInt64(2, _omitFieldNames ? '' : 'oid')
    ..p<$fixnum.Int64>(3, _omitFieldNames ? '' : 'rpids',
        $pb.PbFieldType.P6)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranslateReplyReq clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranslateReplyReq copyWith(void Function(TranslateReplyReq) updates) =>
      super.copyWith((message) => updates(message as TranslateReplyReq))
          as TranslateReplyReq;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranslateReplyReq create() => TranslateReplyReq._();
  @$core.override
  TranslateReplyReq createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranslateReplyReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranslateReplyReq>(create);
  static TranslateReplyReq? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get type => $_getI64(0);
  @$pb.TagNumber(1)
  set type($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get oid => $_getI64(1);
  @$pb.TagNumber(2)
  set oid($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasOid() => $_has(1);
  @$pb.TagNumber(2)
  void clearOid() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$fixnum.Int64> get rpids => $_getList(2);
}

class TranslateReplyResp extends $pb.GeneratedMessage {
  factory TranslateReplyResp({
    $core.Iterable<$core.MapEntry<$fixnum.Int64, ReplyInfo>>?
        translatedReplies,
  }) {
    final result = create();
    if (translatedReplies != null) {
      result.translatedReplies.addEntries(translatedReplies);
    }
    return result;
  }

  TranslateReplyResp._();

  factory TranslateReplyResp.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TranslateReplyResp.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TranslateReplyResp',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'bilibili.main.community.reply.v1'),
      createEmptyInstance: create)
    ..m<$fixnum.Int64, ReplyInfo>(1, _omitFieldNames ? '' : 'translatedReplies',
        entryClassName: 'TranslateReplyResp.TranslatedRepliesEntry',
        keyFieldType: $pb.PbFieldType.O6,
        valueFieldType: $pb.PbFieldType.OM,
        valueCreator: ReplyInfo.create,
        valueDefaultOrMaker: ReplyInfo.getDefault,
        packageName: const $pb.PackageName(
            'bilibili.main.community.reply.v1'))
    ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TranslateReplyResp create() => TranslateReplyResp._();
  @$core.override
  TranslateReplyResp createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TranslateReplyResp getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TranslateReplyResp>(create);
  static TranslateReplyResp? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbMap<$fixnum.Int64, ReplyInfo> get translatedReplies => $_getMap(0);

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranslateReplyResp clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TranslateReplyResp copyWith(
          void Function(TranslateReplyResp) updates) =>
      super.copyWith((message) => updates(message as TranslateReplyResp))
          as TranslateReplyResp;
}
