import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import 'api_client.dart';
import 'location_filter_service.dart';
import 'tracking_buffer_service.dart';
import 'tracking_sender_service.dart';

const _keySessionId = 'bg_tracking_session_id';
const _keyDeviceId = 'bg_tracking_device_id';
const _keyToken = 'auth_token';

/// Call from main() after WidgetsFlutterBinding.ensureInitialized().
Future<void> initializeBackgroundTrackingService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundStart,
      autoStart: false,
      // Run as a normal background service to avoid
      // strict foreground-notification requirements.
      isForegroundMode: false,
      notificationChannelId: 'tracking_channel',
      foregroundServiceNotificationId: 101,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onBackgroundStart,
      onBackground: onBackgroundStart,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onBackgroundStart(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
  }
  var stopped = false;
  service.on('stopService').listen((_) {
    stopped = true;
    service.stopSelf();
  });

  final prefs = await SharedPreferences.getInstance();
  final sessionId = prefs.getInt(_keySessionId);
  final deviceId = prefs.getString(_keyDeviceId);
  if (sessionId == null || deviceId == null || deviceId.isEmpty) {
    service.stopSelf();
    return true;
  }

  final token = await _readToken();
  if (token == null || token.isEmpty) {
    service.stopSelf();
    return true;
  }

  final api = ApiClient(baseUrl: kApiBaseUrl, token: token);
  final buffer = TrackingBufferService();
  final filter = LocationFilterService();
  final sender = TrackingSenderService(api, buffer);
  sender.startSending();

  Position? lastPosition;
  DateTime? lastPositionTime;

  void tick() async {
    if (stopped) return;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
      );
      final decision = filter.shouldSend(position);
      if (!decision.accept) return;

      final now = DateTime.now();
      final trackingTime = now.toUtc().toIso8601String();
      final idempotencyKey = '${deviceId}_${position.timestamp.millisecondsSinceEpoch}';
      final payload = <String, dynamic>{
        'device_id': deviceId,
        'session_id': sessionId,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'duration': 0,
        'tracking_time': trackingTime,
        'idempotency_key': idempotencyKey,
      };
      if (position.speed >= 0) payload['speed'] = position.speed * 3.6;
      if (lastPosition != null && lastPositionTime != null) {
        payload['last_lat'] = lastPosition!.latitude;
        payload['last_lng'] = lastPosition!.longitude;
        payload['last_timestamp'] = lastPositionTime!.toUtc().toIso8601String();
      }
      lastPosition = position;
      lastPositionTime = now;
      await buffer.add(payload, idempotencyKey);
      sender.sendNow();
    } catch (_) {}
  }

  Duration intervalForSpeed(double? speedKmh) {
    if (speedKmh == null || speedKmh < 1) return const Duration(seconds: 60);
    if (speedKmh > 30) return const Duration(seconds: 4);
    return const Duration(seconds: 10);
  }

  Duration nextInterval = const Duration(seconds: 10);
  void scheduleNext() {
    Future.delayed(nextInterval, () {
      if (stopped) return;
      tick();
      nextInterval = intervalForSpeed(lastPosition != null ? lastPosition!.speed * 3.6 : null);
      scheduleNext();
    });
  }
  tick();
  scheduleNext();
  return true;
}

Future<String?> _readToken() async {
  try {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    return await storage.read(key: _keyToken);
  } catch (_) {
    return null;
  }
}

Future<void> startBackgroundTracking({required int sessionId, required String deviceId}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_keySessionId, sessionId);
  await prefs.setString(_keyDeviceId, deviceId);

  final service = FlutterBackgroundService();
  await service.startService();
}

Future<void> stopBackgroundTracking() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_keySessionId);
  await prefs.remove(_keyDeviceId);

  final service = FlutterBackgroundService();
  service.invoke('stopService');
}
