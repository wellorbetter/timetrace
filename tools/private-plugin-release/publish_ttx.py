#!/usr/bin/env python3
"""Submit a verified TTX to the Marketplace publisher API; it never publishes it."""
from __future__ import annotations
import argparse, hashlib, json, os
from pathlib import Path
from urllib.request import Request, urlopen

def call(url: str, token: str, method: str, body: bytes | None, content_type: str) -> dict:
    request = Request(url, data=body, method=method, headers={"Authorization": f"Bearer {token}", "Content-Type": content_type, "Accept": "application/json"})
    with urlopen(request, timeout=60) as response:
        return json.loads(response.read())

def main() -> None:
    p = argparse.ArgumentParser(); p.add_argument("--base-url", required=True); p.add_argument("--token", help="Prefer MARKETPLACE_PUBLISHER_TOKEN environment variable in CI"); p.add_argument("--publisher", required=True); p.add_argument("--plugin", required=True); p.add_argument("--version", required=True); p.add_argument("--channel", choices=["stable", "beta"], default="stable"); p.add_argument("--archive", required=True); args = p.parse_args()
    token = args.token or os.environ.get("MARKETPLACE_PUBLISHER_TOKEN")
    if not token: raise RuntimeError("provide --token or MARKETPLACE_PUBLISHER_TOKEN")
    package = Path(args.archive).read_bytes(); digest = hashlib.sha256(package).hexdigest(); base = args.base_url.rstrip("/")
    release = call(base + "/api/marketplace/v1/publisher/releases", token, "POST", json.dumps({"publisher_id": args.publisher, "plugin_id": args.plugin, "version": args.version, "channel": args.channel, "package_bytes": len(package)}, separators=(",", ":")).encode(), "application/json")
    release_id = release["release_id"]
    call(base + release["upload"]["path"], token, "PUT", package, "application/octet-stream")
    complete = call(base + f"/api/marketplace/v1/publisher/releases/{release_id}/complete", token, "POST", json.dumps({"package_digest": digest}, separators=(",", ":")).encode(), "application/json")
    if complete.get("state") != "pending_review": raise RuntimeError(f"unexpected Marketplace state: {complete}")
    print(json.dumps({"release_id": release_id, "package_sha256": digest, "state": "pending_review"}, sort_keys=True))

if __name__ == "__main__": main()
