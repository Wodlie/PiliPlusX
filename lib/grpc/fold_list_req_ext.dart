// 临时诊断用：手写 FoldListReq（非生成物，查完可整文件删除）
// 依据 reverse-output/apk-reply-fold/REPORT.md §8 + evidence/15_foldlist_rpc.txt
//   FoldListReq { int64 oid = 1; int64 type = 2; string extra = 3; FeedPagination pagination = 4; }
// 响应可用 ReplyInfo.fromBuffer 解析（FoldListResp.replies=1 与 ReplyInfo.replies=1 同构），
// 因此这里不必手写 FoldListResp。
import 'dart:core' as $core;

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart' as $reply;
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart' as $2;
import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

class FoldListReq extends $pb.GeneratedMessage {
  factory FoldListReq({
    $fixnum.Int64? oid,
    $fixnum.Int64? type,
    $core.String? extra,
    $2.FeedPagination? pagination,
  }) {
    final result = FoldListReq._();
    if (oid != null) result.oid = oid;
    if (type != null) result.type = type;
    if (extra != null) result.extra = extra;
    if (pagination != null) result.pagination = pagination;
    return result;
  }

  FoldListReq._();

  factory FoldListReq.fromBuffer(
    $core.List<$core.int> data, [
    $pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY,
  ]) => FoldListReq()..mergeFromBuffer(data, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
    'FoldListReq',
    package: const $pb.PackageName('bilibili.main.community.reply.v1'),
    createEmptyInstance: FoldListReq.$_createMessage,
  )
    ..aInt64(1, 'oid')
    ..aInt64(2, 'type')
    ..aOS(3, 'extra')
    ..aOM<$2.FeedPagination>(4, 'pagination', subBuilder: $2.FeedPagination.create)
    ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.Deprecated('See https://github.com/google/protobuf/issues/998.')
  FoldListReq clone() => deepCopy();

  @$core.Deprecated('See https://github.com/google/protobuf/issues/998.')
  FoldListReq copyWith(void Function(FoldListReq) updates) =>
      super.copyWith((message) => updates(message as FoldListReq))
          as FoldListReq;

  @$core.pragma('dart2js:noInline')
  static FoldListReq create() => FoldListReq._();
  static FoldListReq $_createMessage() => FoldListReq._();
  @$core.override
  FoldListReq createEmptyInstance() => FoldListReq._();
  static FoldListReq getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FoldListReq>(FoldListReq.$_createMessage);
  static FoldListReq? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get oid => $_getI64(0);
  @$pb.TagNumber(1)
  set oid($fixnum.Int64 value) => $_setInt64(0, value);

  @$pb.TagNumber(2)
  $fixnum.Int64 get type => $_getI64(1);
  @$pb.TagNumber(2)
  set type($fixnum.Int64 value) => $_setInt64(1, value);

  @$pb.TagNumber(3)
  $core.String get extra => $_getSZ(2);
  @$pb.TagNumber(3)
  set extra($core.String value) => $_setString(2, value);

  @$pb.TagNumber(4)
  $2.FeedPagination get pagination => $_getN(3);
  @$pb.TagNumber(4)
  set pagination($2.FeedPagination value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasPagination() => $_has(3);
  @$pb.TagNumber(4)
  $2.FeedPagination ensurePagination() => $_ensure(3);
}

// FoldListResp { repeated ReplyInfo replies=1; FeedPaginationReply pagination_reply=2;
//                string title=3; SubjectControl subject_control=4; }
class FoldListResp extends $pb.GeneratedMessage {
  factory FoldListResp({
    $core.Iterable<$reply.ReplyInfo>? replies,
    $2.FeedPaginationReply? paginationReply,
    $core.String? title,
    $reply.SubjectControl? subjectControl,
  }) {
    final result = FoldListResp._();
    if (replies != null) result.replies.addAll(replies);
    if (paginationReply != null) result.paginationReply = paginationReply;
    if (title != null) result.title = title;
    if (subjectControl != null) result.subjectControl = subjectControl;
    return result;
  }

  FoldListResp._();

