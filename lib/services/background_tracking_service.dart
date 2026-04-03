import 'dart:io';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'location_filter_service.dart';
import 'tracking_local_store.dart';

const _keySessionId = 'bg_tracking_session_id';
const _keyDeviceId = 'bg_tracking_device_id';

/// Call from main() after WidgetsFlutterBinding.ensureInitialized().
Future<void> initializeBackgroundTrackingService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'tracking_channel',
      foregroundServiceNotificationId: 101,
      initialNotificationTitle: 'Tracking active',
      initialNotificationContent: 'Recording your route in the background.',
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
    // Promote to foreground — notification channel is pre-created in MainActivity.kt
    // so this works even before POST_NOTIFICATIONS is granted.
    service.setAsForegroundService();
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

  final filter = LocationFilterService();

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
      final durationSeconds = lastPositionTime != null
          ? now.difference(lastPositionTime!).inSeconds
          : 0;
      final idempotencyKey = '${deviceId}_${position.timestamp.millisecondsSinceEpoch}';
      final payload = <String, dynamic>{
        'device_id': deviceId,
        'session_id': sessionId,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'duration': durationSeconds,
        'tracking_time': trackingTime,
        'idempotency_key': idempotencyKey,
      };
      if (position.speed >= 0) {
        payload['speed'] = position.speed * 3.6;
      } else if (lastPosition != null && lastPositionTime != null && durationSeconds > 0) {
        final distanceM = Geolocator.distanceBetween(
          lastPosition!.latitude,
          lastPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        final speedKmh = (distanceM / 1000) / (durationSeconds / 3600);
        if (speedKmh >= 0) payload['speed'] = speedKmh;
      }
      if (lastPosition != null && lastPositionTime != null) {
        payload['last_lat'] = lastPosition!.latitude;
        payload['last_lng'] = lastPosition!.longitude;
        payload['last_timestamp'] = lastPositionTime!.toUtc().toIso8601String();
      }
      lastPosition = position;
      lastPositionTime = now;
      // Store locally only. All points are uploaded in one batch when the session stops.
      await TrackingLocalStore.insertFromPayload(payload);
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

Future<void> startBackgroundTracking({required int sessionId, required String deviceId}) async {
  // Android 13+ requires POST_NOTIFICATIONS to show the foreground service notification.
  if (Platform.isAndroid) {
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      await Permission.notification.request();
    }
  }

  // Stop any existing background isolate first so stale code never runs.
  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
    // Give the isolate time to exit before starting a new one.
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_keySessionId, sessionId);
  await prefs.setString(_keyDeviceId, deviceId);

  await service.startService();
}

Future<void> stopBackgroundTracking() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_keySessionId);
  await prefs.remove(_keyDeviceId);

  final service = FlutterBackgroundService();
  service.invoke('stopService');
}
