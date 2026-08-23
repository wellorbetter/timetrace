// GENERATED CODE - DO NOT MODIFY BY HAND.
// Source: crates/plugin-api via tooling/contract-gen.

import 'dart:collection';
import 'dart:convert';

const int pluginManifestSchemaVersion = 1;
const String contractSchemaFingerprint = 'fnv1a64:4e36ddc3fcf32041';
const int maxModelDraftJsonBytes = 4 * 1024;
const int maxModelPreviewJsonBytes = 16 * 1024;
const int maxModelEventJsonBytes = 16 * 1024;
const int maxModelContractJsonBytes = 4 * 1024 * 1024;
const int maxModelOutputBytes = 512 * 1024;
const int maxModelStreamEvents = 1024;

/// Thrown when JSON does not match the canonical plugin transport contract.
final class PluginContractFormatException implements FormatException {
  const PluginContractFormatException(this.message, [this.source, this.offset]);

  @override
  final String message;
  @override
  final Object? source;
  @override
  final int? offset;

  @override
  String toString() => 'PluginContractFormatException: $message';
}

/// Immutable canonical model contract golden fixture.
final class ModelContractFixtureDto {
  ModelContractFixtureDto._({
    required this.draft,
    required this.preview,
    required List<ModelEventDto> events,
  }) : events = List.unmodifiable(events);

  factory ModelContractFixtureDto._fromTrustedJson(Map<String, Object?> json) {
    _expectFields(
      json,
      required: const {'draft', 'preview', 'events'},
      optional: const {},
      path: r'$',
    );
    final rawEvents = json['events'];
    if (rawEvents is! List<Object?>) _wrongType(r'$.events', 'array');
    if (rawEvents.length > maxModelStreamEvents) {
      throw const PluginContractFormatException(
        r'$.events exceeds the model stream event limit',
      );
    }
    final events = <ModelEventDto>[];
    var streamStarted = false;
    var streamTerminal = false;
    var outputBytes = 0;
    for (var index = 0; index < rawEvents.length; index++) {
      final path = '\$.events[$index]';
      final event = ModelEventDto._fromTrustedJson(
        _object(rawEvents[index], path),
        path: path,
      );
      if (!streamStarted) {
        if (event.event != 'started') {
          throw PluginContractFormatException(
            r'$.events must begin with started',
          );
        }
        streamStarted = true;
      } else if (streamTerminal) {
        throw PluginContractFormatException(
          'model stream contains an event after its terminal at $path',
        );
      } else if (event.event == 'delta') {
        final remaining = maxModelOutputBytes - outputBytes;
        final deltaBytes = _utf8LengthWithin(event.text!, remaining);
        if (deltaBytes == null) {
          throw const PluginContractFormatException(
            r'$.events exceeds the cumulative model output byte limit',
          );
        }
        outputBytes += deltaBytes;
      } else if (event.event == 'completed' || event.event == 'failed') {
        streamTerminal = true;
      } else {
        throw PluginContractFormatException(
          'invalid model stream transition at $path',
        );
      }
      events.add(event);
    }
    if (!streamStarted || !streamTerminal) {
      throw const PluginContractFormatException(
        r'$.events must contain started and exactly one terminal event',
      );
    }
    return ModelContractFixtureDto._(
      draft: ModelRequestDraftDto._fromTrustedJson(
        _object(json['draft'], r'$.draft'),
        path: r'$.draft',
      ),
      preview: TransferPreviewDto._fromTrustedJson(
        _object(json['preview'], r'$.preview'),
        path: r'$.preview',
      ),
      events: events,
    );
  }

  factory ModelContractFixtureDto.fromJsonString(String source) =>
      ModelContractFixtureDto._fromTrustedJson(
        _decodeBoundedObject(source, maxModelContractJsonBytes),
      );

  final ModelRequestDraftDto draft;
  final TransferPreviewDto preview;
  final List<ModelEventDto> events;

  Map<String, Object?> toJson() => <String, Object?>{
    'draft': draft.toJson(),
    'preview': preview.toJson(),
    'events': events.map((event) => event.toJson()).toList(),
  };
}

/// Immutable inclusive calendar-date range used by model contracts.
final class ModelDateRangeDto {
  const ModelDateRangeDto._(this.start, this.end);

  factory ModelDateRangeDto.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    _expectFields(
      json,
      required: const {'start', 'end'},
      optional: const {},
      path: path,
    );
    final start = _string(json['start'], '$path.start');
    final end = _string(json['end'], '$path.end');
    _validateModelDateRange(start, end, path);
    return ModelDateRangeDto._(start, end);
  }

  final String start;
  final String end;

  Map<String, Object?> toJson() => <String, Object?>{
    'start': start,
    'end': end,
  };
}