  factory FoldListResp.fromBuffer(
    $core.List<$core.int> data, [
    $pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY,
  ]) => FoldListResp()..mergeFromBuffer(data, registry);

  static final $pb.BuilderInfo _i2 = $pb.BuilderInfo(
    'FoldListResp',
    package: const $pb.PackageName('bilibili.main.community.reply.v1'),
    createEmptyInstance: FoldListResp.$_createMessage,
  )
    ..pPM<$reply.ReplyInfo>(1, 'replies', subBuilder: $reply.ReplyInfo.create)
    ..aOM<$2.FeedPaginationReply>(2, 'paginationReply',
        subBuilder: $2.FeedPaginationReply.create)
    ..aOS(3, 'title')
    ..aOM<$reply.SubjectControl>(4, 'subjectControl',
        subBuilder: $reply.SubjectControl.create)
    ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i2;

  @$core.Deprecated('See https://github.com/google/protobuf/issues/998.')
  FoldListResp clone() => deepCopy();

  @$core.Deprecated('See https://github.com/google/protobuf/issues/998.')
  FoldListResp copyWith(void Function(FoldListResp) updates) =>
      super.copyWith((message) => updates(message as FoldListResp))
          as FoldListResp;

  @$core.pragma('dart2js:noInline')
  static FoldListResp create() => FoldListResp._();
  static FoldListResp $_createMessage() => FoldListResp._();
  @$core.override
  FoldListResp createEmptyInstance() => FoldListResp._();
  static FoldListResp getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FoldListResp>(FoldListResp.$_createMessage);
  static FoldListResp? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$reply.ReplyInfo> get replies => $_getList(0);

