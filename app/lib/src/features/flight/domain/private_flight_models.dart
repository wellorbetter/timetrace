import 'package:flutter/foundation.dart';

/// Feature-owned immutable flight session model.
@immutable
final class PrivateFlightSession {
  const PrivateFlightSession({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.durationSecs,
    required this.status,
    required this.satisfaction,
    required this.note,
    required this.date,
  });

  final int id;
  final String startedAt;
  final String? endedAt;
  final int? durationSecs;
  final String status;
  final int? satisfaction;
  final String note;
  final String date;
}

/// Feature-owned immutable material model.
@immutable
final class PrivateFlightMaterial {
  const PrivateFlightMaterial({
    required this.id,
    required this.title,
    required this.kind,
    required this.sourceUrl,
    required this.domain,
    required this.localAssetPath,
    required this.tags,
    required this.rating,
  });

  final int id;
  final String title;
  final String kind;
  final String? sourceUrl;
  final String? domain;
  final String? localAssetPath;
  final String tags;
  final int? rating;
}

/// Feature-owned immutable material link model.
@immutable
final class PrivateFlightMaterialLink {
  const PrivateFlightMaterialLink({
    required this.flightId,
    required this.sortOrder,
    required this.material,
  });

  final int flightId;
  final int sortOrder;
  final PrivateFlightMaterial material;
}
