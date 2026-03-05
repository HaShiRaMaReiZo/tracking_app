import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

import '../config/api_config.dart';

class ApiClient {
  ApiClient({String? baseUrl, String? token}) {
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
          if (_token != null && _token!.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $_token';
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
    if (token != null) _token = token;
  }

  late final Dio _dio;
  String? _token;

  String? get token => _token;
  set token(String? value) => _token = value;

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

  Future<Map<String, dynamic>?> getSessionLive(int sessionId) async {
    try {
      final response = await _dio.get('/sessions/$sessionId/live');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<dynamic>> getSessionLocations(int sessionId) async {
    final response = await _dio.get('/sessions/$sessionId/locations');
    return response.data is List ? response.data as List<dynamic> : [];
  }

  /// POST single tracking point. Returns response body. On 4xx/5xx throws.
  Future<Map<String, dynamic>> postTracking(Map<String, dynamic> body) async {
    final response = await _dio.post('/trackings', data: body);
    return response.data as Map<String, dynamic>;
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
}
