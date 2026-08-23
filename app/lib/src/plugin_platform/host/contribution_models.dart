import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:timetrace_app/src/bridge/plugins/service.dart';
import 'package:timetrace_app/src/plugin_platform/generated/plugin_contracts.g.dart';
import 'package:timetrace_app/src/plugin_platform/rendering/declarative_v1_renderer.dart';

/// Canonical persisted preference reported by the Rust plugin host.
enum CanonicalDesiredState { disabled, enabled }

/// Canonical runtime state reported by the Rust plugin host.
enum CanonicalRuntimeState {
  registered,
  incompatible,
  disabled,
  starting,
  ready,
  stopping,
  failed,
}

/// Canonical UI contribution surface.
enum ContributionKind {
  navigation,
  page,
  dashboardCard,
  dashboardCarousel,
  settings,
  command,
}

/// Immutable plugin inventory entry decoded once at the host boundary.
@immutable
final class CanonicalPlugin {
  const CanonicalPlugin._({
    required this.pluginId,
    required this.manifest,
    required this.desiredState,
    required this.runtimeState,
    required this.compatible,
    required this.grantsSatisfied,
    required this.generation,
    required this.failureCode,
    required this.failureRetryable,
  });

  factory CanonicalPlugin.fromHostDto(HostPluginUiStateDto wire) {
    if (wire.generation.isNegative) {
      throw const FormatException('negative plugin generation');
    }
    final manifest = PluginManifestDto.fromJsonString(wire.manifestJson);
    if (manifest.id != wire.pluginId) {
      throw const FormatException('plugin manifest owner mismatch');
    }
    return CanonicalPlugin._(
      pluginId: wire.pluginId,
      manifest: manifest,
      desiredState: _desiredState(wire.desiredState),
      runtimeState: _runtimeState(wire.runtimeState),
      compatible: wire.compatible,
      grantsSatisfied: wire.grantsSatisfied,
      generation: wire.generation,
      failureCode: wire.failureCode,
      failureRetryable: wire.failureRetryable,
    );
  }

  /// Canonical plugin identifier.
  final String pluginId;

  /// Strictly decoded canonical manifest.
  final PluginManifestDto manifest;

  /// Host-persisted desired state.
  final CanonicalDesiredState desiredState;

  /// Host-owned transient runtime state.
  final CanonicalRuntimeState runtimeState;

  /// Whether platform and host API compatibility passed.
  final bool compatible;

  /// Whether every activation grant is currently satisfied.
  final bool grantsSatisfied;

  /// Host lifecycle generation.
  final BigInt generation;

  /// Stable non-sensitive failure code.
  final String? failureCode;

  /// Whether retry may succeed without configuration changes.
  final bool failureRetryable;

  bool get _mayOwnActiveContributions {
    return desiredState == CanonicalDesiredState.enabled &&
        runtimeState == CanonicalRuntimeState.ready &&
        compatible &&
        grantsSatisfied;
  }
}

/// Immutable active contribution decoded once at the host boundary.
@immutable
final class ProjectedContribution {
  const ProjectedContribution._({
    required this.pluginId,
    required this.contributionId,
    required this.kind,
    required this.contribution,
    required this.route,
    required this.title,
    required this.iconToken,
    required this.rendererMode,
    required this.rendererContractId,
    required this.rendererSchemaVersion,
    required this.declarativeDocument,
  });

