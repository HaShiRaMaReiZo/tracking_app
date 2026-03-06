import 'package:flutter/foundation.dart';

import '../db/tracking_db.dart';
import 'api_client.dart';

class TrackingUploadService {
  TrackingUploadService(this._apiClient);

  final ApiClient _apiClient;

  /// Upload all unsynced points for the given session.
  /// Keeps local data if network/server fails.
  Future<void> uploadSession(int sessionId) async {
    final db = await TrackingDb.instance();
    final rows = await db.query(
      TrackingDb.tableTrackingPoints,
      where: 'session_id = ? AND is_synced = 0',
      whereArgs: [sessionId],
      orderBy: 'tracking_time ASC',
    );
    debugPrint('[UPLOAD] Session $sessionId: found ${rows.length} unsynced rows in SQLite');
    if (rows.isEmpty) return;

    // Convert to API payload shape reusing /trackings/batch endpoint.
    final points = rows
        .map((row) => <String, dynamic>{
              'session_id': row['session_id'],
              'device_id': 'local',
              'latitude': row['latitude'],
              'longitude': row['longitude'],
              'accuracy': row['accuracy'],
              'duration': row['duration'] ?? 0,
              'tracking_time': row['tracking_time'],
            })
        .toList();

    // Chunk very long trips into multiple batch requests to avoid oversize payloads.
    const batchSize = 1000;
    try {
      for (var i = 0; i < points.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, points.length);
        final slice = points.sublist(i, end);
        debugPrint('[UPLOAD] Sending batch ${i ~/ batchSize + 1}: ${slice.length} points');
        await _apiClient.postTrackingBatch(
          slice.map((p) => Map<String, dynamic>.from(p)).toList(),
        );
        debugPrint('[UPLOAD] Batch sent successfully');
      }
      await db.update(
        TrackingDb.tableTrackingPoints,
        {'is_synced': 1},
        where: 'session_id = ? AND is_synced = 0',
        whereArgs: [sessionId],
      );
      debugPrint('[UPLOAD] All rows marked as synced');
    } catch (e) {
      debugPrint('[UPLOAD] ERROR sending batch: $e — rows kept for retry');
    }
  }
}