/// Immutable plugin-selectable model request draft.
final class ModelRequestDraftDto {
  ModelRequestDraftDto._({
    required this.providerId,
    required this.dateRange,
    required List<String> fields,
  }) : fields = List.unmodifiable(fields);

  factory ModelRequestDraftDto._fromTrustedJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _expectFields(
      json,
      required: const {'provider_id', 'date_range', 'fields'},
      optional: const {},
      path: path,
    );
    return ModelRequestDraftDto._(
      providerId: _canonicalIdentifier(
        json['provider_id'],
        '$path.provider_id',
      ),
      dateRange: ModelDateRangeDto.fromJson(
        _object(json['date_range'], '$path.date_range'),
        path: '$path.date_range',
      ),
      fields: _modelFields(json['fields'], '$path.fields'),
    );
  }

  factory ModelRequestDraftDto.fromJsonString(String source) {
    return ModelRequestDraftDto._fromTrustedJson(
      _decodeBoundedObject(source, maxModelDraftJsonBytes),
    );
  }

  final String providerId;
  final ModelDateRangeDto dateRange;
  final List<String> fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'provider_id': providerId,
    'date_range': dateRange.toJson(),
    'fields': fields,
  };
}

/// Immutable bounded aggregate summary shown before model transfer.
final class AggregateTransferSummaryDto {
  const AggregateTransferSummaryDto._({
    required this.dailyRows,
    required this.applicationRows,
    required this.hourlyRows,
    required this.trackedDuration,
  });

  factory AggregateTransferSummaryDto.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    _expectFields(
      json,
      required: const {
        'daily_rows',
        'application_rows',
        'hourly_rows',
        'tracked_duration',
      },
      optional: const {},
      path: path,
    );
    final daily = _unsignedBounded(
      json['daily_rows'],
      '$path.daily_rows',
      10000,
    );
    final applications = _unsignedBounded(
      json['application_rows'],
      '$path.application_rows',
      10000,
    );
    final hourly = _unsignedBounded(
      json['hourly_rows'],
      '$path.hourly_rows',
      10000,
    );
    final duration = _nonNegativeInteger(
      json['tracked_duration'],
      '$path.tracked_duration',
    );
    if (daily + applications + hourly > 10000) {
      throw PluginContractFormatException('$path exceeds 10000 total rows');
    }
    return AggregateTransferSummaryDto._(
      dailyRows: daily,
      applicationRows: applications,
      hourlyRows: hourly,
      trackedDuration: duration,
    );
  }

  final int dailyRows;
  final int applicationRows;
  final int hourlyRows;
  final int trackedDuration;

  Map<String, Object?> toJson() => <String, Object?>{
    'daily_rows': dailyRows,
    'application_rows': applicationRows,
    'hourly_rows': hourlyRows,
    'tracked_duration': trackedDuration,
  };
}

/// Immutable bounded model token estimate.
final class TokenEstimateDto {
  const TokenEstimateDto._(this.minimum, this.maximum);

  factory TokenEstimateDto.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    _expectFields(
      json,
      required: const {'minimum', 'maximum'},
      optional: const {},
      path: path,
    );
    final minimum = _unsignedBounded(json['minimum'], '$path.minimum', 262144);
    final maximum = _unsignedBounded(json['maximum'], '$path.maximum', 262144);
    if (maximum < minimum) {
      throw PluginContractFormatException('$path has a reversed token range');
    }
    return TokenEstimateDto._(minimum, maximum);
  }

  final int minimum;
  final int maximum;

  Map<String, Object?> toJson() => <String, Object?>{
    'minimum': minimum,
    'maximum': maximum,
  };
}

/// Immutable exact transfer preview emitted only by the host.
final class TransferPreviewDto {
  TransferPreviewDto._({
    required this.operationId,
    required this.providerId,
    required this.modelId,
    required this.endpointDomain,
    required this.endpointPort,
    required this.endpointBasePath,
    required this.locality,
    required this.dateRange,
    required List<String> fields,
    required this.summary,
    required this.payloadBytes,
    required this.estimatedTokens,
  }) : fields = List.unmodifiable(fields);