  factory ProjectedContribution.fromHostDto(HostProjectedContributionDto wire) {
    final decoded = jsonDecode(wire.contributionJson);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('contribution must be a JSON object');
    }
    final contribution = PluginContributionDto.fromJson(decoded);
    final kind = _contributionKind(contribution.kind);
    final contributionId = _contributionId(contribution);
    final metadata =
        contribution.descriptor['metadata'] as Map<String, Object?>;
    final display = metadata['display'] as Map<String, Object?>;
    final renderer = contribution.descriptor['renderer'];
    final rendererObject = renderer is Map<String, Object?> ? renderer : null;
    final needsRoute =
        kind == ContributionKind.navigation || kind == ContributionKind.page;
    if (needsRoute && (wire.route == null || wire.route!.isEmpty)) {
      throw const FormatException('projected route is missing');
    }
    if (!needsRoute && wire.route != null) {
      throw const FormatException('non-route contribution has a route');
    }
    final declarativeDocument = wire.declarativeDocument;
    final isDeclarative = rendererObject?['mode'] == 'declarative_v1';
    if (declarativeDocument != null &&
        (kind != ContributionKind.page &&
            kind != ContributionKind.dashboardCard)) {
      throw const FormatException(
        'declarative document has an invalid surface',
      );
    }
    if (declarativeDocument != null && !isDeclarative) {
      throw const FormatException(
        'declarative document has an invalid renderer',
      );
    }
    if (isDeclarative &&
        (kind == ContributionKind.page ||
            kind == ContributionKind.dashboardCard) &&
        declarativeDocument == null) {
      throw const FormatException('declarative document is missing');
    }
    final projectedDocument = declarativeDocument == null
        ? null
        : _declarativeDocument(declarativeDocument, contributionId);
    return ProjectedContribution._(
      pluginId: wire.pluginId,
      contributionId: contributionId,
      kind: kind,
      contribution: contribution,
      route: wire.route,
      title: display['title']! as String,
      iconToken: display['icon'] as String?,
      rendererMode: rendererObject?['mode'] as String?,
      rendererContractId: rendererObject?['contract_id'] as String?,
      rendererSchemaVersion: rendererObject?['schema_version'] as int?,
      declarativeDocument: projectedDocument,
    );
  }

  /// Canonical owner plugin id.
  final String pluginId;

  /// Canonical namespaced contribution id.
  final String contributionId;

  /// Pre-decoded contribution kind used by surface helpers.
  final ContributionKind kind;

  /// Strictly decoded canonical contribution DTO.
  final PluginContributionDto contribution;

  /// Host-generated route for page and navigation contributions.
  final String? route;

  /// Pre-decoded host display title.
  final String title;

  /// Optional host-recognized icon token.
  final String? iconToken;

  /// Canonical renderer mode when this contribution owns a renderer.
  final String? rendererMode;

  /// Bundled renderer contract id, never a plugin id.
  final String? rendererContractId;

  /// Bundled renderer payload schema version.
  final int? rendererSchemaVersion;

  /// Host-parsed, typed signed document for a declarative page or card.
  ///
  /// `null` is fail-closed: the generic renderer must never discover a
  /// resource through a manifest path or parse a raw document in Flutter.
  final DeclarativeV1Document? declarativeDocument;
}

DeclarativeV1Document _declarativeDocument(
  HostDeclarativeV1DocumentDto wire,
  String expectedContributionId,
) {
  if (wire.contributionId != expectedContributionId) {
    throw const FormatException('declarative document owner mismatch');
  }
  return DeclarativeV1Document(
    contributionId: wire.contributionId,
    root: _declarativeNode(wire.root),
  );
}

DeclarativeV1Node _declarativeNode(HostDeclarativeV1NodeDto wire) {
  return switch (wire) {
    HostDeclarativeV1NodeDto_Text(:final text) => DeclarativeV1TextNode(text),
    HostDeclarativeV1NodeDto_Metric(:final label, :final value) =>
      DeclarativeV1MetricNode(label: label, value: value),
    HostDeclarativeV1NodeDto_Stack(:final children) => DeclarativeV1StackNode(
      children.map(_declarativeNode).toList(growable: false),
    ),
    HostDeclarativeV1NodeDto_List(:final items) => DeclarativeV1ListNode(items),
  };
}

/// Immutable complete host publication used by Flutter plugin surfaces.
@immutable
final class ContributionSnapshot {
  ContributionSnapshot._({
    required this.revision,
    required List<CanonicalPlugin> plugins,
    required List<ProjectedContribution> active,
    required List<ProjectedContribution> navigation,
    required List<ProjectedContribution> pages,
    required List<ProjectedContribution> dashboardCards,
    required List<ProjectedContribution> dashboardCarousels,
    required List<ProjectedContribution> settings,
    required List<ProjectedContribution> commands,
  }) : plugins = List.unmodifiable(plugins),
       active = List.unmodifiable(active),
       navigation = List.unmodifiable(navigation),
       pages = List.unmodifiable(pages),
       dashboardCards = List.unmodifiable(dashboardCards),
       dashboardCarousels = List.unmodifiable(dashboardCarousels),
       settings = List.unmodifiable(settings),
       commands = List.unmodifiable(commands),
       pluginsById = UnmodifiableMapView({
         for (final plugin in plugins) plugin.pluginId: plugin,
       });

