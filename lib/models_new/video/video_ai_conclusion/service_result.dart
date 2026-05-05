import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:flutter/foundation.dart' show immutable;

sealed class AiSummaryServiceResult {
  const AiSummaryServiceResult();

  bool get isSuccess => this is AiSummaryServiceSuccess;

  AiConclusionResult get data => switch (this) {
    AiSummaryServiceSuccess(:final data) => data,
    _ => throw this,
  };

  AiConclusionResult? get dataOrNull => switch (this) {
    AiSummaryServiceSuccess(:final data) => data,
    _ => null,
  };

  String? get message => switch (this) {
    AiSummaryServiceSuccess() => null,
    AiSummaryServiceFailure(:final message) => message,
  };
}

@immutable
class AiSummaryServiceSuccess extends AiSummaryServiceResult {
  final AiConclusionResult data;

  const AiSummaryServiceSuccess(this.data);
}

@immutable
sealed class AiSummaryServiceFailure extends AiSummaryServiceResult {
  final String? message;

  const AiSummaryServiceFailure([this.message]);
}

@immutable
class AiSummaryServiceMisconfigured extends AiSummaryServiceFailure {
  const AiSummaryServiceMisconfigured([super.message]);
}

@immutable
class AiSummaryServiceUnavailable extends AiSummaryServiceFailure {
  const AiSummaryServiceUnavailable([super.message]);
}

@immutable
class AiSummaryServiceNoSubtitle extends AiSummaryServiceUnavailable {
  const AiSummaryServiceNoSubtitle([super.message]);
}

@immutable
class AiSummaryServiceProviderError extends AiSummaryServiceFailure {
  const AiSummaryServiceProviderError([super.message]);
}

@immutable
class AiSummaryServiceLegacyError extends AiSummaryServiceFailure {
  const AiSummaryServiceLegacyError([super.message]);
}