  factory TransferPreviewDto._fromTrustedJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _expectFields(
      json,
      required: const {
        'operation_id',
        'provider_id',
        'model_id',
        'endpoint_domain',
        'endpoint_port',
        'endpoint_base_path',
        'locality',
        'date_range',
        'fields',
        'summary',
        'payload_bytes',
        'estimated_tokens',
      },
      optional: const {},
      path: path,
    );
    final modelId = _string(json['model_id'], '$path.model_id');
    if (modelId.isEmpty ||
        _utf8LengthExceeds(modelId, 128) ||
        !RegExp(r'^[A-Za-z0-9._:/-]+$').hasMatch(modelId)) {
      throw PluginContractFormatException('invalid model id at $path.model_id');
    }
    final locality = _enumString(json['locality'], const {
      'local',
      'cloud',
    }, '$path.locality');
    final endpointDomain = _string(
      json['endpoint_domain'],
      '$path.endpoint_domain',
    );
    final endpointPort = _unsignedBounded(
      json['endpoint_port'],
      '$path.endpoint_port',
      65535,
    );
    if (endpointPort == 0 ||
        (locality == 'local' && !_isLoopbackDomain(endpointDomain)) ||
        (locality == 'cloud' &&
            (endpointPort != 443 ||
                _isIpLiteral(endpointDomain) ||
                endpointDomain == 'localhost' ||
                !_isExactDomain(endpointDomain)))) {
      throw PluginContractFormatException('invalid endpoint at $path');
    }
    final endpointBasePath = _string(
      json['endpoint_base_path'],
      '$path.endpoint_base_path',
    );
    _validateModelBasePath(endpointBasePath, '$path.endpoint_base_path');
    return TransferPreviewDto._(
      operationId: _canonicalIdentifier(
        json['operation_id'],
        '$path.operation_id',
      ),
      providerId: _canonicalIdentifier(
        json['provider_id'],
        '$path.provider_id',
      ),
      modelId: modelId,
      endpointDomain: endpointDomain,
      endpointPort: endpointPort,
      endpointBasePath: endpointBasePath,
      locality: locality,
      dateRange: ModelDateRangeDto.fromJson(
        _object(json['date_range'], '$path.date_range'),
        path: '$path.date_range',
      ),
      fields: _modelFields(json['fields'], '$path.fields'),
      summary: AggregateTransferSummaryDto.fromJson(
        _object(json['summary'], '$path.summary'),
        path: '$path.summary',
      ),
      payloadBytes: _positiveBounded(
        json['payload_bytes'],
        '$path.payload_bytes',
        262144,
      ),
      estimatedTokens: TokenEstimateDto.fromJson(
        _object(json['estimated_tokens'], '$path.estimated_tokens'),
        path: '$path.estimated_tokens',
      ),
    );
  }

  factory TransferPreviewDto.fromJsonString(String source) {
    return TransferPreviewDto._fromTrustedJson(
      _decodeBoundedObject(source, maxModelPreviewJsonBytes),
    );
  }

  final String operationId;
  final String providerId;
  final String modelId;
  final String endpointDomain;
  final int endpointPort;
  final String endpointBasePath;
  final String locality;
  final ModelDateRangeDto dateRange;
  final List<String> fields;
  final AggregateTransferSummaryDto summary;
  final int payloadBytes;
  final TokenEstimateDto estimatedTokens;

  Map<String, Object?> toJson() => <String, Object?>{
    'operation_id': operationId,
    'provider_id': providerId,
    'model_id': modelId,
    'endpoint_domain': endpointDomain,
    'endpoint_port': endpointPort,
    'endpoint_base_path': endpointBasePath,
    'locality': locality,
    'date_range': dateRange.toJson(),
    'fields': fields,
    'summary': summary.toJson(),
    'payload_bytes': payloadBytes,
    'estimated_tokens': estimatedTokens.toJson(),
  };
}

/// Immutable completed-operation model usage.
final class ModelUsageDto {
  const ModelUsageDto._(this.inputTokens, this.outputTokens);

  factory ModelUsageDto.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    _expectFields(
      json,
      required: const {'input_tokens', 'output_tokens'},
      optional: const {},
      path: path,
    );
    return ModelUsageDto._(
      _unsignedBounded(json['input_tokens'], '$path.input_tokens', 262144),
      _unsignedBounded(json['output_tokens'], '$path.output_tokens', 4096),
    );
  }

  final int inputTokens;
  final int outputTokens;

  Map<String, Object?> toJson() => <String, Object?>{
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
  };
}

/// Immutable strict tagged model event.
final class ModelEventDto {
  const ModelEventDto._({
    required this.event,
    this.text,
    this.usage,
    this.code,
    this.retryable,
  });