  /// Creates an empty snapshot, primarily for fail-safe hosts and tests.
  factory ContributionSnapshot.empty({required BigInt revision}) {
    if (revision.isNegative) {
      throw const FormatException('negative contribution revision');
    }
    return ContributionSnapshot._(
      revision: revision,
      plugins: const [],
      active: const [],
      navigation: const [],
      pages: const [],
      dashboardCards: const [],
      dashboardCarousels: const [],
      settings: const [],
      commands: const [],
    );
  }

  /// Strictly decodes one complete FRB host publication.
  factory ContributionSnapshot.fromHostDto(HostContributionSnapshotDto wire) {
    if (wire.revision.isNegative) {
      throw const FormatException('negative contribution revision');
    }
    final plugins = <CanonicalPlugin>[];
    final pluginsById = <String, CanonicalPlugin>{};
    final manifestContributions =
        <String, Map<String, _ManifestContribution>>{};
    for (final pluginWire in wire.plugins) {
      final plugin = CanonicalPlugin.fromHostDto(pluginWire);
      if (pluginsById.containsKey(plugin.pluginId)) {
        throw const FormatException('duplicate plugin id');
      }
      final descriptors = <String, PluginContributionDto>{};
      for (final contribution in plugin.manifest.contributions) {
        final contributionId = _contributionId(contribution);
        if (descriptors.containsKey(contributionId)) {
          throw const FormatException('duplicate manifest contribution id');
        }
        descriptors[contributionId] = contribution;
      }
      final pageRoutes = <String, String>{};
      final routeOwners = <String>{};
      for (final entry in descriptors.entries) {
        if (_contributionKind(entry.value.kind) != ContributionKind.page) {
          continue;
        }
        final viewId = entry.value.descriptor['view_id'];
        if (viewId is! String || viewId.isEmpty) {
          throw const FormatException('manifest page view id is missing');
        }
        final route = '/extensions/${plugin.pluginId}/$viewId';
        if (!routeOwners.add(route)) {
          throw const FormatException('duplicate manifest page route');
        }
        pageRoutes[entry.key] = route;
      }
      final contributions = <String, _ManifestContribution>{};
      for (final entry in descriptors.entries) {
        final kind = _contributionKind(entry.value.kind);
        final route = switch (kind) {
          ContributionKind.page => pageRoutes[entry.key],
          ContributionKind.navigation => _navigationRoute(
            entry.value,
            pageRoutes,
          ),
          _ => null,
        };
        contributions[entry.key] = _ManifestContribution(
          kind: kind,
          canonicalJson: jsonEncode(entry.value.toJson()),
          route: route,
        );
      }
      plugins.add(plugin);
      pluginsById[plugin.pluginId] = plugin;
      manifestContributions[plugin.pluginId] = contributions;
    }

    final active = <ProjectedContribution>[];
    final activeIds = <String>{};
    final navigation = <ProjectedContribution>[];
    final pages = <ProjectedContribution>[];
    final dashboardCards = <ProjectedContribution>[];
    final dashboardCarousels = <ProjectedContribution>[];
    final settings = <ProjectedContribution>[];
    final commands = <ProjectedContribution>[];
    for (final contributionWire in wire.active) {
      final contribution = ProjectedContribution.fromHostDto(contributionWire);
      final owner = pluginsById[contribution.pluginId];
      if (owner == null || !owner._mayOwnActiveContributions) {
        throw const FormatException('active contribution owner is not ready');
      }
      final manifestContribution =
          manifestContributions[contribution.pluginId]?[contribution
              .contributionId];
      if (manifestContribution == null ||
          manifestContribution.kind != contribution.kind ||
          manifestContribution.canonicalJson !=
              jsonEncode(contribution.contribution.toJson()) ||
          manifestContribution.route != contribution.route) {
        throw const FormatException('active contribution is not in manifest');
      }
      if (!activeIds.add(contribution.contributionId)) {
        throw const FormatException('duplicate active contribution id');
      }
      active.add(contribution);
      switch (contribution.kind) {
        case ContributionKind.navigation:
          navigation.add(contribution);
        case ContributionKind.page:
          pages.add(contribution);
        case ContributionKind.dashboardCard:
          dashboardCards.add(contribution);
        case ContributionKind.dashboardCarousel:
          dashboardCarousels.add(contribution);
        case ContributionKind.settings:
          settings.add(contribution);
        case ContributionKind.command:
          commands.add(contribution);
      }
    }

    return ContributionSnapshot._(
      revision: wire.revision,
      plugins: plugins,
      active: active,
      navigation: navigation,
      pages: pages,
      dashboardCards: dashboardCards,
      dashboardCarousels: dashboardCarousels,
      settings: settings,
      commands: commands,
    );
  }

