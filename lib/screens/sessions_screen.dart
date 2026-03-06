import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/device_id_service.dart';
import '../services/tracking_upload_service.dart';
import 'login_screen.dart';
import 'map_screen.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<dynamic> _sessions = [];
  bool _loading = true;
  String? _error;
  int? _activeSessionId;
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _loadDeviceId();
    _loadSessions();
  }

  Future<void> _loadDeviceId() async {
    final id = await DeviceIdService().getOrCreate();
    if (mounted) setState(() => _deviceId = id);
  }

  Future<void> _loadSessions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.authService.apiClient.getSessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loading = false;
        _activeSessionId = () {
          for (final s in list) {
            if (s is Map && s['is_active'] == true && s['id'] != null) return s['id'] as int;
          }
          return null;
        }();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ApiClient.errorMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _startSession() async {
    if (_deviceId == null) return;
    setState(() => _error = null);
    try {
      final session = await widget.authService.apiClient.startSession(name: 'Session ${DateTime.now().toIso8601String().substring(0, 16)}');
      if (!mounted) return;
      final id = session['id'] as int?;
      if (id != null) {
        setState(() => _activeSessionId = id);
        await _loadSessions();
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MapScreen(
              authService: widget.authService,
              sessionId: id,
              deviceId: _deviceId!,
              onSessionStopped: () {
                setState(() => _activeSessionId = null);
                _loadSessions();
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ApiClient.errorMessage(e));
    }
  }

  Future<void> _stopSession(int id) async {
    // First, try to flush any locally stored points for this session.
    try {
      await TrackingUploadService(widget.authService.apiClient).uploadSession(id);
    } catch (_) {}

    const maxAttempts = 3;
    const retryDelays = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await widget.authService.apiClient.stopSession(id);
        if (!mounted) return;
        setState(() => _activeSessionId = null);
        _loadSessions();
        return;
      } catch (e) {
        if (!mounted) return;
        final isRetriable = ApiClient.isRetriableError(e);
        if (!isRetriable || attempt == maxAttempts - 1) {
          setState(() => _error = ApiClient.errorMessage(e));
          return;
        }
        if (attempt < retryDelays.length) {
          await Future<void>.delayed(retryDelays[attempt]);
        }
      }
    }
  }

  Future<void> _logout() async {
    await widget.authService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(authService: widget.authService)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSessions,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: _activeSessionId != null || _deviceId == null ? null : _startSession,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_activeSessionId != null ? 'Tracking active' : 'Start tracking'),
                  ),
                  const SizedBox(height: 24),
                  ..._sessions.map((s) {
                    final map = s as Map<String, dynamic>;
                    final id = map['id'] as int?;
                    final name = map['name'] as String? ?? 'Session';
                    final started = map['started_at'] as String?;
                    final _ = map['ended_at'] as String?;
                    final active = map['is_active'] == true;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(name),
                        subtitle: Text(started ?? '—'),
                        trailing: active && id != null
                            ? TextButton(
                                onPressed: () => _stopSession(id),
                                child: const Text('Stop'),
                              )
                            : null,
                        onTap: id != null && !active
                            ? () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => MapScreen(
                                      authService: widget.authService,
                                      sessionId: id,
                                      deviceId: _deviceId ?? '',
                                      readOnly: true,
                                    ),
                                  ),
                                )
                            : null,
                      ),
                    );
                  }),
                ],
              ),
            ),
    );
  }
}
