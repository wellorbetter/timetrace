#!/usr/bin/env python3
"""Build and verify the non-executable TimeTrace TTX v1 archive.

The signing private key is deliberately accepted only as a file path.  CI must
materialize that file from a GitHub Actions secret; never commit it.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys
import zipfile

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

PREFIX = b"timetrace.ttx.publisher.v1\0"
CONTROL = {"manifest.json", "payload-index.json", "signature.json", "release-attestation.json"}


def canonical(value: object) -> bytes:
    # This is the frozen Marketplace v1 canonical JSON profile: schema keys
    # are ASCII and all numbers are bounded integers. It deliberately mirrors
    # the Worker/Rust recursive lexical-key serializer, not generic JCS.
    if value is None or isinstance(value, (bool, int, float, str)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if isinstance(value, list):
        return b"[" + b",".join(canonical(item) for item in value) + b"]"
    if isinstance(value, dict):
        if not all(isinstance(key, str) and key.isascii() for key in value):
            raise ValueError("canonical object keys must be ASCII strings")
        return b"{" + b",".join(
            canonical(key) + b":" + canonical(value[key]) for key in sorted(value)
        ) + b"}"
    raise ValueError(f"unsupported JSON value: {type(value)!r}")


def exact_json(path: Path) -> tuple[object, bytes]:
    raw = path.read_bytes()
    value = json.loads(raw)
    encoded = canonical(value)
    # Source JSON may contain editor whitespace or a final newline.  The
    # archive always receives the canonical encoding which the Worker/host
    # require; this also keeps releases reproducible across editors.
    return value, encoded


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def unb64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def payload_entries(root: Path) -> list[tuple[str, bytes]]:
    if not root.exists():
        return []
    entries: list[tuple[str, bytes]] = []
    for path in sorted((p for p in root.rglob("*") if p.is_file()), key=lambda p: p.as_posix()):
        relative = path.relative_to(root).as_posix()
        member = PurePosixPath("resources") / relative
        if member.name in CONTROL or ".." in member.parts or member.is_absolute():
            raise ValueError(f"unsafe payload path: {relative}")
        entries.append((member.as_posix(), path.read_bytes()))
    return entries


def private_key(path: Path) -> Ed25519PrivateKey:
    key = serialization.load_pem_private_key(path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("signing key must be an Ed25519 PEM private key")
    return key


def public_key(path: Path) -> Ed25519PublicKey:
    key = serialization.load_pem_public_key(path.read_bytes())
    if not isinstance(key, Ed25519PublicKey):
        raise ValueError("public key must be an Ed25519 PEM public key")
    return key


def build(args: argparse.Namespace) -> None:
    manifest, manifest_bytes = exact_json(Path(args.manifest))
    payload = payload_entries(Path(args.payload_dir))
    index = {"files": [{"bytes": len(data), "path": name, "sha256": sha256(data)} for name, data in payload], "schema_version": 1}
    index_bytes = canonical(index)
    signer = private_key(Path(args.signing_key))
    message = PREFIX + canonical({"manifest": manifest, "payload_index": index})
    signature = {"algorithm": "ed25519", "key_id": args.key_id, "value": b64url(signer.sign(message))}
    signature_bytes = canonical(signature)
    archive = Path(args.out)
    archive.parent.mkdir(parents=True, exist_ok=True)
    members = [("manifest.json", manifest_bytes), ("payload-index.json", index_bytes), ("signature.json", signature_bytes), *payload]
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for name, data in members:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            zf.writestr(info, data)
    attestation = {
        "manifest_sha256": sha256(manifest_bytes), "package_bytes": archive.stat().st_size,
        "package_sha256": sha256(archive.read_bytes()), "publisher_key_id": args.key_id,
        "publisher_signature": signature["value"], "schema_version": 1,
        "source_revision": args.source_revision or os.environ.get("GITHUB_SHA", "local-unversioned"),
    }
    Path(args.attestation or str(archive) + ".attestation.json").write_bytes(canonical(attestation))
    print(json.dumps(attestation, sort_keys=True))


def verify(args: argparse.Namespace) -> None:
    with zipfile.ZipFile(args.archive) as zf:
        names = zf.namelist()
        if len(names) != len(set(names)) or not {"manifest.json", "payload-index.json", "signature.json"}.issubset(names):
            raise ValueError("invalid archive members")
        manifest_raw = zf.read("manifest.json"); index_raw = zf.read("payload-index.json"); signature_raw = zf.read("signature.json")
        manifest = json.loads(manifest_raw); index = json.loads(index_raw); signature = json.loads(signature_raw)
        if canonical(manifest) != manifest_raw or canonical(index) != index_raw or canonical(signature) != signature_raw:
            raise ValueError("non-canonical archive control member")
        for entry in index.get("files", []):
            data = zf.read(entry["path"])
            if len(data) != entry["bytes"] or sha256(data) != entry["sha256"]:
                raise ValueError(f"payload digest mismatch: {entry['path']}")
    if signature.get("algorithm") != "ed25519" or signature.get("key_id") != args.key_id:
        raise ValueError("unexpected signing algorithm or key id")
    public_key(Path(args.public_key)).verify(unb64url(signature["value"]), PREFIX + canonical({"manifest": manifest, "payload_index": index}))
    print(json.dumps({"ok": True, "package_sha256": sha256(Path(args.archive).read_bytes())}, sort_keys=True))


def export_public(args: argparse.Namespace) -> None:
    value = private_key(Path(args.signing_key)).public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    Path(args.out).write_bytes(value)


def export_jwk(args: argparse.Namespace) -> None:
    raw = private_key(Path(args.signing_key)).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    print(canonical({"crv": "Ed25519", "kty": "OKP", "x": b64url(raw)}).decode("utf-8"))


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    commands = p.add_subparsers(dest="command", required=True)
    b = commands.add_parser("build"); b.add_argument("--manifest", required=True); b.add_argument("--payload-dir", default="resources"); b.add_argument("--signing-key", required=True); b.add_argument("--key-id", required=True); b.add_argument("--out", required=True); b.add_argument("--attestation"); b.add_argument("--source-revision"); b.set_defaults(func=build)
    v = commands.add_parser("verify"); v.add_argument("--archive", required=True); v.add_argument("--public-key", required=True); v.add_argument("--key-id", required=True); v.set_defaults(func=verify)
    e = commands.add_parser("public-key"); e.add_argument("--signing-key", required=True); e.add_argument("--out", required=True); e.set_defaults(func=export_public)
    j = commands.add_parser("publisher-jwk"); j.add_argument("--signing-key", required=True); j.set_defaults(func=export_jwk)
    return p


if __name__ == "__main__":
    try:
        args = parser().parse_args(); args.func(args)
    except Exception as error:
        print(f"TTX build failed: {error}", file=sys.stderr); sys.exit(1)