  @$pb.TagNumber(2)
  $2.FeedPaginationReply get paginationReply => $_getN(1);
  @$pb.TagNumber(2)
  set paginationReply($2.FeedPaginationReply value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPaginationReply() => $_has(1);

  @$pb.TagNumber(3)
  $core.String get title => $_getSZ(2);
  @$pb.TagNumber(3)
  set title($core.String value) => $_setString(2, value);

  @$pb.TagNumber(4)
  $reply.SubjectControl get subjectControl => $_getN(3);
  @$pb.TagNumber(4)
  set subjectControl($reply.SubjectControl value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasSubjectControl() => $_has(3);
}

// MixedCard.Type { UNKNOWN=0 QUESTION=1 FOLD=2 HOTSPOT=3 }
class MixedCardType extends $pb.ProtobufEnum {
  static const MixedCardType UNKNOWN = MixedCardType._(0, 'UNKNOWN');
  static const MixedCardType QUESTION = MixedCardType._(1, 'QUESTION');
  static const MixedCardType FOLD = MixedCardType._(2, 'FOLD');
  static const MixedCardType HOTSPOT = MixedCardType._(3, 'HOTSPOT');

  static const $core.List<MixedCardType> values = <MixedCardType>[
    UNKNOWN,
    QUESTION,
    FOLD,
    HOTSPOT,
  ];

  static final $core.Map<$core.int, MixedCardType> _byValue =
      $pb.ProtobufEnum.initByValue(values);

  static MixedCardType? valueOf($core.int value) => _byValue[value];

  const MixedCardType._(super.value, super.name);
}

// FoldCard { string bottom_text = 1; FeedPagination fold_pagination = 2; }
// 注意 fold_pagination 是请求类型 FeedPagination（pageSize=1/offset=2）。
class FoldCard extends $pb.GeneratedMessage {
  factory FoldCard({
    $core.String? bottomText,
    $2.FeedPagination? foldPagination,
  }) {
    final result = FoldCard._();
    if (bottomText != null) result.bottomText = bottomText;
    if (foldPagination != null) result.foldPagination = foldPagination;
    return result;
  }

  FoldCard._();

  factory FoldCard.fromBuffer(
    $core.List<$core.int> data, [
    $pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY,
  ]) => FoldCard()..mergeFromBuffer(data, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
    'FoldCard',
    package: const $pb.PackageName('bilibili.main.community.reply.v1'),
    createEmptyInstance: FoldCard.$_createMessage,
  )
    ..aOS(1, 'bottomText')
    ..aOM<$2.FeedPagination>(2, 'foldPagination',
        subBuilder: $2.FeedPagination.create)
    ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  FoldCard clone() => deepCopy();

  FoldCard copyWith(void Function(FoldCard) updates) =>
      super.copyWith((message) => updates(message as FoldCard)) as FoldCard;

  static FoldCard create() => FoldCard._();
  static FoldCard $_createMessage() => FoldCard._();
  @$core.override
  FoldCard createEmptyInstance() => FoldCard._();
  static FoldCard getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FoldCard>(FoldCard.$_createMessage);
  static FoldCard? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get bottomText => $_getSZ(0);
  @$pb.TagNumber(1)
  set bottomText($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBottomText() => $_has(0);

  @$pb.TagNumber(2)
  $2.FeedPagination get foldPagination => $_getN(1);
  @$pb.TagNumber(2)
  set foldPagination($2.FeedPagination value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFoldPagination() => $_has(1);
  @$pb.TagNumber(2)
  $2.FeedPagination ensureFoldPagination() => $_ensure(1);
}

// MixedCard { Type type = 1; FoldCard fold = 5; }
class MixedCard extends $pb.GeneratedMessage {
  factory MixedCard({MixedCardType? type, FoldCard? fold}) {
    final result = MixedCard._();
    if (type != null) result.type = type;
    if (fold != null) result.fold = fold;
    return result;
  }

  MixedCard._();

  factory MixedCard.fromBuffer(
    $core.List<$core.int> data, [
    $pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY,
  ]) => MixedCard()..mergeFromBuffer(data, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
    'MixedCard',
    package: const $pb.PackageName('bilibili.main.community.reply.v1'),
    createEmptyInstance: MixedCard.$_createMessage,
  )
    ..aE<MixedCardType>(1, 'type', enumValues: MixedCardType.values)
    ..aOM<FoldCard>(5, 'fold', subBuilder: FoldCard.create)
    ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  MixedCard clone() => deepCopy();

  MixedCard copyWith(void Function(MixedCard) updates) =>
      super.copyWith((message) => updates(message as MixedCard)) as MixedCard;

  static MixedCard create() => MixedCard._();
  static MixedCard $_createMessage() => MixedCard._();
  @$core.override
  MixedCard createEmptyInstance() => MixedCard._();
  static MixedCard getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MixedCard>(MixedCard.$_createMessage);
  static MixedCard? _defaultInstance;

  @$pb.TagNumber(1)
  MixedCardType get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(MixedCardType value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);

  @$pb.TagNumber(5)
  FoldCard get fold => $_getN(1);
  @$pb.TagNumber(5)
  set fold(FoldCard value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasFold() => $_has(1);
  @$pb.TagNumber(5)
  FoldCard ensureFold() => $_ensure(1);
}

/// Reparse FOLD(2) and fold(5), which the generated schema keeps as unknown fields.
FoldCard? decodeFoldCardFromMixedCard($core.Object? message) {
  if (message is! $pb.GeneratedMessage) return null;
  return _decodeUsableFoldCard(message.writeToBuffer());
}

FoldCard? _decodeUsableFoldCard($core.List<$core.int> bytes) {
  try {
    final card = MixedCard.fromBuffer(bytes);
    if (card.hasType() &&
        card.type == MixedCardType.FOLD &&
        card.hasFold() &&
        card.fold.foldPagination.offset.isNotEmpty) {
      return card.fold;
    }
  } catch (_) {
    // Ignore a malformed card and allow the caller to try the next one.
  }
  return null;
}

/// Select the first usable card from DetailListReply's unknown mixed_cards(11).
FoldCard? decodeFoldCardFromUnknown($pb.GeneratedMessage message) {
  final field = message.unknownFields.getField(11);
  if (field == null) return null;
  for (final bytes in field.lengthDelimited) {
    final card = _decodeUsableFoldCard(bytes);
    if (card != null) return card;
  }
  return null;
}