  factory ModelEventDto._fromTrustedJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    final event = _enumString(json['event'], const {
      'started',
      'delta',
      'completed',
      'failed',
    }, '$path.event');
    switch (event) {
      case 'started':
        _expectFields(
          json,
          required: const {'event'},
          optional: const {},
          path: path,
        );
        return const ModelEventDto._(event: 'started');
      case 'delta':
        _expectFields(
          json,
          required: const {'event', 'text'},
          optional: const {},
          path: path,
        );
        final text = _string(json['text'], '$path.text');
        if (text.isEmpty || _utf8LengthExceeds(text, 8192)) {
          throw PluginContractFormatException(
            'invalid delta size at $path.text',
          );
        }
        return ModelEventDto._(event: event, text: text);
      case 'completed':
        _expectFields(
          json,
          required: const {'event', 'usage'},
          optional: const {},
          path: path,
        );
        return ModelEventDto._(
          event: event,
          usage: ModelUsageDto.fromJson(
            _object(json['usage'], '$path.usage'),
            path: '$path.usage',
          ),
        );
      case 'failed':
        _expectFields(
          json,
          required: const {'event', 'code', 'retryable'},
          optional: const {},
          path: path,
        );
        final retryable = json['retryable'];
        if (retryable is! bool) _wrongType('$path.retryable', 'boolean');
        return ModelEventDto._(
          event: event,
          code: _enumString(json['code'], const {
            'invalid_request',
            'authentication_failed',
            'rate_limited',
            'provider_unavailable',
            'timeout',
            'cancelled',
            'invalid_response',
            'internal',
          }, '$path.code'),
          retryable: retryable,
        );
    }
    throw PluginContractFormatException('unsupported model event at $path');
  }

  factory ModelEventDto.fromJsonString(String source) {
    return ModelEventDto._fromTrustedJson(
      _decodeBoundedObject(source, maxModelEventJsonBytes),
    );
  }

  final String event;
  final String? text;
  final ModelUsageDto? usage;
  final String? code;
  final bool? retryable;

  Map<String, Object?> toJson() => <String, Object?>{
    'event': event,
    if (text != null) 'text': text,
    if (usage != null) 'usage': usage!.toJson(),
    if (code != null) 'code': code,
    if (retryable != null) 'retryable': retryable,
  };
}

/// Immutable transport DTO for a canonical plugin manifest.
final class PluginManifestDto {
  PluginManifestDto._({
    required this.schemaVersion,
    required this.id,
    required this.publisher,
    required this.displayName,
    required this.description,
    required this.version,
    required this.hostApi,
    required List<String> platforms,
    required List<PluginContributionDto> contributions,
    required List<PluginCapabilityRequestDto> requestedCapabilities,
  }) : platforms = List.unmodifiable(platforms),
       contributions = List.unmodifiable(contributions),
       requestedCapabilities = List.unmodifiable(requestedCapabilities);

  factory PluginManifestDto.fromJson(Map<String, Object?> json) {
    _expectFields(
      json,
      required: const {
        'schema_version',
        'id',
        'publisher',
        'display_name',
        'version',
        'host_api',
        'platforms',
      },
      optional: const {
        'description',
        'contributions',
        'requested_capabilities',
      },
      path: r'$',
    );
    final schemaVersion = _integer(json['schema_version'], r'$.schema_version');
    if (schemaVersion != pluginManifestSchemaVersion) {
      throw PluginContractFormatException(
        'unsupported schema version $schemaVersion at \$.schema_version',
      );
    }
    return PluginManifestDto._(
      schemaVersion: schemaVersion,
      id: _string(json['id'], r'$.id'),
      publisher: _string(json['publisher'], r'$.publisher'),
      displayName: _string(json['display_name'], r'$.display_name'),
      description: _optionalString(json['description'], r'$.description'),
      version: _string(json['version'], r'$.version'),
      hostApi: _string(json['host_api'], r'$.host_api'),
      platforms: _enumStringList(json['platforms'], const {
        'windows_x64',
        'mac_os_arm64',
        'mac_os_x64',
        'linux_x64',
      }, r'$.platforms'),
      contributions:
          _objectList(
                json['contributions'] ?? const <Object?>[],
                r'$.contributions',
              ).indexed
              .map((entry) {
                return PluginContributionDto.fromJson(
                  entry.$2,
                  path: '\$.contributions[${entry.$1}]',
                );
              })
              .toList(growable: false),
      requestedCapabilities:
          _objectList(
                json['requested_capabilities'] ?? const <Object?>[],
                r'$.requested_capabilities',
              ).indexed
              .map((entry) {
                return PluginCapabilityRequestDto.fromJson(
                  entry.$2,
                  path: '\$.requested_capabilities[${entry.$1}]',
                );
              })
              .toList(growable: false),
    );
  }

  factory PluginManifestDto.fromJsonString(String source) {
    return PluginManifestDto.fromJson(_decodeObject(source));
  }

  final int schemaVersion;
  final String id;
  final String publisher;
  final String displayName;
  final String? description;
  final String version;
  final String hostApi;
  final List<String> platforms;
  final List<PluginContributionDto> contributions;
  final List<PluginCapabilityRequestDto> requestedCapabilities;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': schemaVersion,
    'id': id,
    'publisher': publisher,
    'display_name': displayName,
    if (description != null) 'description': description,
    'version': version,
    'host_api': hostApi,
    'platforms': platforms,
    if (contributions.isNotEmpty)
      'contributions': contributions.map((value) => value.toJson()).toList(),
    if (requestedCapabilities.isNotEmpty)
      'requested_capabilities': requestedCapabilities
          .map((value) => value.toJson())
          .toList(),
  };
}

