import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import '../config/api_config.dart';

class AuthService {
  AuthService() {
    _api = ApiClient(baseUrl: kApiBaseUrl);
    _storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
  }

  late final ApiClient _api;
  late final FlutterSecureStorage _storage;

  static const _keyToken = 'auth_token';
  static const _keyUserId = 'user_id';

  ApiClient get apiClient => _api;

  bool get isLoggedIn => _api.token != null && _api.token!.isNotEmpty;

  Future<void> init() async {
    final token = await _storage.read(key: _keyToken);
    if (token != null) _api.token = token;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final data = await _api.login(email: email, password: password);
    final token = data['token'] as String?;
    if (token == null) throw Exception('No token in response');
    await _storage.write(key: _keyToken, value: token);
    _api.token = token;
    final user = data['user'] as Map<String, dynamic>?;
    if (user != null && user['id'] != null) {
      await _storage.write(key: _keyUserId, value: user['id'].toString());
    }
    return data;
  }

  Future<Map<String, dynamic>> register(
    String name,
    String email,
    String password,
  ) async {
    final data = await _api.register(name: name, email: email, password: password);
    final token = data['token'] as String?;
    if (token == null) throw Exception('No token in response');
    await _storage.write(key: _keyToken, value: token);
    _api.token = token;
    final user = data['user'] as Map<String, dynamic>?;
    if (user != null && user['id'] != null) {
      await _storage.write(key: _keyUserId, value: user['id'].toString());
    }
    return data;
  }

  Future<void> logout() async {
    _api.token = null;
    await _storage.delete(key: _keyToken);
    await _storage.delete(key: _keyUserId);
  }

  Future<String?> getUserId() async => _storage.read(key: _keyUserId);
  Future<String?> getToken() async => _storage.read(key: _keyToken);
}
