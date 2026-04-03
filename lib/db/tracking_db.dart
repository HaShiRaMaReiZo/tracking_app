import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class TrackingDb {
  static const _dbName = 'tracking_local.db';
  static const tableTrackingPoints = 'tracking_points';

  static Database? _db;

  static Future<Database> instance() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE $tableTrackingPoints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            accuracy REAL,
            tracking_time TEXT NOT NULL,
            duration REAL,
            speed REAL,
            device_id TEXT,
            last_lat REAL,
            last_lng REAL,
            last_timestamp TEXT,
            idempotency_key TEXT,
            is_synced INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_tracking_session_time ON $tableTrackingPoints(session_id, tracking_time)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE $tableTrackingPoints ADD COLUMN speed REAL',
          );
          await db.execute(
            'ALTER TABLE $tableTrackingPoints ADD COLUMN device_id TEXT',
          );
          await db.execute(
            'ALTER TABLE $tableTrackingPoints ADD COLUMN last_lat REAL',
          );
          await db.execute(
            'ALTER TABLE $tableTrackingPoints ADD COLUMN last_lng REAL',
          );
          await db.execute(
            'ALTER TABLE $tableTrackingPoints ADD COLUMN last_timestamp TEXT',
          );
          await db.execute(
            'ALTER TABLE $tableTrackingPoints ADD COLUMN idempotency_key TEXT',
          );
        }
      },
    );
    return _db!;
  }
}