/// Immutable contribution union preserving its strictly validated descriptor.
final class PluginContributionDto {
  PluginContributionDto._(this.kind, Map<String, Object?> descriptor)
    : descriptor = UnmodifiableMapView(_deepFreezeMap(descriptor));

  factory PluginContributionDto.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _expectFields(
      json,
      required: const {'kind', 'descriptor'},
      optional: const {},
      path: path,
    );
    final kind = _string(json['kind'], '$path.kind');
    final descriptor = _object(json['descriptor'], '$path.descriptor');
    _validateContribution(kind, descriptor, '$path.descriptor');
    return PluginContributionDto._(kind, descriptor);
  }

  final String kind;
  final Map<String, Object?> descriptor;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'descriptor': _deepMutableMap(descriptor),
  };
}

/// Immutable capability request transport DTO.
final class PluginCapabilityRequestDto {
  PluginCapabilityRequestDto._({
    required this.id,
    required Map<String, Object?> constraints,
    required this.rationale,
  }) : constraints = UnmodifiableMapView(_deepFreezeMap(constraints));

  factory PluginCapabilityRequestDto.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _expectFields(
      json,
      required: const {'id'},
      optional: const {'constraints', 'rationale'},
      path: path,
    );
    final constraints = _object(
      json['constraints'] ?? const <String, Object?>{},
      '$path.constraints',
    );
    _expectFields(
      constraints,
      required: const {},
      optional: const {
        'max_range_days',
        'allowed_granularities',
        'max_rows',
        'max_bytes',
        'allowed_domains',
      },
      path: '$path.constraints',
    );
    _optionalInteger(
      constraints['max_range_days'],
      '$path.constraints.max_range_days',
    );
    _optionalInteger(constraints['max_rows'], '$path.constraints.max_rows');
    _optionalInteger(constraints['max_bytes'], '$path.constraints.max_bytes');
    if (constraints.containsKey('allowed_granularities')) {
      _stringList(
        constraints['allowed_granularities'],
        '$path.constraints.allowed_granularities',
      );
    }
    if (constraints.containsKey('allowed_domains')) {
      _stringList(
        constraints['allowed_domains'],
        '$path.constraints.allowed_domains',
      );
    }
    return PluginCapabilityRequestDto._(
      id: _string(json['id'], '$path.id'),
      constraints: constraints,
      rationale: _optionalString(json['rationale'], '$path.rationale'),
    );
  }

  final String id;
  final Map<String, Object?> constraints;
  final String? rationale;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (constraints.isNotEmpty) 'constraints': _deepMutableMap(constraints),
    if (rationale != null) 'rationale': rationale,
  };
}

/// Immutable transport DTO for one privacy-safe diagnostic event.
final class DiagnosticEventDto {
  DiagnosticEventDto._({
    required this.timestamp,
    required this.level,
    required this.target,
    required this.eventCode,
    required this.pluginId,
    required this.correlationId,
    required this.duration,
    required Map<String, ScalarValueDto> fields,
  }) : fields = UnmodifiableMapView(fields);

  factory DiagnosticEventDto.fromJson(Map<String, Object?> json) {
    _expectFields(
      json,
      required: const {
        'timestamp',
        'level',
        'target',
        'event_code',
        'correlation_id',
      },
      optional: const {'plugin_id', 'duration', 'fields'},
      path: r'$',
    );
    final rawFields = _object(
      json['fields'] ?? const <String, Object?>{},
      r'$.fields',
    );
    const fieldNames = {
      'operation',
      'status',
      'error_code',
      'provider_id',
      'state',
      'reason_code',
      'rows',
      'bytes',
      'count',
      'dropped_events',
      'attempt',
      'generation',
    };
    final fields = <String, ScalarValueDto>{};
    for (final entry in rawFields.entries) {
      if (!fieldNames.contains(entry.key)) {
        throw PluginContractFormatException(
          'unknown diagnostic field ${entry.key}',
        );
      }
      fields[entry.key] = ScalarValueDto.fromJson(
        _object(entry.value, '\$.fields.${entry.key}'),
        path: '\$.fields.${entry.key}',
      );
    }
    return DiagnosticEventDto._(
      timestamp: _integer(json['timestamp'], r'$.timestamp'),
      level: _enumString(json['level'], const {
        'trace',
        'debug',
        'info',
        'warn',
        'error',
      }, r'$.level'),
      target: _enumString(json['target'], const {
        'core',
        'bridge',
        'plugin_host',
        'plugin_services',
        'plugin',
      }, r'$.target'),
      eventCode: _string(json['event_code'], r'$.event_code'),
      pluginId: _optionalString(json['plugin_id'], r'$.plugin_id'),
      correlationId: _string(json['correlation_id'], r'$.correlation_id'),
      duration: _optionalInteger(json['duration'], r'$.duration'),
      fields: fields,
    );
  }

