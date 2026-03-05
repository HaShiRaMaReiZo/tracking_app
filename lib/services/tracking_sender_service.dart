import 'dart:async';

import 'api_client.dart';
import 'tracking_buffer_service.dart';

class TrackingSenderService {
  TrackingSenderService(this._api, this._buffer);

  final ApiClient _api;
  final TrackingBufferService _buffer;

  static const _batchSize = 20;
  static const _initialBackoffSec = 2;
  static const _maxBackoffSec = 60;

  Timer? _timer;
  int _backoffSec = _initialBackoffSec;

  void startSending() {
    _timer?.cancel();
    _backoffSec = _initialBackoffSec;
    _scheduleSend();
  }

  void _scheduleSend() {
    _timer?.cancel();
    _timer = Timer(Duration(seconds: _backoffSec), () async {
      await _drainOnce();
      _scheduleSend();
    });
  }

  void stopSending() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _drainOnce() async {
    final pending = await _buffer.getPending(limit: _batchSize);
    if (pending.isEmpty) {
      _backoffSec = _initialBackoffSec;
      return;
    }

    if (pending.length == 1) {
      final point = pending.first;
      try {
        await _api.postTracking(point.payload);
        await _buffer.remove(point.id);
        _backoffSec = _initialBackoffSec;
      } catch (e) {
        if (ApiClient.isValidationError(e)) {
          await _buffer.remove(point.id);
          return;
        }
        if (ApiClient.isRetriableError(e)) {
          await _buffer.markRetry(point.id, ApiClient.errorMessage(e));
          _backoffSec = (_backoffSec * 2).clamp(_initialBackoffSec, _maxBackoffSec);
        } else {
          await _buffer.remove(point.id);
        }
      }
      return;
    }

    final points = pending.map((p) => p.payload).toList();
    try {
      final result = await _api.postTrackingBatch(points);
      final accepted = result['accepted'] as int? ?? 0;
      final failed = result['failed'] as List<dynamic>? ?? [];
      final acceptedIds = pending.take(accepted).map((p) => p.id).toList();
      await _buffer.removeMany(acceptedIds);
      for (final f in failed) {
        if (f is Map && f['index'] != null) {
          final idx = f['index'] as int;
          if (idx >= 0 && idx < pending.length) {
            await _buffer.remove(pending[idx].id);
          }
        }
      }
      _backoffSec = _initialBackoffSec;
    } catch (e) {
      if (ApiClient.isRetriableError(e)) {
        for (final p in pending) {
          await _buffer.markRetry(p.id, ApiClient.errorMessage(e));
        }
        _backoffSec = (_backoffSec * 2).clamp(_initialBackoffSec, _maxBackoffSec);
      } else {
        for (final p in pending) {
          await _buffer.remove(p.id);
        }
      }
    }
  }

  Future<void> sendNow() async {
    await _drainOnce();
  }
}
