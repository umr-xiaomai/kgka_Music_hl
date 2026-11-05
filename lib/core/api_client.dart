import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  String? token;
  String? t1;
  String? sessionId;

  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) {
    return _sendWithRetry(
      () => _client.get(AppConfig.apiUri(path, query), headers: _headers),
    );
  }

  /// 直接请求外部 URI（不经过 AppConfig.apiUri），返回原始 JSON。
  /// 用于跨平台 API 调用（如网易云 API、酷狗搜索提示）。
  Future<dynamic> getRaw(Uri uri, {Map<String, String>? headers}) {
    return _sendWithRetry(() => _client.get(uri, headers: {
          'Accept': 'application/json',
          ...?headers,
        }));
  }

  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) {
    return _sendWithRetry(
      () => _client.post(
        AppConfig.apiUri(path, query),
        headers: _headers,
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };

    if (token case final value? when value.isNotEmpty) {
      headers['X-Kg-Session-Id'] = value;
    }
    if (t1 case final value? when value.isNotEmpty) {
      headers['t1'] = value;
    }
    if (sessionId case final value? when value.isNotEmpty) {
      headers['X-Kg-Session-Id'] = value;
    }

    return headers;
  }

  /// 带自动重试的请求发送。
  ///
  /// 对连接超时、5xx 服务器错误自动重试，指数退避（500ms、1s）。
  /// 其他错误（如 4xx、格式异常）不重试，直接抛出。
  Future<dynamic> _sendWithRetry(
    Future<http.Response> Function() request, {
    int maxRetries = 2,
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await request();
        // 5xx 服务器错误可重试
        if (response.statusCode >= 500 && attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
          continue;
        }
        return await _processResponse(response);
      } on http.ClientException {
        // 网络连接异常（连接超时、断网等），重试
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
          continue;
        }
        rethrow;
      } on FormatException {
        // 非 5xx 的格式异常不重试
        rethrow;
      }
    }
    // 理论上不会到达这里，但为了保证编译器认为有返回值
    throw ApiException('请求失败，已重试 $maxRetries 次');
  }

  /// 处理响应：更新 sessionId、校验状态码、解码 JSON。
  Future<dynamic> _processResponse(http.Response response) {
    final responseSessionId = response.headers['x-kg-session-id'];
    if (responseSessionId != null && responseSessionId.isNotEmpty) {
      sessionId = responseSessionId;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.body, statusCode: response.statusCode);
    }
    if (response.body.trim().isEmpty) {
      return Future.value(null);
    }
    try {
      final decoded = jsonDecode(response.body);
      return Future.value(unwrapData(decoded));
    } on FormatException {
      return Future.value(response.body);
    }
  }

  void close() => _client.close();
}

dynamic unwrapData(dynamic json) {
  if (json is Map<String, dynamic>) {
    final data = json['data'];
    if (data != null) {
      return data;
    }
  }
  return json;
}
