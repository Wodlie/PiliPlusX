import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show immutable;

enum VideoSummaryProviderModelPath {
  text,
  multimodal,
}

enum VideoSummaryProviderErrorType {
  misconfigured,
  auth,
  forbidden,
  throttled,
  timeout,
  unsupportedCapability,
  server,
  invalidResponse,
  network,
  unknown,
}

sealed class VideoSummaryProviderResult<T> {
  const VideoSummaryProviderResult();

  bool get isSuccess => this is VideoSummaryProviderSuccess<T>;

  T? get dataOrNull => switch (this) {
    VideoSummaryProviderSuccess(:final data) => data,
    _ => null,
  };

  VideoSummaryProviderFailure? get errorOrNull => switch (this) {
    VideoSummaryProviderErrorResult(:final error) => error,
    _ => null,
  };
}

@immutable
class VideoSummaryProviderSuccess<T> extends VideoSummaryProviderResult<T> {
  final T data;

  const VideoSummaryProviderSuccess(this.data);
}

@immutable
class VideoSummaryProviderErrorResult<T>
    extends VideoSummaryProviderResult<T> {
  final VideoSummaryProviderFailure error;

  const VideoSummaryProviderErrorResult(this.error);
}

@immutable
class VideoSummaryProviderFailure {
  final VideoSummaryProviderErrorType type;
  final String message;
  final int? statusCode;

  const VideoSummaryProviderFailure({
    required this.type,
    required this.message,
    this.statusCode,
  });

  bool get isMisconfigured => type == VideoSummaryProviderErrorType.misconfigured;

  bool get isTimeout => type == VideoSummaryProviderErrorType.timeout;
}

@immutable
class OpenAiCompatibleSummaryResponse {
  final String text;
  final int? statusCode;
  final Map<String, dynamic>? rawData;

  const OpenAiCompatibleSummaryResponse({
    required this.text,
    this.statusCode,
    this.rawData,
  });
}

@immutable
class VideoSummaryProviderConfig {
  final String baseUrl;
  final String apiKey;
  final String textModel;
  final String multimodalModel;

  const VideoSummaryProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.textModel,
    required this.multimodalModel,
  });

  factory VideoSummaryProviderConfig.fromPref() {
    return VideoSummaryProviderConfig(
      baseUrl: Pref.aiSummaryBaseUrl,
      apiKey: Pref.aiSummaryApiKey,
      textModel: Pref.aiSummaryTextModel,
      multimodalModel: Pref.aiSummaryMultimodalModel,
    );
  }

  static Uri? parseBaseUrl(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final Uri? uri = Uri.tryParse(trimmed.endsWith('/') ? trimmed : '$trimmed/');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  Uri? get parsedBaseUrl => parseBaseUrl(baseUrl);

  String? modelFor(VideoSummaryProviderModelPath path) {
    return switch (path) {
      VideoSummaryProviderModelPath.text => textModel.trim().isEmpty
          ? null
          : textModel.trim(),
      VideoSummaryProviderModelPath.multimodal => multimodalModel.trim().isEmpty
          ? null
          : multimodalModel.trim(),
    };
  }

  VideoSummaryProviderFailure? validateShared() {
    if (parsedBaseUrl == null) {
      return const VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.misconfigured,
        message: 'Provider baseUrl 未配置或格式无效',
      );
    }
    if (apiKey.trim().isEmpty) {
      return const VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.misconfigured,
        message: 'Provider apiKey 未配置',
      );
    }
    return null;
  }

  VideoSummaryProviderFailure? validateFor(VideoSummaryProviderModelPath path) {
    final sharedFailure = validateShared();
    if (sharedFailure != null) {
      return sharedFailure;
    }
    if (modelFor(path) == null) {
      return VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.misconfigured,
        message: switch (path) {
          VideoSummaryProviderModelPath.text => 'textModel 未配置',
          VideoSummaryProviderModelPath.multimodal => 'multimodalModel 未配置',
        },
      );
    }
    return null;
  }
}

@immutable
class OpenAiCompatibleTextSummaryRequest {
  final String prompt;
  final String? systemPrompt;
  final String? title;

  const OpenAiCompatibleTextSummaryRequest({
    required this.prompt,
    this.systemPrompt,
    this.title,
  });

  Map<String, dynamic> toPayload(String model) {
    return {
      'model': model,
      'messages': [
        if (systemPrompt?.trim().isNotEmpty == true)
          {
            'role': 'system',
            'content': systemPrompt!.trim(),
          },
        {
          'role': 'user',
          'content': [
            if (title?.trim().isNotEmpty == true)
              {
                'type': 'text',
                'text': '标题：${title!.trim()}',
              },
            {
              'type': 'text',
              'text': prompt,
            },
          ],
        },
      ],
    };
  }
}

@immutable
class OpenAiCompatibleMp4VideoInput {
  final Uri url;

  const OpenAiCompatibleMp4VideoInput(this.url);

  factory OpenAiCompatibleMp4VideoInput.parse(String value) {
    final Uri? uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('视频输入必须是有效的 http/https URL');
    }
    return OpenAiCompatibleMp4VideoInput(uri);
  }
}

@immutable
class OpenAiCompatibleMultimodalSummaryRequest {
  final String prompt;
  final OpenAiCompatibleMp4VideoInput video;
  final String? systemPrompt;
  final String? title;
  final String? bvid;
  final int? cid;

  const OpenAiCompatibleMultimodalSummaryRequest({
    required this.prompt,
    required this.video,
    this.systemPrompt,
    this.title,
    this.bvid,
    this.cid,
  });

  Map<String, dynamic> toPayload(String model) {
    return {
      'model': model,
      'messages': [
        if (systemPrompt?.trim().isNotEmpty == true)
          {
            'role': 'system',
            'content': systemPrompt!.trim(),
          },
        {
          'role': 'user',
          'content': [
            if (title?.trim().isNotEmpty == true)
              {
                'type': 'text',
                'text': '标题：${title!.trim()}',
              },
            if (bvid?.trim().isNotEmpty == true)
              {
                'type': 'text',
                'text': 'BVID：${bvid!.trim()}',
              },
            if (cid != null)
              {
                'type': 'text',
                'text': 'CID：$cid',
              },
            {
              'type': 'text',
              'text': prompt,
            },
            {
              'type': 'input_video',
              'input_video': {
                'url': video.url.toString(),
              },
            },
          ],
        },
      ],
    };
  }
}
