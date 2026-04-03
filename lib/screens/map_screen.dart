import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/background_tracking_service.dart';
import '../services/location_filter_service.dart';
import '../services/tracking_local_store.dart';
import '../services/tracking_upload_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.authService,
    required this.sessionId,
    required this.deviceId,
    this.onSessionStopped,
    this.readOnly = false,
  });

  final AuthService authService;
  final int sessionId;
  final String deviceId;
  final VoidCallback? onSessionStopped;
  final bool readOnly;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<LatLng> _points = [];
  Map<String, dynamic>? _live;
  bool _loading = true;
  String? _error;
  final MapController _mapController = MapController();

  LocationFilterService? _filter;
  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;
  DateTime? _lastPositionTime;
  bool _cameraMoved = false;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    if (widget.readOnly) {
      _loadLocations();
    } else {
      _loading = false;
      _startTracking();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    if (!widget.readOnly) stopBackgroundTracking();
    super.dispose();
  }

  Future<void> _startTracking() async {
    debugPrint('[TRACKING] _startTracking() called for session ${widget.sessionId}');

    var status = await Geolocator.checkPermission();
    debugPrint('[TRACKING] Location permission status: $status');
    if (status == LocationPermission.denied) {
      status = await Geolocator.requestPermission();
      debugPrint('[TRACKING] Permission after request: $status');
      if (status == LocationPermission.denied ||
          status == LocationPermission.deniedForever) {
        debugPrint('[TRACKING] Permission denied — cannot track');
        if (mounted) setState(() => _error = 'Location permission denied.');
        return;
      }
    }

    // Check if location service is enabled at all.
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    debugPrint('[TRACKING] Location service enabled: $serviceEnabled');
    if (!serviceEnabled) {
      if (mounted) setState(() => _error = 'Location services are off. Enable GPS.');
      return;
    }

    // Show last known position immediately — no waiting for a GPS fix.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        debugPrint('[TRACKING] Last known position: ${last.latitude}, ${last.longitude} accuracy=${last.accuracy}m');
        if (mounted) {
          final center = LatLng(last.latitude, last.longitude);
          setState(() {
            _live = {
              'latitude': last.latitude,
              'longitude': last.longitude,
              'accuracy': last.accuracy,
            };
          });
          _mapController.move(center, 16);
          _cameraMoved = true;
        }
      } else {
        debugPrint('[TRACKING] No last known position available');
      }
    } catch (e) {
      debugPrint('[TRACKING] getLastKnownPosition error: $e');
    }

    _filter = LocationFilterService();
    debugPrint('[TRACKING] Position stream starting...');

    // Use a position stream for continuous live updates.
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(
      _onPosition,
      onError: (e) {
        debugPrint('[TRACKING] Position stream error: $e');
      },
    );

    startBackgroundTracking(
        sessionId: widget.sessionId, deviceId: widget.deviceId);
    debugPrint('[TRACKING] Background tracking started');
  }

  void _onPosition(Position position) async {
    if (!mounted || widget.readOnly) return;

    debugPrint('[GPS] Raw fix: ${position.latitude}, ${position.longitude} '
        'accuracy=${position.accuracy}m speed=${position.speed}m/s');

    final now = DateTime.now();
    final trackingTime = now.toUtc().toIso8601String();

    // Always update the live marker so the user can see themselves instantly.
    final uiPoint = LatLng(position.latitude, position.longitude);
    if (mounted) {
      setState(() {
        _live = {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'tracking_time': trackingTime,
          'speed': position.speed >= 0 ? position.speed * 3.6 : null,
          'updated_at': now.toUtc().toIso8601String(),
        };
      });
      // Move camera to first real fix.
      if (!_cameraMoved) {
        _cameraMoved = true;
        debugPrint('[GPS] Moving camera to first fix: ${uiPoint.latitude}, ${uiPoint.longitude}');
        _mapController.move(uiPoint, 16);
      }
    }

    // Apply the filter to decide whether this point is worth storing.
    final decision = _filter!.shouldSend(position);
    if (!decision.accept) {
      debugPrint('[GPS] Point REJECTED by filter: ${decision.reason}');
      return;
    }
    debugPrint('[GPS] Point ACCEPTED — storing to SQLite');

    final durationSeconds = _lastPositionTime != null
        ? now.difference(_lastPositionTime!).inSeconds
        : 0;
    final idempotencyKey =
        '${widget.deviceId}_${position.timestamp.millisecondsSinceEpoch}';
    final payload = <String, dynamic>{
      'device_id': widget.deviceId,
      'session_id': widget.sessionId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'duration': durationSeconds,
      'tracking_time': trackingTime,
      'idempotency_key': idempotencyKey,
    };
    // Use device-reported speed when available; otherwise compute from distance/duration
    if (position.speed >= 0) {
      payload['speed'] = position.speed * 3.6;
    } else if (_lastPosition != null && _lastPositionTime != null && durationSeconds > 0) {
      final distanceM = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      final speedKmh = (distanceM / 1000) / (durationSeconds / 3600);
      if (speedKmh >= 0) payload['speed'] = speedKmh;
    }
    if (_lastPosition != null && _lastPositionTime != null) {
      payload['last_lat'] = _lastPosition!.latitude;
      payload['last_lng'] = _lastPosition!.longitude;
      payload['last_timestamp'] = _lastPositionTime!.toUtc().toIso8601String();
    }
    _lastPosition = position;
    _lastPositionTime = now;

    // Persist locally. All points are uploaded in one call when the session stops.
    await TrackingLocalStore.insertFromPayload(payload);

    // Extend the polyline with every accepted point.
    if (mounted) {
      setState(() {
        _points = [..._points, uiPoint];
      });
      debugPrint('[GPS] Polyline now has ${_points.length} points');
    }
  }

  Future<void> _loadLocations() async {
    setState(() => _loading = true);
    try {
      final list = await widget.authService.apiClient
          .getSessionLocations(widget.sessionId);
      if (!mounted) return;
      final points = <LatLng>[];
      for (final loc in list) {
        if (loc is! Map<String, dynamic>) continue;
        // API shape (example): { start_tracking: { snapped_points: [{ snapped_lat, snapped_lon }] }, ... }
        final start = loc['start_tracking'] as Map<String, dynamic>?;
        final startSnap = _firstSnapPoint(start);
        if (startSnap != null) {
          points.add(LatLng(
            _toDouble(startSnap['snapped_lat']),
            _toDouble(startSnap['snapped_lon']),
          ));
        }

        final end = loc['end_tracking'] as Map<String, dynamic>?;
        final endSnap = _firstSnapPoint(end);
        if (endSnap != null) {
          points.add(LatLng(
            _toDouble(endSnap['snapped_lat']),
            _toDouble(endSnap['snapped_lon']),
          ));
        }
      }
      setState(() {
        _points = points;
        _loading = false;
      });
      if (points.isNotEmpty) {
        _mapController.move(points.last, 14);
      } else {
        _setInitialCenterFromDevice();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ApiClient.errorMessage(e);
        _loading = false;
      });
    }
  }

  // Safe conversion: Eloquent may return lat/lng as strings.
  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.parse(v.toString());
  }

  static Map<String, dynamic>? _firstSnapPoint(Map<String, dynamic>? tracking) {
    if (tracking == null) return null;
    final snaps = tracking['snapped_points'];
    if (snaps is List && snaps.isNotEmpty && snaps.first is Map) {
      return Map<String, dynamic>.from(snaps.first as Map);
    }
    return null;
  }

  Future<void> _setInitialCenterFromDevice() async {
    try {
      var status = await Geolocator.checkPermission();
      if (status == LocationPermission.denied) {
        status = await Geolocator.requestPermission();
      }
      if (status == LocationPermission.denied ||
          status == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      if (!mounted) return;
      final center = LatLng(position.latitude, position.longitude);
      setState(() {
        _live = {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
        };
      });
      _mapController.move(center, 16);
    } catch (_) {}
  }

  Future<void> _stopSession() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    debugPrint('[STOP] Stop button pressed — session ${widget.sessionId}');
    // Stop live tracking first.
    _positionSub?.cancel();
    await stopBackgroundTracking();
    debugPrint('[STOP] Tracking stopped. Starting upload...');

    // Upload all locally stored points for this session.
    try {
      await TrackingUploadService(widget.authService.apiClient)
          .uploadSession(widget.sessionId);
      debugPrint('[STOP] Upload complete');
    } catch (e) {
      debugPrint('[STOP] Upload error: $e');
      if (!mounted) return;
      setState(() {
        _error = ApiClient.errorMessage(e);
        _stopping = false;
      });
      // Do NOT stop the session on the server if upload failed.
      return;
    }

    const maxAttempts = 3;
    const retryDelays = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await widget.authService.apiClient.stopSession(widget.sessionId);
        widget.onSessionStopped?.call();
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      } catch (e) {
        if (!mounted) return;
        final isRetriable = ApiClient.isRetriableError(e);
        if (!isRetriable || attempt == maxAttempts - 1) {
          setState(() {
            _error = ApiClient.errorMessage(e);
            _stopping = false;
          });
          return;
        }
        if (attempt < retryDelays.length) {
          await Future<void>.delayed(retryDelays[attempt]);
        }
      }
    }
  }

  Future<void> _goToMyLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(
              () => _error = 'Location services are disabled on this device.');
        }
        return;
      }
      var status = await Geolocator.checkPermission();
      if (status == LocationPermission.denied) {
        status = await Geolocator.requestPermission();
      }
      if (status == LocationPermission.denied ||
          status == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() =>
              _error = 'Location permission denied. Enable in system settings.');
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      if (!mounted) return;
      final center = LatLng(position.latitude, position.longitude);
      setState(() {
        _live ??= {};
        _live!['latitude'] = position.latitude;
        _live!['longitude'] = position.longitude;
        _live!['accuracy'] = position.accuracy;
      });
      _mapController.move(center, 16);
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to get current location.');
    }
  }

  @override
  Widget build(BuildContext context) {
    LatLng center = const LatLng(16.8661, 96.1951); // Yangon default
    if (_live != null &&
        _live!['latitude'] != null &&
        _live!['longitude'] != null) {
      center = LatLng(
        (_live!['latitude'] as num).toDouble(),
        (_live!['longitude'] as num).toDouble(),
      );
    } else if (_points.isNotEmpty) {
      center = _points.last;
    }

    return Scaffold(
      appBar: AppBar(
        title:
            Text(widget.readOnly ? 'Session ${widget.sessionId}' : 'Tracking'),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: center, initialZoom: 16),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.tracking.tracking_app',
              ),
              if (_points.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                        points: _points,
                        color: Colors.blue,
                        strokeWidth: 4),
                  ],
                ),
              if (_live != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        (_live!['latitude'] as num).toDouble(),
                        (_live!['longitude'] as num).toDouble(),
                      ),
                      width: 40,
                      height: 40,
                      child: const _CurrentLocationMarker(),
                    ),
                  ],
                ),
            ],
          ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(child: Text(_error!)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _error = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!widget.readOnly)
            FloatingActionButton(
              heroTag: 'stop',
              onPressed: _stopping ? null : _stopSession,
              backgroundColor: _stopping ? Colors.red.shade300 : Colors.red,
              child: _stopping
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Icon(Icons.stop, color: Colors.white),
            ),
          if (!widget.readOnly) const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'my_location',
            onPressed: _goToMyLocation,
            child: const Icon(Icons.my_location),
          ),
        ],
      ),
    );
  }
}

class _CurrentLocationMarker extends StatelessWidget {
  const _CurrentLocationMarker();

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: _size,
      height: _size,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary.withValues(alpha: 0.2),
                border: Border.all(color: primary, width: 2),
              ),
            ),
            Container(
              width: _size * 0.35,
              height: _size * 0.35,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
