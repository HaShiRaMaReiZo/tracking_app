import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

import '../config/api_config.dart';

class ApiClient {
  ApiClient({String? baseUrl, String? initialToken}) {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ?? kApiBaseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
      ),
    );
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final t = token;
          if (t != null && t.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $t';
          }
          return handler.next(options);
        },
      ),
    );
    _dio.interceptors.add(
      PrettyDioLogger(
        logPrint: (o) => debugPrint(o.toString()),
        requestHeader: true,
        requestBody: true,
        responseBody: true,
        responseHeader: false,
        error: true,
      ),
    );
    if (initialToken != null) token = initialToken;
  }

  late final Dio _dio;
  String? token;

  String get baseUrl => _dio.options.baseUrl;

  // --- Auth (no token required) ---

  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final response = await _dio.post(
      '/register',
      data: {'name': name, 'email': email, 'password': password},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final response = await _dio.post(
      '/login',
      data: {'email': email, 'password': password},
    );
    return response.data as Map<String, dynamic>;
  }

  // --- Authenticated ---

  Future<Map<String, dynamic>> getUser() async {
    final response = await _dio.get('/user');
    return response.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getSessions() async {
    final response = await _dio.get('/sessions');
    return response.data is List ? response.data as List<dynamic> : [];
  }

  Future<Map<String, dynamic>> startSession({String? name}) async {
    final response = await _dio.post(
      '/sessions/start',
      data: name != null ? {'name': name} : null,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> stopSession(int sessionId) async {
    await _dio.post('/sessions/$sessionId/stop');
  }

  Future<List<dynamic>> getSessionLocations(int sessionId) async {
    // Backends in the wild differ:
    // - some return a raw list at GET /sessions/{id}/locations
    // - others return a Laravel Resource collection: { "data": [ ... ] }
    // - others expose the same collection under /location-history?session_id={id}
    try {
      final response = await _dio.get('/sessions/$sessionId/locations');
      return _extractListFromResponse(response.data);
    } on DioException catch (e) {
      // If the endpoint doesn't exist (or method not allowed), try the alternative.
      final status = e.response?.statusCode;
      if (status == 404 || status == 405) {
        final response = await _dio.get(
          '/location-history',
          queryParameters: {'session_id': sessionId},
        );
        return _extractListFromResponse(response.data);
      }
      rethrow;
    }
  }

  /// POST batch of points. Returns { accepted, failed }. On 5xx throws.
  Future<Map<String, dynamic>> postTrackingBatch(
    List<Map<String, dynamic>> points,
  ) async {
    final response = await _dio.post(
      '/trackings/batch',
      data: {'points': points},
    );
    return response.data as Map<String, dynamic>;
  }

  /// Check if error is server error (5xx) or network – for retry logic.
  static bool isRetriableError(dynamic error) {
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        return true;
      }
      final status = error.response?.statusCode;
      if (status != null && status >= 500) return true;
      return false;
    }
    return false;
  }

  /// Check if error is validation (4xx) – do not retry same payload.
  static bool isValidationError(dynamic error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      return status != null && status >= 400 && status < 500;
    }
    return false;
  }

  /// Extract a short, user-friendly message from API error response.
  static String errorMessage(dynamic error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      // Common socket-level wording on Android: "Connection reset by peer".
      final lower = (error.message ?? '').toLowerCase();
      if (error.type == DioExceptionType.connectionError &&
          (lower.contains('connection reset') || lower.contains('reset by peer'))) {
        return 'Connection was reset by the server. Try again (or switch network/VPN) and check the API is healthy.';
      }
      if (status == 404) {
        return 'Not found (404). Check that API base URL ends with /api.';
      }
      final data = error.response?.data;
      if (data is Map && data.containsKey('message')) {
        final msg = data['message'];
        if (msg is String) return msg;
        if (msg is List && msg.isNotEmpty) return msg.first.toString();
      }
      if (status != null) return 'Request failed ($status).';
      return error.message ?? 'Request failed';
    }
    return error.toString();
  }

  static List<dynamic> _extractListFromResponse(dynamic data) {
    if (data is List) return data;
    if (data is Map && data['data'] is List) return data['data'] as List;
    return const <dynamic>[];
  }
}
