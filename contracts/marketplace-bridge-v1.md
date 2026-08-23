# Marketplace Bridge / FRB v1 contract

This document freezes the desktop bridge boundary between a host-owned
Marketplace application service and Flutter. It is a typed projection of
already verified state, not a transport for catalog JSON or package contents.

## Ownership and route boundary

`MarketplaceBridgeProvider` is the only native provider that owns Marketplace
network fetches, pinned root-key verification, package fetching, publisher-key
lookup, archive verification, local storage, and installation. Flutter owns
only presentation state and user intent. Neither a plugin provider nor a Dart
route may invoke an arbitrary URL, load a manifest, resolve a signing key, or
write package bytes.

Flutter routes are host-owned `/extensions/marketplace` and
`/extensions/marketplace/:publisherId/:pluginId`. A route parameter is an
identifier for a detail lookup only; it is never a package location or a
release selector. The bridge provider is composed once in the desktop service
root and is not constructible from plugin code.

## Inputs

All identifiers use the existing lowercase bounded identifier grammar. Every
string bound is checked by Rust before any service action.

```text
MarketplaceCatalogQueryV1 {
  channel: stable | beta,              // default stable
  cursor: Option<opaque, <=512 bytes>,
  limit: 1..50                         // default host-selected, <=50
}

MarketplacePluginRefV1 {
  publisher_id: Identifier,
  plugin_id: Identifier
}

MarketplaceInstallRequestV1 {
  release: MarketplaceReleaseRefV1,
  consent_capability_ids: [MarketplaceCapabilityV1] // sorted, unique, exact
}
```

`platform`, host API version, package-size policy, installed versions, local
policy, and trust roots are native facts. Dart cannot submit or override them.
There is no free-text filter, offset, URL, raw JSON, raw manifest, ZIP bytes,
signature, public key, publisher key id, local path, package digest override,
or `force` field in any input.

## Host-produced outputs

```text
MarketplaceVerifiedCatalogPageV1 {
  schema_version: 1,
  catalog_revision: opaque <=128 bytes,
  generated_at: exact UTC milliseconds,
  items: [MarketplaceCatalogItemV1] <=50,
  next_cursor: Option<opaque <=512 bytes>
}

MarketplaceCatalogItemV1 {
  release: MarketplaceReleaseRefV1,
  display_name: bounded plain text <=128 bytes,
  description: Option<bounded plain text <=4096 bytes>,
  channel: MarketplaceChannelV1,
  state: MarketplaceReleaseStateV1,
  badges: [MarketplaceBadgeV1] <=4,
  compatibility: MarketplaceCompatibilityV1,
  permissions: [MarketplacePermissionReviewV1] <=3,
  package_bytes: 1..16777216,
  published_at: exact UTC milliseconds
}

MarketplacePluginDetailV1 {
  identity: MarketplacePluginRefV1,
  selected_release: MarketplaceCatalogItemV1,
  versions: [MarketplaceCatalogItemV1] <=50,
  install_plan: MarketplaceInstallPlanV1
}

MarketplaceReleaseRefV1 {
  release_id: UUID,
  publisher_id: Identifier,
  plugin_id: Identifier,
  version: SemVer,
  package_digest: lowercase SHA-256 hex
}

MarketplaceInstallPlanV1 {
  release: MarketplaceReleaseRefV1,
  disposition: MarketplaceInstallDispositionV1,
  required_consent: [MarketplacePermissionReviewV1],
  disk_bytes: 1..16777216
}
```

Only an internally stored `VerifiedMarketplaceCatalogPage` may be projected
into these DTOs. An invalid or unverified network catalog produces an error
output and no list/detail/install-plan DTO.

## Closed enums

```text
MarketplaceCapabilityV1 = usage_aggregate_read | ai_cloud | ai_local
MarketplaceChannelV1 = stable | beta
MarketplaceBadgeV1 = official | verified_publisher | beta | suspended | revoked
MarketplaceReleaseStateV1 = published | suspended | revoked
MarketplaceCompatibilityV1 = installable | update_available | already_installed |
                             incompatible_host_api | incompatible_platform |
                             package_too_large | permission_required |
                             blocked_local_policy | blocked_suspended | revoked
MarketplaceInstallDispositionV1 = same values as MarketplaceCompatibilityV1
MarketplaceOperationPhaseV1 = idle | checking | downloading | verifying |
                               installing | enabled | blocked | failed
MarketplaceBlockedReasonV1 = local_policy | suspended | revoked |
                             incompatible | permission_required
MarketplaceErrorCodeV1 = catalog_unavailable | catalog_invalid |
                         catalog_signature_invalid | not_found | invalid_request |
                         package_unavailable | package_too_large | digest_mismatch |
                         archive_invalid | release_identity_mismatch |
                         consent_mismatch | storage_unavailable | cancelled | internal
```

Unknown native enum variants must map to a non-installable `failed` result with
`internal`; they must never be rendered as a generic remote status. Error DTOs
contain only `MarketplaceErrorCodeV1`, `retryable`, and an optional host-issued
correlation id. They contain no raw Worker message, URL, filesystem path,
signature, key, manifest, or package content.

`MarketplacePermissionReviewV1` consists of a closed
`MarketplaceCapabilityV1`, a host-generated constrained summary, and an
optional bounded rationale. It is not an arbitrary capability string or remote
markup. The install request's `consent_capability_ids` must equal the plan's
required capability set exactly after sorting/deduplication; missing, extra,
unknown, or stale consent is rejected.

## Operations

`install(request)` first re-resolves `request.release` against the current
verified catalog/release cache and recomputes compatibility. It does not accept
“latest by plugin”, an external release id, or an older detail snapshot. The
host then emits host-produced `MarketplaceOperationStateV1` snapshots using the
closed phase/error enums. Cancellation is accepted only before the durable
local promotion boundary; after that boundary the eventual terminal state is
`enabled` or a stable failure, never a fabricated cancellation.

## Implementation and test gate

The future Rust bridge adapter should own DTO conversions in one module and
must be the sole FRB export surface. Required tests before enabling Flutter:

1. Rust DTO conversion starts only from `VerifiedMarketplaceCatalogPage` and
   cannot be called with raw catalog bytes.
2. Boundary tests reject query limit 0/51, oversized cursor, malformed route
   identifiers, duplicate/extra/missing consent IDs, and release-ref changes.
3. Serialization tests show no DTO or error output has URL, raw bytes, key,
   signature, manifest, archive path, or raw remote error field.
4. Flutter fake-port tests cover every closed phase, disposition, and error;
   unknown states are non-installable.
5. Integration tests prove the adapter rechecks the immutable release ref,
   catalog trust, digest, archive identity, and consent independently.

The existing local-only Flutter marketplace port is not this contract and must
be replaced or adapted only after these tests exist.