  factory DiagnosticEventDto.fromJsonString(String source) {
    return DiagnosticEventDto.fromJson(_decodeObject(source));
  }

  final int timestamp;
  final String level;
  final String target;
  final String eventCode;
  final String? pluginId;
  final String correlationId;
  final int? duration;
  final Map<String, ScalarValueDto> fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'timestamp': timestamp,
    'level': level,
    'target': target,
    'event_code': eventCode,
    if (pluginId != null) 'plugin_id': pluginId,
    'correlation_id': correlationId,
    if (duration != null) 'duration': duration,
    if (fields.isNotEmpty)
      'fields': fields.map((key, value) => MapEntry(key, value.toJson())),
  };
}

/// Immutable tagged scalar shared by settings and diagnostic fields.
final class ScalarValueDto {
  const ScalarValueDto._(this.type, this.value);

  factory ScalarValueDto.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _expectFields(
      json,
      required: const {'type', 'value'},
      optional: const {},
      path: path,
    );
    final type = _enumString(json['type'], const {
      'boolean',
      'integer',
      'unsigned',
      'string',
    }, '$path.type');
    final value = json['value'];
    switch (type) {
      case 'boolean':
        if (value is! bool) _wrongType('$path.value', 'boolean');
        break;
      case 'integer':
        _integer(value, '$path.value');
        break;
      case 'unsigned':
        final number = _integer(value, '$path.value');
        if (type == 'unsigned' && number < 0) {
          throw PluginContractFormatException(
            '$path.value must be non-negative',
          );
        }
        break;
      case 'string':
        _string(value, '$path.value');
        break;
    }
    return ScalarValueDto._(type, value as Object);
  }

  final String type;
  final Object value;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'value': value,
  };
}

void _validateContribution(
  String kind,
  Map<String, Object?> descriptor,
  String path,
) {
  switch (kind) {
    case 'navigation':
      _expectFields(
        descriptor,
        required: const {'metadata', 'page_id'},
        optional: const {},
        path: path,
      );
      _validateMetadata(
        _object(descriptor['metadata'], '$path.metadata'),
        '$path.metadata',
      );
      _string(descriptor['page_id'], '$path.page_id');
      break;
    case 'page':
      _expectFields(
        descriptor,
        required: const {'metadata', 'view_id', 'renderer'},
        optional: const {},
        path: path,
      );
      _validateMetadata(
        _object(descriptor['metadata'], '$path.metadata'),
        '$path.metadata',
      );
      _string(descriptor['view_id'], '$path.view_id');
      _validateRenderer(
        _object(descriptor['renderer'], '$path.renderer'),
        '$path.renderer',
      );
      break;
    case 'dashboard_carousel':
    case 'dashboard_card':
      _expectFields(
        descriptor,
        required: const {'metadata', 'renderer', 'size', 'refresh'},
        optional: const {},
        path: path,
      );
      _validateMetadata(
        _object(descriptor['metadata'], '$path.metadata'),
        '$path.metadata',
      );
      _validateRenderer(
        _object(descriptor['renderer'], '$path.renderer'),
        '$path.renderer',
      );
      _enumString(descriptor['size'], const {
        'small',
        'medium',
        'large',
        'wide',
      }, '$path.size');
      _enumString(descriptor['refresh'], const {
        'on_demand',
        'data_revision',
      }, '$path.refresh');
      break;
    case 'settings':
      _expectFields(
        descriptor,
        required: const {'metadata', 'schema_version', 'fields'},
        optional: const {},
        path: path,
      );
      _validateMetadata(
        _object(descriptor['metadata'], '$path.metadata'),
        '$path.metadata',
      );
      _integer(descriptor['schema_version'], '$path.schema_version');
      final fields = _objectList(descriptor['fields'], '$path.fields');
      for (final entry in fields.indexed) {
        final fieldPath = '$path.fields[${entry.$1}]';
        _expectFields(
          entry.$2,
          required: const {'key', 'label', 'kind', 'required'},
          optional: const {'default_value'},
          path: fieldPath,
        );
        _string(entry.$2['key'], '$fieldPath.key');
        _string(entry.$2['label'], '$fieldPath.label');
        _enumString(entry.$2['kind'], const {
          'boolean',
          'integer',
          'string',
          'secret_reference',
        }, '$fieldPath.kind');
        if (entry.$2['required'] is! bool) {
          _wrongType('$fieldPath.required', 'boolean');
        }
        if (entry.$2.containsKey('default_value')) {
          ScalarValueDto.fromJson(
            _object(entry.$2['default_value'], '$fieldPath.default_value'),
            path: '$fieldPath.default_value',
          );
        }
      }
      break;
    case 'command':
      _expectFields(
        descriptor,
        required: const {'metadata', 'input_schema_version', 'timeout_ms'},
        optional: const {},
        path: path,
      );
      _validateMetadata(
        _object(descriptor['metadata'], '$path.metadata'),
        '$path.metadata',
      );
      _integer(
        descriptor['input_schema_version'],
        '$path.input_schema_version',
      );
      _integer(descriptor['timeout_ms'], '$path.timeout_ms');
      break;
    default:
      throw PluginContractFormatException(
        'unknown contribution kind $kind at $path',
      );
  }
}

