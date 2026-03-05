import 'package:geolocator/geolocator.dart';

class LocationFilterConfig {
  const LocationFilterConfig({
    this.maxAccuracyMeters = 20,
    this.minMovementMeters = 5,
    this.jumpMaxDisplacementAtLowSpeedM = 15,
    this.jumpLowSpeedKmh = 5,
    this.jumpDisplacementVsExpectedRatio = 2.5,
  });

  final double maxAccuracyMeters;
  final double minMovementMeters;
  final double jumpMaxDisplacementAtLowSpeedM;
  final double jumpLowSpeedKmh;
  final double jumpDisplacementVsExpectedRatio;
}

class FilterDecision {
  const FilterDecision(this.accept, [this.reason]);
  final bool accept;
  final String? reason;
}

class LocationFilterService {
  LocationFilterService([this.config = const LocationFilterConfig()]);

  final LocationFilterConfig config;

  Position? _lastAccepted;
  DateTime? _lastAcceptedTime;

  FilterDecision shouldSend(Position position) {
    if (position.accuracy > config.maxAccuracyMeters) {
      return FilterDecision(false, 'Accuracy too low');
    }

    final now = DateTime.now();
    if (_lastAccepted == null) {
      _lastAccepted = position;
      _lastAcceptedTime = now;
      return const FilterDecision(true);
    }

    final distance = Geolocator.distanceBetween(
      _lastAccepted!.latitude,
      _lastAccepted!.longitude,
      position.latitude,
      position.longitude,
    ).toDouble();

    if (distance < config.minMovementMeters) {
      return const FilterDecision(false, 'Movement below minimum');
    }

    final speedKmh = (position.speed >= 0 ? position.speed * 3.6 : 0.0);
    if (distance > config.jumpMaxDisplacementAtLowSpeedM &&
        speedKmh < config.jumpLowSpeedKmh) {
      return const FilterDecision(false, 'GPS jump');
    }

    final elapsedSec = _lastAcceptedTime != null
        ? now.difference(_lastAcceptedTime!).inSeconds
        : 0;
    if (elapsedSec > 0 && speedKmh > 0) {
      final expectedMeters = (speedKmh / 3.6) * elapsedSec;
      if (expectedMeters > 0 &&
          distance > config.jumpDisplacementVsExpectedRatio * expectedMeters) {
        return const FilterDecision(false, 'GPS jump displacement');
      }
    }

    _lastAccepted = position;
    _lastAcceptedTime = now;
    return const FilterDecision(true);
  }

  void reset() {
    _lastAccepted = null;
    _lastAcceptedTime = null;
  }
}
