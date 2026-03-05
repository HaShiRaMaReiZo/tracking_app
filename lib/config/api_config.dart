/// API base URL for the Location_tracking Laravel backend (must include /api).
/// - Android emulator: http://10.0.2.2:8000/api
/// - iOS simulator: http://127.0.0.1:8000/api
/// - Real device: http://<LAN_IP>:8000/api
/// Must end with /api so paths like /register become /api/register.
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://location-tracking-b3jv.onrender.com/api',
);

/// Optional WebSocket URL when using Laravel Reverb.
const String kWebSocketUrl = String.fromEnvironment(
  'WEB_SOCKET_URL',
  defaultValue: '',
);
