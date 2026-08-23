# Plugin Marketplace P2 archive status

This branch preserves the experimental Marketplace, plugin lifecycle, and
first-party entitlement work for later product exploration. It is intentionally
separate from the minimal built-in AI Recap feature.

## Included

- Signed Marketplace catalog, package verification, registry, policy refresh,
  consent, rollback protection, and typed Flutter bridge/UI experiments.
- Declarative P1 rendering and exact first-party P2 entitlements for
  `private-flight` and `ai-recap`.
- Private-repository packaging and pending-review publishing templates. The
  templates contain placeholders only; signing keys remain outside Git.

## Deliberately excluded

- Local signing keys, credentials, generated packages, screenshots, logs,
  temporary packaging output, and Python bytecode caches.
- The broad unfinished core collector/storage refactor from the original dirty
  development worktree.
- Production deployment and remote database mutations.

## Current build status

This is a WIP archive, not a merge-ready or release-ready branch. The bridge
still references collector and flight-storage contracts from the excluded core
refactor (`ActivityCollector`, `CollectorHandle`, `WindowsActivityCollector`,
`FlightStore`, and related record types). Restore or redesign those contracts
before attempting to merge or ship this experiment.

The minimal built-in AI Recap feature must remain independent of this branch.