void _validateMetadata(Map<String, Object?> value, String path) {
  _expectFields(
    value,
    required: const {'id', 'display', 'order'},
    optional: const {'required_capabilities'},
    path: path,
  );
  _string(value['id'], '$path.id');
  _integer(value['order'], '$path.order');
  if (value.containsKey('required_capabilities')) {
    _stringList(value['required_capabilities'], '$path.required_capabilities');
  }
  final display = _object(value['display'], '$path.display');
  _expectFields(
    display,
    required: const {'title'},
    optional: const {'description', 'icon'},
    path: '$path.display',
  );
  _string(display['title'], '$path.display.title');
  _optionalString(display['description'], '$path.display.description');
  _optionalString(display['icon'], '$path.display.icon');
}

void _validateRenderer(Map<String, Object?> value, String path) {
  final mode = _string(value['mode'], '$path.mode');
  switch (mode) {
    case 'bundled_typed':
      _expectFields(
        value,
        required: const {'mode', 'contract_id', 'schema_version'},
        optional: const {},
        path: path,
      );
      _string(value['contract_id'], '$path.contract_id');
      _integer(value['schema_version'], '$path.schema_version');
      break;
    case 'declarative_v1':
      _expectFields(
        value,
        required: const {'mode'},
        optional: const {},
        path: path,
      );
      break;
    default:
      throw PluginContractFormatException(
        'unknown renderer mode $mode at $path',
      );
  }
}

List<String> _modelFields(Object? value, String path) {
  const allowed = {
    'date_range',
    'usage_date',
    'app_display_id',
    'app_display_name',
    'duration',
    'hour_bucket',
  };
  if (value is! List<Object?>) _wrongType(path, 'array');
  if (value.isEmpty || value.length > 6) {
    throw PluginContractFormatException('invalid transfer fields at $path');
  }
  final fields = <String>[];
  final unique = <String>{};
  for (var index = 0; index < value.length; index++) {
    final field = _enumString(value[index], allowed, '$path[$index]');
    if (!unique.add(field)) {
      throw PluginContractFormatException('duplicate transfer field at $path');
    }
    fields.add(field);
  }
  final hasDimension =
      fields.contains('usage_date') ||
      fields.contains('app_display_id') ||
      fields.contains('app_display_name') ||
      fields.contains('hour_bucket');
  if (!fields.contains('date_range') ||
      !fields.contains('duration') ||
      !hasDimension) {
    throw PluginContractFormatException(
      'missing required transfer shape at $path',
    );
  }
  return List.unmodifiable(fields);
}

void _validateModelDateRange(String start, String end, String path) {
  final first = _parseDateOnly(start, '$path.start');
  final last = _parseDateOnly(end, '$path.end');
  final inclusiveDays = last.difference(first).inDays + 1;
  if (inclusiveDays < 1 || inclusiveDays > 7) {
    throw PluginContractFormatException('invalid model date range at $path');
  }
}

DateTime _parseDateOnly(String value, String path) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) {
    throw PluginContractFormatException('invalid date at $path');
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final parsed = DateTime.utc(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    throw PluginContractFormatException('invalid date at $path');
  }
  return parsed;
}

bool _isLoopbackDomain(String value) {
  if (value == 'localhost' || value == '::1') return true;
  final octets = _canonicalIpv4(value);
  return octets != null && octets.first == 127;
}

bool _isIpLiteral(String value) {
  return value.contains(':') || _canonicalIpv4(value) != null;
}

List<int>? _canonicalIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    final octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255 || octet.toString() != part) {
      return null;
    }
    octets.add(octet);
  }
  return octets;
}

bool _isExactDomain(String value) {
  if (value.isEmpty || value.length > 253 || value != value.toLowerCase()) {
    return false;
  }
  final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  return value.codeUnits.every((unit) => unit <= 0x7f) &&
      value.split('.').every((part) => label.hasMatch(part));
}

void _validateModelBasePath(String value, String path) {
  final invalidSegment = value
      .split('/')
      .any((segment) => segment == '.' || segment == '..');
  if (value.isEmpty ||
      value.length > 256 ||
      !value.startsWith('/') ||
      !RegExp(r'^[A-Za-z0-9._~/-]+$').hasMatch(value) ||
      value.contains('//') ||
      invalidSegment ||
      (value != '/' && value.endsWith('/'))) {
    throw PluginContractFormatException('invalid endpoint base path at $path');
  }
}

