import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';

enum PollingUnit { seconds, minutes }

const minimumPollingMilliseconds = 30000;
const maximumPollingMilliseconds = 60000;
const defaultPollingMilliseconds = minimumPollingMilliseconds;

bool isValidPollingMilliseconds(int milliseconds) =>
    milliseconds >= minimumPollingMilliseconds &&
    milliseconds <= maximumPollingMilliseconds;

/// Read compatibility only. New explicit writes must validate, not clamp.
int effectivePollingMilliseconds(int milliseconds) => milliseconds
    .clamp(minimumPollingMilliseconds, maximumPollingMilliseconds)
    .toInt();

/// Quantize the exact decimal rational first, then check canonical ms bounds.
int? parsePollingMilliseconds(String text, PollingUnit unit) {
  final value = text.trim();
  if (value.length > 64 || !RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value))
    return null;
  final parts = value.split('.');
  final fraction = parts.length == 2 ? parts[1] : '';
  final numerator = BigInt.parse(parts[0] + fraction);
  final denominator = BigInt.from(10).pow(fraction.length);
  final factor = BigInt.from(unit == PollingUnit.seconds ? 1000 : 60000);
  final rounded =
      (numerator * factor * BigInt.two + denominator) ~/
      (denominator * BigInt.two);
  if (rounded < BigInt.from(minimumPollingMilliseconds) ||
      rounded > BigInt.from(maximumPollingMilliseconds)) return null;
  return rounded.toInt();
}

String formatPollingValue(int milliseconds, PollingUnit unit) {
  final factor = BigInt.from(unit == PollingUnit.seconds ? 1000 : 60000);
  final precision = BigInt.from(1000000);
  final scaled =
      (BigInt.from(milliseconds).abs() * precision * BigInt.two + factor) ~/
      (factor * BigInt.two);
  final whole = scaled ~/ precision;
  final fraction = (scaled % precision)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${milliseconds < 0 ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}

/// App settings persisted via the Rust bridge (AppConfig.json).
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    required int pollIntervalMs,
    required int idleThresholdMinutes,
    required bool minimizeToTray,
    required bool startMinimized,
    required bool autoStartTracking,
    required List<String> excludedApps,
    required String dbPath,
  }) = _AppSettings;

  const AppSettings._();

  factory AppSettings.defaults() => const AppSettings(
    pollIntervalMs: defaultPollingMilliseconds,
    idleThresholdMinutes: 5,
    minimizeToTray: true,
    startMinimized: false,
    autoStartTracking: true,
    excludedApps: [],
    dbPath: '',
  );
}
