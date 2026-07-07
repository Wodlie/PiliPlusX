import 'dart:io';

import 'package:PiliPlus/models/common/video/video_summary_provider.dart';
import 'package:dio/dio.dart';

/// 仅面向 OpenAI-compatible provider。
///
/// - 文本路径只读取 `textModel`
/// - 多模态路径只读取 `multimodalModel`
/// - 多模态输入只接受完整 MP4 视频输入，不接受拆分的 DASH video/audio URL
abstract final class OpenAiCompatibleSummaryProvider {
  static const String _chatCompletionsPath = 'chat/completions';
  static final RegExp _unsupportedCapabilityPattern = RegExp(
    r'unsupported|not\s+support|capability|multimodal|video|vision|media\s+type|not\s+implemented',
    caseSensitive: false,
  );

  static Future<VideoSummaryProviderResult<OpenAiCompatibleSummaryResponse>>
  summarizeText(OpenAiCompatibleTextSummaryRequest request) {
    return _execute(
      path: VideoSummaryProviderModelPath.text,
      payloadBuilder: request.toPayload,
    );
  }

  static Future<VideoSummaryProviderResult<OpenAiCompatibleSummaryResponse>>
  summarizeMultimodal(OpenAiCompatibleMultimodalSummaryRequest request) {
    return _execute(
      path: VideoSummaryProviderModelPath.multimodal,
      payloadBuilder: request.toPayload,
    );
  }

  static Future<VideoSummaryProviderResult<OpenAiCompatibleSummaryResponse>>
  _execute({
    required VideoSummaryProviderModelPath path,
    required Map<String, dynamic> Function(String model) payloadBuilder,
  }) async {
    final config = VideoSummaryProviderConfig.fromPref();
    final Duration timeout = Duration(seconds: config.timeoutSeconds);
    final validationFailure = config.validateFor(path);
    if (validationFailure != null) {
      return VideoSummaryProviderErrorResult(validationFailure);
    }

    final Dio dio = Dio(
      BaseOptions(
        baseUrl: config.parsedBaseUrl.toString(),
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        responseType: ResponseType.json,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer ${config.apiKey.trim()}',
          HttpHeaders.contentTypeHeader: Headers.jsonContentType,
          HttpHeaders.acceptHeader: Headers.jsonContentType,
        },
        validateStatus: (_) => true,
      ),
    );

    final String model = config.modelFor(path)!;

