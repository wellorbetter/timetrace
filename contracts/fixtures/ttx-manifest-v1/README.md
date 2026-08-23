# TTX manifest v1 shared fixture

`manifest.json` is the exact canonical UTF-8 `PluginManifest` v1 archive member. Its authoritative identity fields are `publisher` and `id`; its authoritative permission declarations are `requested_capabilities[].id` plus their attached constraints. `publisher_id`, `plugin_id`, and `permissions` are catalog projection fields and are forbidden in this archive member.

`payload-index.json` is the exact canonical empty payload-index v1 fixture. `signature-preimage.json` is the canonical JSON suffix of the publisher signature message. The complete message bytes are `ASCII("timetrace.ttx.publisher.v1\\0") || signature-preimage.json`, excluding each repository text file's terminal LF.

Both Worker publication validation and desktop archive installation must reject a semantically equivalent but byte-noncanonical control member. They must validate against `../../schema/ttx-manifest-v1.schema.json`, which references the canonical PluginManifest schema; the additional byte profile is described here because JSON Schema cannot encode it.

`marketplace-capability-requests.json` is the shared valid P0 capability matrix. Marketplace TTX v1 accepts only `usage.aggregate.read`, `ai.cloud`, and `ai.local`. Query bounds/granularities are valid only for `usage.aggregate.read`; exact lowercase DNS domains are valid only for `ai.cloud`; `ai.local` has an empty constraint object. All other PluginManifest capability IDs, including future syntactically valid IDs, are fail-closed until a desktop enforcement path and a new marketplace contract revision exist.

Marketplace P1 permits only the non-executable activation profile demonstrated by
`manifest-p1.json`: `page`, `navigation`, `dashboard_card`, and `settings`.
Pages and cards use only `declarative_v1`; `dashboard_carousel`, `command`,
`bundled_typed`, `wide` dashboard cards, secret-reference settings, and every
nonempty `required_capabilities` list are rejected. `nonempty-contributions.rejected.json`
is retained as a pre-P1 historical fixture and is now accepted because it is a
safe declarative page.

For each page/card contribution id `x`, the only admissible activation document
path is `resources/declarative-v1/x.json`; there is no manifest-selected path.
`resources/declarative-v1/sample-insights.overview.json` demonstrates the closed
v1 document grammar: `text`, `metric`, `stack`, and `list`. The parser limits a
document to 128 KiB, 256 nodes, depth 16, 64 children/items per container, and
4 KiB per text field. Documents cannot contain HTML, URLs, scripts, actions,
renderer identifiers, styles, dynamic queries, or executable payload references.