int _unsignedBounded(Object? value, String path, int maximum) {
  final number = _integer(value, path);
  if (number < 0 || number > maximum) {
    throw PluginContractFormatException('$path must be between 0 and $maximum');
  }
  return number;
}

int _nonNegativeInteger(Object? value, String path) {
  final number = _integer(value, path);
  if (number < 0) {
    throw PluginContractFormatException('$path must be non-negative');
  }
  return number;
}

int _positiveBounded(Object? value, String path, int maximum) {
  final number = _unsignedBounded(value, path, maximum);
  if (number == 0) {
    throw PluginContractFormatException('$path must be positive');
  }
  return number;
}

String _canonicalIdentifier(Object? value, String path) {
  final identifier = _string(value, path);
  if (identifier.isEmpty ||
      identifier.length > 128 ||
      !RegExp(r'^[a-z0-9]+(?:[-._:][a-z0-9]+)*$').hasMatch(identifier)) {
    throw PluginContractFormatException(
      'invalid canonical identifier at $path',
    );
  }
  return identifier;
}

int? _utf8LengthWithin(String value, int limit) {
  var bytes = 0;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit <= 0x7f) {
      bytes += 1;
    } else if (unit <= 0x7ff) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 < value.length) {
        final next = value.codeUnitAt(index + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          bytes += 4;
          index += 1;
        } else {
          bytes += 3;
        }
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
    if (bytes > limit) return null;
  }
  return bytes;
}

bool _utf8LengthExceeds(String value, int limit) =>
    _utf8LengthWithin(value, limit) == null;

Map<String, Object?> _decodeBoundedObject(String source, int maxBytes) {
  if (_utf8LengthExceeds(source, maxBytes)) {
    throw PluginContractFormatException(
      'JSON frame exceeds its $maxBytes-byte limit',
    );
  }
  return _decodeObject(source);
}

Map<String, Object?> _decodeObject(String source) {
  try {
    return _object(jsonDecode(source), r'$');
  } on FormatException catch (error) {
    throw PluginContractFormatException(error.message, source, error.offset);
  }
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map<String, Object?>) _wrongType(path, 'object');
  return value;
}

List<Map<String, Object?>> _objectList(Object? value, String path) {
  if (value is! List<Object?>) _wrongType(path, 'array');
  return value.indexed
      .map((entry) {
        return _object(entry.$2, '$path[${entry.$1}]');
      })
      .toList(growable: false);
}

List<String> _stringList(Object? value, String path) {
  if (value is! List<Object?>) _wrongType(path, 'array');
  return value.indexed
      .map((entry) {
        return _string(entry.$2, '$path[${entry.$1}]');
      })
      .toList(growable: false);
}

List<String> _enumStringList(Object? value, Set<String> allowed, String path) {
  final values = _stringList(value, path);
  for (var index = 0; index < values.length; index++) {
    _enumString(values[index], allowed, '$path[$index]');
  }
  return values;
}

String _string(Object? value, String path) {
  if (value is! String) _wrongType(path, 'string');
  return value;
}

String? _optionalString(Object? value, String path) {
  if (value == null) return null;
  return _string(value, path);
}

int _integer(Object? value, String path) {
  if (value is! int) _wrongType(path, 'integer');
  return value;
}

int? _optionalInteger(Object? value, String path) {
  if (value == null) return null;
  return _integer(value, path);
}

String _enumString(Object? value, Set<String> allowed, String path) {
  final result = _string(value, path);
  if (!allowed.contains(result)) {
    throw PluginContractFormatException('unsupported value $result at $path');
  }
  return result;
}

Never _wrongType(String path, String expected) {
  throw PluginContractFormatException('$path must be a JSON $expected');
}

void _expectFields(
  Map<String, Object?> value, {
  required Set<String> required,
  required Set<String> optional,
  required String path,
}) {
  final missing = required.difference(value.keys.toSet());
  if (missing.isNotEmpty) {
    throw PluginContractFormatException('missing ${missing.first} at $path');
  }
  final allowed = <String>{...required, ...optional};
  final unknown = value.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw PluginContractFormatException(
      'unknown field ${unknown.first} at $path',
    );
  }
}

Map<String, Object?> _deepFreezeMap(Map<String, Object?> source) {
  return source.map((key, value) => MapEntry(key, _deepFreeze(value)));
}

Object? _deepFreeze(Object? value) {
  if (value is Map<String, Object?>) {
    return UnmodifiableMapView(_deepFreezeMap(value));
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_deepFreeze));
  }
  return value;
}

Map<String, Object?> _deepMutableMap(Map<String, Object?> source) {
  return source.map((key, value) => MapEntry(key, _deepMutable(value)));
}

Object? _deepMutable(Object? value) {
  if (value is Map<String, Object?>) return _deepMutableMap(value);
  if (value is List<Object?>) return value.map(_deepMutable).toList();
  return value;
}
