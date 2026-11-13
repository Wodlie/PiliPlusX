/// Presenter layer: decision -> row state -> widget view model.
///
/// Six files, one direction:
///
/// * [ContentPresenter] maps a composed decision onto a [ContentPresentation];
/// * [PresenterStore] holds those rows and enforces the write-back guard;
/// * [ReplyGuardBridge] projects a comment list onto presentations and suggestion
///   anchors without touching the list itself;
/// * [ReplyPresentation] is the view model a comment widget consumes;
/// * [ReplyGuardListState] holds the list-revision rules the controller adopts,
///   split out so they are executable without a controller;
/// * [replyGuardContentVersionOf] / [replyGuardCommentInputOf] are the page-side
///   adapter. They live here so the controller that registers a row and the
///   widget that renders it derive the payload revision from one function
///   instead of two copies that silently drift;
/// * [ReplyGuardPolicyFacts] / [replyGuardPolicyDigestOf] are the policy half of
///   that revision. They are value objects on purpose: the live settings are
///   read by the page layer (`replyGuardLivePolicyFacts` in the guard mixin),
///   because reading `Pref`/`ReplyGrpc` here would pull `package:get` -> `dart:ui`
///   into this barrel and stop every plain-Dart probe from running.
///
/// Everything re-exported here is pure Dart: no `package:flutter`, no
/// `BuildContext`, no `package:get`, no storage implementation. That is what lets
/// the whole layer be executed by a plain-Dart check script, and it is why the
/// store is a plain listener list instead of a `GetxController`.
///
/// A page imports this barrel and wraps [PresenterStore] in whatever reactive
/// primitive it uses; it never reaches into the decision, policy or operator
/// layers directly.
library;

export 'package:PiliPlus/services/content_guard/presenter/content_presenter.dart';
export 'package:PiliPlus/services/content_guard/presenter/presenter_store.dart';
export 'package:PiliPlus/services/content_guard/presenter/reply_guard_adapter.dart';
export 'package:PiliPlus/services/content_guard/presenter/reply_guard_bridge.dart';
export 'package:PiliPlus/services/content_guard/presenter/reply_guard_list_state.dart';
export 'package:PiliPlus/services/content_guard/presenter/reply_guard_policy_digest.dart';
export 'package:PiliPlus/services/content_guard/presenter/reply_presentation.dart';
