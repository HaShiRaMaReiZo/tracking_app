import 'dart:convert';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Single buffered point (pending send or failed).
class BufferedPoint {
  BufferedPoint({
    required this.id,
    required this.payloadJson,
    required this.idempotencyKey,
    required this.createdAt,
    this.retryCount = 0,
    this.lastError,
  });

  final int id;
  final String payloadJson;
  final String idempotencyKey;
  final DateTime createdAt;
  final int retryCount;
  final String? lastError;

  Map<String, dynamic> get payload => Map<String, dynamic>.from(
        jsonDecode(payloadJson) as Map<dynamic, dynamic>,
      );

  static const tableName = 'tracking_buffer';
  static const maxBufferSize = 500;
  static const maxAgeHours = 24;
}

class TrackingBufferService {
  static Database? _db;

  static Future<Database> _getDb() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'tracking_buffer.db');
    _db = await openDatabase(path, version: 1, onCreate: (db, _) {
      db.execute('''
        CREATE TABLE ${BufferedPoint.tableName} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          payload_json TEXT NOT NULL,
          idempotency_key TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          retry_count INTEGER NOT NULL DEFAULT 0,
          last_error TEXT
        )
      ''');
      db.execute('CREATE INDEX idx_created ON ${BufferedPoint.tableName}(created_at)');
    });
    return _db!;
  }

  Future<void> add(Map<String, dynamic> payload, String idempotencyKey) async {
    final db = await _getDb();
    await db.insert(BufferedPoint.tableName, {
      'payload_json': jsonEncode(payload),
      'idempotency_key': idempotencyKey,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'retry_count': 0,
    });
    await _trim();
  }

  Future<void> _trim() async {
    final db = await _getDb();
    final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${BufferedPoint.tableName}'),
        ) ??
        0;
    if (count > BufferedPoint.maxBufferSize) {
      final toRemove = count - BufferedPoint.maxBufferSize;
      final ids = await db.rawQuery(
        'SELECT id FROM ${BufferedPoint.tableName} ORDER BY created_at ASC LIMIT $toRemove',
      );
      for (final row in ids) {
        await db.delete(BufferedPoint.tableName, where: 'id = ?', whereArgs: [row['id']]);
      }
    }
    final cutoff = DateTime.now().subtract(const Duration(hours: BufferedPoint.maxAgeHours)).millisecondsSinceEpoch;
    await db.delete(BufferedPoint.tableName, where: 'created_at < ?', whereArgs: [cutoff]);
  }

  Future<List<BufferedPoint>> getPending({int limit = 20}) async {
    final db = await _getDb();
    final rows = await db.query(
      BufferedPoint.tableName,
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(_rowToPoint).toList();
  }

  BufferedPoint _rowToPoint(Map<String, dynamic> row) {
    return BufferedPoint(
      id: row['id'] as int,
      payloadJson: row['payload_json'] as String,
      idempotencyKey: row['idempotency_key'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      retryCount: row['retry_count'] as int? ?? 0,
      lastError: row['last_error'] as String?,
    );
  }

  Future<void> remove(int id) async {
    final db = await _getDb();
    await db.delete(BufferedPoint.tableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> removeMany(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _getDb();
    await db.delete(
      BufferedPoint.tableName,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  Future<void> markRetry(int id, String error) async {
    final db = await _getDb();
    final rows = await db.query(BufferedPoint.tableName, columns: ['retry_count'], where: 'id = ?', whereArgs: [id]);
    final current = rows.isNotEmpty ? (rows.first['retry_count'] as int? ?? 0) : 0;
    await db.update(
      BufferedPoint.tableName,
      {'retry_count': current + 1, 'last_error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> pendingCount() async {
    final db = await _getDb();
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${BufferedPoint.tableName}'),
        ) ??
        0;
  }

  /// Removes buffered points whose payload has a different session_id.
  /// Call when starting tracking for a session so only current session points are sent.
  Future<void> clearWhereSessionIdNot(int sessionId) async {
    final db = await _getDb();
    final rows = await db.query(
      BufferedPoint.tableName,
      columns: ['id', 'payload_json'],
    );
    final idsToRemove = <int>[];
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload_json'] as String) as Map<dynamic, dynamic>;
        final sid = payload['session_id'];
        if (sid == null) continue;
        final sidInt = sid is int ? sid : (sid is num ? sid.toInt() : int.tryParse(sid.toString()));
        if (sidInt != null && sidInt != sessionId) {
          idsToRemove.add(row['id'] as int);
        }
      } catch (_) {}
    }
    if (idsToRemove.isNotEmpty) await removeMany(idsToRemove);
  }
}