    try {
      final Response response = await dio.post(
        _chatCompletionsPath,
        data: payloadBuilder(model),
      );
      return _mapResponse(response, path);
    } on DioException catch (error) {
      return VideoSummaryProviderErrorResult(_mapDioException(error, path));
    }
  }

  static VideoSummaryProviderResult<OpenAiCompatibleSummaryResponse>
  _mapResponse(
    Response response,
    VideoSummaryProviderModelPath path,
  ) {
    final int? statusCode = response.statusCode;
    if (statusCode != null && statusCode >= 200 && statusCode < 300) {
      final String? text = _extractResponseText(response.data);
      if (text == null || text.trim().isEmpty) {
        return const VideoSummaryProviderErrorResult(
          VideoSummaryProviderFailure(
            type: VideoSummaryProviderErrorType.invalidResponse,
            message: 'Provider 响应缺少可读取的文本内容',
          ),
        );
      }
      return VideoSummaryProviderSuccess(
        OpenAiCompatibleSummaryResponse(
          text: text.trim(),
          statusCode: statusCode,
          rawData: _asStringKeyedMap(response.data),
        ),
      );
    }

    return VideoSummaryProviderErrorResult(
      _mapStatusFailure(statusCode, response.data, path),
    );
  }

  static VideoSummaryProviderFailure _mapStatusFailure(
    int? statusCode,
    dynamic data,
    VideoSummaryProviderModelPath path,
  ) {
    final String message = _readErrorMessage(data);
    if (_isUnsupportedCapability(statusCode, message, path)) {
      return VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.unsupportedCapability,
        message: message.isEmpty ? 'Provider 不支持当前能力' : message,
        statusCode: statusCode,
      );
    }

    if (statusCode != null && statusCode >= 500) {
      return VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.server,
        message: message.isEmpty ? 'Provider 服务异常' : message,
        statusCode: statusCode,
      );
    }

    return switch (statusCode) {
      401 => VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.auth,
        message: message.isEmpty ? 'Provider 认证失败' : message,
        statusCode: statusCode,
      ),
      403 => VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.forbidden,
        message: message.isEmpty ? 'Provider 拒绝当前请求' : message,
        statusCode: statusCode,
      ),
      429 => VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.throttled,
        message: message.isEmpty ? 'Provider 请求过于频繁' : message,
        statusCode: statusCode,
      ),
      _ => VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.unknown,
        message: message.isEmpty
            ? 'Provider 请求失败（HTTP ${statusCode ?? -1}）'
            : message,
        statusCode: statusCode,
      ),
    };
  }

  static VideoSummaryProviderFailure _mapDioException(
    DioException error,
    VideoSummaryProviderModelPath path,
  ) {
    final String message = _readErrorMessage(error.response?.data);
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.timeout,
        message: message.isEmpty ? 'Provider 请求超时' : message,
        statusCode: error.response?.statusCode,
      ),
      DioExceptionType.badResponse => _mapStatusFailure(
        error.response?.statusCode,
        error.response?.data,
        path,
      ),
      DioExceptionType.connectionError ||
      DioExceptionType.badCertificate => VideoSummaryProviderFailure(
        type: VideoSummaryProviderErrorType.network,
        message: message.isEmpty ? 'Provider 网络连接失败' : message,
        statusCode: error.response?.statusCode,
      ),
      _ => VideoSummaryProviderFailure(
        type:
            _isUnsupportedCapability(
              error.response?.statusCode,
              message,
              path,
            )
            ? VideoSummaryProviderErrorType.unsupportedCapability
            : VideoSummaryProviderErrorType.unknown,
        message: message.isEmpty ? 'Provider 请求失败：${error.message}' : message,
        statusCode: error.response?.statusCode,
      ),
    };
  }

  static bool _isUnsupportedCapability(
    int? statusCode,
    String message,
    VideoSummaryProviderModelPath path,
  ) {
    if (path != VideoSummaryProviderModelPath.multimodal) {
      return false;
    }
    if (message.isEmpty) {
      return statusCode == 415 || statusCode == 501;
    }
    return statusCode == 400 ||
        statusCode == 404 ||
        statusCode == 415 ||
        statusCode == 422 ||
        statusCode == 501 ||
        _unsupportedCapabilityPattern.hasMatch(message);
  }

  static String _readErrorMessage(dynamic data) {
    if (data is String) {
      return data.trim();
    }
    if (data is Map) {
      final dynamic error = data['error'];
      if (error is Map && error['message'] is String) {
        return (error['message'] as String).trim();
      }
      if (data['message'] is String) {
        return (data['message'] as String).trim();
      }
    }
    return '';
  }

  static String? _extractResponseText(dynamic data) {
    if (data is! Map) {
      return null;
    }

    final dynamic choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }

    final dynamic firstChoice = choices.first;
    if (firstChoice is! Map) {
      return null;
    }

    final dynamic message = firstChoice['message'];
    if (message is! Map) {
      return null;
    }

    final dynamic content = message['content'];
    if (content is String) {
      return content;
    }
    if (content is List) {
      final List<String> parts = <String>[];
      for (final item in content) {
        if (item is String && item.trim().isNotEmpty) {
          parts.add(item.trim());
          continue;
        }
        if (item is Map) {
          final dynamic text = item['text'] ?? item['value'];
          if (text is String && text.trim().isNotEmpty) {
            parts.add(text.trim());
          }
        }
      }
      if (parts.isNotEmpty) {
        return parts.join('\n');
      }
    }
    return null;
  }

  static Map<String, dynamic>? _asStringKeyedMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }
}
