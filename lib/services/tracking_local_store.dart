import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../db/tracking_db.dart';

class TrackingLocalStore {
  /// Insert a tracking point using the same payload map we send to the API.
  /// Expected keys: session_id, latitude, longitude, accuracy, duration, tracking_time.
  static Future<void> insertFromPayload(Map<String, dynamic> payload) async {
    final Database db = await TrackingDb.instance();

    final rawSessionId = payload['session_id'];
    final sessionId = _toInt(rawSessionId);
    if (sessionId == null) return;

    final lat = _toDouble(payload['latitude']);
    final lng = _toDouble(payload['longitude']);
    if (lat == null || lng == null) return;

    final accuracy = _toDouble(payload['accuracy']);
    final duration = _toDouble(payload['duration']);

    final rawTime = payload['tracking_time']?.toString();
    final trackingTime = _parseIsoOrNow(rawTime);

    await db.insert(TrackingDb.tableTrackingPoints, {
      'session_id': sessionId,
      'latitude': lat,
      'longitude': lng,
      'accuracy': accuracy,
      'tracking_time': trackingTime.toUtc().toIso8601String(),
      'duration': duration,
      'is_synced': 0,
    });
    debugPrint('[SQLITE] Stored point: session=$sessionId lat=$lat lng=$lng accuracy=$accuracy duration=$duration');
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static DateTime _parseIsoOrNow(String? value) {
    if (value == null || value.isEmpty) return DateTime.now().toUtc();
    try {
      return DateTime.parse(value).toUtc();
    } catch (_) {
      return DateTime.now().toUtc();
    }
  }
}