  /// Host-owned complete publication revision.
  final BigInt revision;

  /// All canonical management entries in host order.
  final List<CanonicalPlugin> plugins;

  /// Plugin lookup index, built once per incoming snapshot.
  final Map<String, CanonicalPlugin> pluginsById;

  /// All currently projectable contributions in host order.
  final List<ProjectedContribution> active;

  /// Active navigation destinations.
  final List<ProjectedContribution> navigation;

  /// Active pages.
  final List<ProjectedContribution> pages;

  /// Active dashboard cards.
  final List<ProjectedContribution> dashboardCards;

  /// Active dashboard carousel entries.
  final List<ProjectedContribution> dashboardCarousels;

  /// Active settings sections.
  final List<ProjectedContribution> settings;

  /// Active commands.
  final List<ProjectedContribution> commands;
}

CanonicalDesiredState _desiredState(String value) {
  return switch (value) {
    'disabled' => CanonicalDesiredState.disabled,
    'enabled' => CanonicalDesiredState.enabled,
    _ => throw const FormatException('unknown desired state'),
  };
}

CanonicalRuntimeState _runtimeState(String value) {
  return switch (value) {
    'registered' => CanonicalRuntimeState.registered,
    'incompatible' => CanonicalRuntimeState.incompatible,
    'disabled' => CanonicalRuntimeState.disabled,
    'starting' => CanonicalRuntimeState.starting,
    'ready' => CanonicalRuntimeState.ready,
    'stopping' => CanonicalRuntimeState.stopping,
    'failed' => CanonicalRuntimeState.failed,
    _ => throw const FormatException('unknown runtime state'),
  };
}

ContributionKind _contributionKind(String value) {
  return switch (value) {
    'navigation' => ContributionKind.navigation,
    'page' => ContributionKind.page,
    'dashboard_card' => ContributionKind.dashboardCard,
    'dashboard_carousel' => ContributionKind.dashboardCarousel,
    'settings' => ContributionKind.settings,
    'command' => ContributionKind.command,
    _ => throw const FormatException('unknown contribution kind'),
  };
}

String _contributionId(PluginContributionDto contribution) {
  final metadata = contribution.descriptor['metadata'];
  if (metadata is! Map<String, Object?>) {
    throw const FormatException('contribution metadata is missing');
  }
  final contributionId = metadata['id'];
  if (contributionId is! String) {
    throw const FormatException('contribution id is missing');
  }
  return contributionId;
}

String _navigationRoute(
  PluginContributionDto contribution,
  Map<String, String> pageRoutes,
) {
  final pageId = contribution.descriptor['page_id'];
  if (pageId is! String || pageRoutes[pageId] == null) {
    throw const FormatException('navigation target page is missing');
  }
  return pageRoutes[pageId]!;
}

final class _ManifestContribution {
  const _ManifestContribution({
    required this.kind,
    required this.canonicalJson,
    required this.route,
  });

  final ContributionKind kind;
  final String canonicalJson;
  final String? route;
}
