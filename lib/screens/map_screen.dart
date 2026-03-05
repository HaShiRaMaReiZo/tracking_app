import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/background_tracking_service.dart';
import '../services/location_filter_service.dart';
import '../services/tracking_buffer_service.dart';
import '../services/tracking_sender_service.dart';

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
  LatLng? _initialCenter;
  bool _loading = true;
  String? _error;
  final MapController _mapController = MapController();

  LocationFilterService? _filter;
  TrackingBufferService? _buffer;
  TrackingSenderService? _sender;
  Timer? _trackingTimer;
  Position? _lastPosition;
  DateTime? _lastPositionTime;

  @override
  void initState() {
    super.initState();
    _loadLocations();
    if (!widget.readOnly) {
      _pollLive();
      _startTracking();
    }
  }

  @override
  void dispose() {
    _trackingTimer?.cancel();
    _sender?.stopSending();
    if (!widget.readOnly) stopBackgroundTracking();
    super.dispose();
  }

  Future<void> _startTracking() async {
    final status = await Geolocator.checkPermission();
    if (status == LocationPermission.denied) {
      final requested = await Geolocator.requestPermission();
      if (requested == LocationPermission.denied || requested == LocationPermission.deniedForever) return;
    }
    _filter = LocationFilterService();
    _buffer = TrackingBufferService();
    await _buffer!.clearWhereSessionIdNot(widget.sessionId);
    _sender = TrackingSenderService(widget.authService.apiClient, _buffer!);
    _sender!.startSending();

    void tick() async {
      if (!mounted || widget.readOnly) return;
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
        );
        final decision = _filter!.shouldSend(position);
        if (!decision.accept) return;

        final now = DateTime.now();
        final trackingTime = now.toUtc().toIso8601String();
        final idempotencyKey = '${widget.deviceId}_${position.timestamp.millisecondsSinceEpoch}';
        final payload = <String, dynamic>{
          'device_id': widget.deviceId,
          'session_id': widget.sessionId,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'duration': 0,
          'tracking_time': trackingTime,
          'idempotency_key': idempotencyKey,
        };
        if (position.speed >= 0) payload['speed'] = position.speed * 3.6;
        if (_lastPosition != null && _lastPositionTime != null) {
          payload['last_lat'] = _lastPosition!.latitude;
          payload['last_lng'] = _lastPosition!.longitude;
          payload['last_timestamp'] = _lastPositionTime!.toUtc().toIso8601String();
        }
        _lastPosition = position;
        _lastPositionTime = now;
        await _buffer!.add(payload, idempotencyKey);
        _sender!.sendNow();
        if (mounted) setState(() => _points = [..._points, LatLng(position.latitude, position.longitude)]);
      } catch (_) {}
    }

    Duration intervalForSpeed(double? speedKmh) {
      if (speedKmh == null || speedKmh < 1) return const Duration(seconds: 60);
      if (speedKmh > 30) return const Duration(seconds: 4);
      return const Duration(seconds: 10);
    }

    Duration nextInterval = const Duration(seconds: 10);
    void scheduleNext() {
      _trackingTimer?.cancel();
      _trackingTimer = Timer(nextInterval, () {
        tick();
        nextInterval = intervalForSpeed(_lastPosition?.speed != null ? _lastPosition!.speed * 3.6 : null);
        scheduleNext();
      });
    }
    tick();
    scheduleNext();
    startBackgroundTracking(sessionId: widget.sessionId, deviceId: widget.deviceId);
  }

  Future<void> _loadLocations() async {
    setState(() => _loading = true);
    try {
      final list = await widget.authService.apiClient.getSessionLocations(widget.sessionId);
      if (!mounted) return;
      final points = <LatLng>[];
      for (final loc in list) {
        if (loc is! Map<String, dynamic>) continue;
        final start = loc['start_tracking'] as Map<String, dynamic>?;
        if (start != null && start['latitude'] != null && start['longitude'] != null) {
          points.add(LatLng((start['latitude'] as num).toDouble(), (start['longitude'] as num).toDouble()));
        }
        if (loc['end_tracking'] is Map) {
          final end = loc['end_tracking'] as Map<String, dynamic>;
          if (end['latitude'] != null && end['longitude'] != null) {
            points.add(LatLng((end['latitude'] as num).toDouble(), (end['longitude'] as num).toDouble()));
          }
        }
      }
      setState(() => _points = points);
      if (points.isEmpty) {
        await _setInitialCenterFromDevice();
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ApiClient.errorMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _setInitialCenterFromDevice() async {
    try {
      var status = await Geolocator.checkPermission();
      if (status == LocationPermission.denied) {
        status = await Geolocator.requestPermission();
      }
      if (status == LocationPermission.denied || status == LocationPermission.deniedForever) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      if (mounted) setState(() {
        _initialCenter = LatLng(position.latitude, position.longitude);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pollLive() async {
    while (mounted && !widget.readOnly) {
      try {
        final live = await widget.authService.apiClient.getSessionLive(widget.sessionId);
        if (mounted && live != null && live['latitude'] != null && live['longitude'] != null) {
          setState(() => _live = live);
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _stopSession() async {
    try {
      await stopBackgroundTracking();
      await widget.authService.apiClient.stopSession(widget.sessionId);
      widget.onSessionStopped?.call();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ApiClient.errorMessage(e));
    }
  }

  Future<void> _goToMyLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      if (!mounted) return;
      _mapController.move(LatLng(position.latitude, position.longitude), 16);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    LatLng initialCenter = const LatLng(0.0, 0.0);
    if (_live != null && _live!['latitude'] != null && _live!['longitude'] != null) {
      initialCenter = LatLng((_live!['latitude'] as num).toDouble(), (_live!['longitude'] as num).toDouble());
    } else if (_points.isNotEmpty) {
      initialCenter = _points.last;
    } else if (_initialCenter != null) {
      initialCenter = _initialCenter!;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.readOnly ? 'Session ${widget.sessionId}' : 'Tracking'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: initialCenter,
                    initialZoom: 16,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.tracking.tracking_app',
                    ),
                    if (_points.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(points: _points, color: Colors.blue, strokeWidth: 4),
                        ],
                      ),
                    if (_live != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng((_live!['latitude'] as num).toDouble(), (_live!['longitude'] as num).toDouble()),
                            width: 24,
                            height: 24,
                            child: const Icon(Icons.location_on, color: Colors.red, size: 24),
                          ),
                        ],
                      ),
                  ],
                ),
                if (_error != null)
                  Positioned(
                    top: 8,
                    left: 8,
                    right: 8,
                    child: Material(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(_error!),
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
              onPressed: _stopSession,
              child: const Icon(Icons.stop),
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
