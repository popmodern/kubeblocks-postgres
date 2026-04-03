#!/usr/bin/env python3

"""Generate the Supabase release asset checksum lockfile.

The Docker build should never depend on live GitHub API lookups. This script
refreshes the checked-in lockfile from GitHub release metadata ahead of time.

By default it reads the extension versions pinned in postgres-appliance/Dockerfile
and writes postgres-appliance/build_scripts/supabase_release_assets.sha256.

Authentication is optional but recommended to avoid low anonymous GitHub API
rate limits. Set GITHUB_TOKEN when running this script in CI or locally.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve()
BUILD_SCRIPTS_DIR = SCRIPT_PATH.parent
POSTGRES_APPLIANCE_DIR = BUILD_SCRIPTS_DIR.parent
REPO_ROOT = POSTGRES_APPLIANCE_DIR.parent
DOCKERFILE_PATH = POSTGRES_APPLIANCE_DIR / "Dockerfile"
OUTPUT_PATH = BUILD_SCRIPTS_DIR / "supabase_release_assets.sha256"

TARGET_EXTENSIONS = {
    "pg_graphql": "PG_GRAPHQL_VERSION",
    "pg_jsonschema": "PG_JSONSCHEMA_VERSION",
    "wrappers": "WRAPPERS_VERSION",
}


@dataclass(frozen=True)
class ReleaseTarget:
    repo: str
    version: str

    @property
    def tag(self) -> str:
        return f"v{self.version}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dockerfile",
        default=str(DOCKERFILE_PATH),
        help="Path to the Dockerfile that pins Supabase extension versions.",
    )
    parser.add_argument(
        "--output",
        default=str(OUTPUT_PATH),
        help="Path to the generated checksum lockfile.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the output file is up to date without rewriting it.",
    )
    return parser.parse_args()


def load_dockerfile_versions(dockerfile_path: Path) -> dict[str, str]:
    text = dockerfile_path.read_text(encoding="utf-8")
    versions: dict[str, str] = {}
    for env_name in TARGET_EXTENSIONS.values():
        match = re.search(rf"\b{re.escape(env_name)}=([^\s\\]+)", text)
        if not match:
            raise ValueError(f"Could not find {env_name} in {dockerfile_path}")
        versions[env_name] = match.group(1)
    return versions


def github_request(url: str) -> urllib.request.Request:
    headers = {"Accept": "application/vnd.github+json"}
    token = os.getenv("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def fetch_release_assets(target: ReleaseTarget) -> list[tuple[str, str]]:
    url = f"https://api.github.com/repos/supabase/{target.repo}/releases/tags/{target.tag}"
    request = github_request(url)

    try:
        with urllib.request.urlopen(request) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GitHub API request failed for {target.repo} {target.tag}: HTTP {exc.code}") from exc

    assets: list[tuple[str, str]] = []
    for asset in payload.get("assets", []):
        name = asset.get("name")
        digest = asset.get("digest") or ""
        if not name or not name.endswith(".deb"):
            continue
        if not digest.startswith("sha256:"):
            raise RuntimeError(
                f"Asset {name} in supabase/{target.repo} {target.tag} does not expose a sha256 digest"
            )
        assets.append((name, digest.split(":", 1)[1]))

    if not assets:
        raise RuntimeError(f"No .deb assets found for supabase/{target.repo} {target.tag}")

    return sorted(assets)


def render_output(targets: dict[str, ReleaseTarget]) -> str:
    lines = [
        "# GENERATED FILE. Do not edit by hand.",
        "# Regenerate with:",
        "#   python3 postgres-appliance/build_scripts/generate_supabase_release_assets.py",
        "#",
        "# This lockfile records GitHub release asset sha256 digests for the Supabase",
        "# native extension .deb packages consumed by postgres-appliance/build_scripts/base.sh.",
        "#",
        "# Authentication:",
        "#   Set GITHUB_TOKEN to avoid low anonymous GitHub API rate limits.",
        "#",
        "# Pinned release tags:",
    ]

    for repo_name, target in targets.items():
        lines.append(f"#   supabase/{repo_name} {target.tag}")

    lines.append("")

    entries: list[tuple[str, str]] = []
    for repo_name, target in targets.items():
        for asset_name, sha256 in fetch_release_assets(target):
            entries.append((asset_name, sha256))

    for asset_name, sha256 in sorted(entries):
        lines.append(f"{sha256}  {asset_name}")

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    dockerfile_path = Path(args.dockerfile).resolve()
    output_path = Path(args.output).resolve()

    versions = load_dockerfile_versions(dockerfile_path)
    targets = {
        repo_name: ReleaseTarget(repo=repo_name, version=versions[env_name])
        for repo_name, env_name in TARGET_EXTENSIONS.items()
    }
    rendered = render_output(targets)

    if args.check:
        existing = output_path.read_text(encoding="utf-8") if output_path.exists() else ""
        if existing != rendered:
            print(f"{output_path} is out of date. Regenerate it with:", file=sys.stderr)
            print(
                "  python3 postgres-appliance/build_scripts/generate_supabase_release_assets.py",
                file=sys.stderr,
            )
            return 1
        return 0

    output_path.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())