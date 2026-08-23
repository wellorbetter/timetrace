# Marketplace First-Party Bundled v1 fixture

These are the only positive manifest fixtures for the P2 `private-flight` and
`ai-recap` entitlement profiles.  They are not valid Marketplace P1 input: their
`bundled_typed` renderer is intentionally rejected by
`ttx-manifest-v1.schema.json`.

`ai-recap.manifest.json` is an exact host entitlement: it must request
`usage.aggregate.read` and at least one of `ai.local`/`ai.cloud`, with empty
constraints.  The package cannot select a provider target, endpoint, or other
runtime policy.

The associated archive must contain only the three Marketplace control files.
`payload-index.json` is canonical and empty.  No payload or resource is
permitted, including an icon or a renderer asset.  Worker and host must apply
the normal canonical-control-file and publisher-signature checks as well as
the additional P2 profile/binding checks described in the OpenSpec change.
