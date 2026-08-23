# Marketplace catalog v1 canonical fixture

`catalog.json` is a signed-envelope input fixture. Its member ordering is intentionally non-canonical; it also covers Unicode strings and exact millisecond UTC timestamps.

`canonical-signed.json` is the exact Marketplace v1 canonical JSON profile UTF-8 payload to verify: parse `catalog.json`, omit the top-level `signature` member, and compare byte-for-byte. The profile is intentionally narrower than generic RFC 8785/JCS: every signed object member is a schema-declared ASCII key, keys sort lexicographically, strings are UTF-8 JSON strings, and numbers are bounded integers. Dynamic BMP/astral Unicode object keys are rejected before canonicalization. The single terminal LF in this repository text file is not part of the canonical payload.

The signature member is fixed test data (`ed25519`, key id `marketplace-root-v1`, 64 zero bytes in unpadded base64url); it is structurally valid but is not an assertion of a production private-key signature.
