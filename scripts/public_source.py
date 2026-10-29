#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Create and verify a manifest-bound, history-free public source tree."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import zipfile


MANIFEST = "PUBLIC_SOURCE_MANIFEST.tsv"
MANIFEST_HEADER = "path\tmode\tsize\tsha256"


class PublicSourceError(Exception):
    """A deterministic public-source policy failure."""


REGEX_RULES = (
    (
        "private email address",
        re.compile(
            rb"(?i)[a-z0-9._%+-]+@(gmail|googlemail|icloud|me|mac|outlook|hotmail|yahoo)\.[a-z]{2,}"
        ),
    ),
    (
        "credential assignment",
        re.compile(
            rb"(?i)(access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|password)"
            rb"\s*[:=]\s*[\"']?[a-z0-9_./+\-=]{8,}"
        ),
    ),
    (
        "bearer credential",
        re.compile(rb"(?i)authorization\s*[:=]\s*[\"']?bearer\s+[a-z0-9._~+/=-]{8,}"),
    ),
    ("private key material", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"gh[opsu]_[A-Za-z0-9]{20,}")),
    ("OpenAI key", re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{20,}")),
    ("Anthropic key", re.compile(rb"sk-ant-[A-Za-z0-9_-]{20,}")),
)


def validated_relative_path(raw: str, *, label: str) -> PurePosixPath:
    if not raw or "\x00" in raw or "\t" in raw or "\n" in raw or "\\" in raw:
        raise PublicSourceError(f"{label} contains an unsafe path: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or raw != path.as_posix() or any(part in ("", ".", "..") for part in path.parts):
        raise PublicSourceError(f"{label} contains an unsafe path: {raw!r}")
    if ".git" in path.parts:
        raise PublicSourceError(f"{label} may not include .git: {raw}")
    if raw == MANIFEST:
        raise PublicSourceError(f"{label} may not include the generated {MANIFEST}")
    return path


def ensure_regular_path(root: Path, relative: PurePosixPath, *, label: str) -> os.stat_result:
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise PublicSourceError(f"{label} is or traverses a symlink: {relative.as_posix()}")
    try:
        metadata = current.stat()
    except FileNotFoundError as error:
        raise PublicSourceError(f"{label} is missing: {relative.as_posix()}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise PublicSourceError(f"{label} is not a regular file: {relative.as_posix()}")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode not in (0o644, 0o755):
        raise PublicSourceError(f"{label} has unsupported mode {mode:04o}: {relative.as_posix()}")
    return metadata


def load_allowlist(root: Path, relative_name: str) -> tuple[PurePosixPath, ...]:
    allowlist_path = validated_relative_path(relative_name, label="allowlist")
    absolute = root.joinpath(*allowlist_path.parts)
    ensure_regular_path(root, allowlist_path, label="allowlist")
    lines = absolute.read_text(encoding="utf-8").splitlines()
    raw_paths = [line for line in lines if line and not line.startswith("#")]
    if raw_paths != sorted(raw_paths) or len(raw_paths) != len(set(raw_paths)):
        raise PublicSourceError("allowlist entries must be unique and bytewise sorted")
    paths = tuple(validated_relative_path(raw, label="allowlist") for raw in raw_paths)
    if allowlist_path not in paths:
        raise PublicSourceError("allowlist must include itself")
    return paths


def scan_bytes(relative: PurePosixPath, payload: bytes) -> None:
    for label, pattern in REGEX_RULES:
        if pattern.search(payload):
            raise PublicSourceError(f"{relative.as_posix()}: rejected {label}")


def scan_artifact_bytes(relative: PurePosixPath, payload: bytes) -> None:
    for label, pattern in REGEX_RULES:
        if label != "private email address" and pattern.search(payload):
            raise PublicSourceError(f"{relative.as_posix()}: rejected {label}")


def scan_artifact(path: Path) -> None:
    if path.is_symlink():
        raise PublicSourceError("public artifact may not be a symlink")
    scan_artifact_bytes(PurePosixPath(path.name), path.name.encode("utf-8"))
    scan_artifact_bytes(
        PurePosixPath(path.name),
        re.sub(rb"[^a-z0-9]", b"", path.name.lower().encode("utf-8")),
    )
    if path.is_dir():
        root = path.resolve(strict=True)
        for item in sorted(root.rglob("*")):
            relative = PurePosixPath(item.relative_to(root).as_posix())
            scan_artifact_bytes(relative, relative.as_posix().encode("utf-8"))
            if item.is_symlink():
                raise PublicSourceError(f"public artifact contains a symlink: {relative}")
            if item.is_file():
                scan_artifact_bytes(relative, item.read_bytes())
        return
    if not path.is_file():
        raise PublicSourceError("public artifact is not a regular file or directory")
    if zipfile.is_zipfile(path):
        total = 0
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                relative = validated_relative_path(info.filename.rstrip("/"), label="archive member")
                scan_artifact_bytes(relative, relative.as_posix().encode("utf-8"))
                if info.is_dir():
                    continue
                total += info.file_size
                if total > 512 * 1_024 * 1_024:
                    raise PublicSourceError("public artifact exceeds the scan size limit")
                scan_artifact_bytes(relative, archive.read(info))
        return
    scan_artifact_bytes(PurePosixPath(path.name), path.read_bytes())


def record_for(root: Path, relative: PurePosixPath, *, scan: bool = True) -> tuple[str, str, int, str]:
    metadata = ensure_regular_path(root, relative, label="public source file")
    payload = root.joinpath(*relative.parts).read_bytes()
    if scan:
        scan_bytes(relative, relative.as_posix().encode("utf-8"))
        scan_bytes(relative, payload)
    return (
        relative.as_posix(),
        f"{stat.S_IMODE(metadata.st_mode):04o}",
        len(payload),
        hashlib.sha256(payload).hexdigest(),
    )


def manifest_text(records: list[tuple[str, str, int, str]]) -> str:
    rows = [MANIFEST_HEADER]
    rows.extend(f"{path}\t{mode}\t{size}\t{digest}" for path, mode, size, digest in records)
    return "\n".join(rows) + "\n"


def assert_tree_shape(root: Path, allowed: set[str]) -> None:
    if not root.is_dir() or root.is_symlink():
        raise PublicSourceError(f"export root is not a real directory: {root}")
    seen: set[str] = set()
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in directory_names:
            child = base / name
            relative = child.relative_to(root).as_posix()
            if name == ".git" or child.is_symlink():
                raise PublicSourceError(f"export contains forbidden directory: {relative}")
        for name in file_names:
            child = base / name
            relative = child.relative_to(root).as_posix()
            if child.is_symlink():
                raise PublicSourceError(f"export contains symlink: {relative}")
            if relative not in allowed and relative != MANIFEST:
                raise PublicSourceError(f"export contains non-allowlisted file: {relative}")
            seen.add(relative)
    expected = allowed | {MANIFEST}
    if seen != expected:
        missing = sorted(expected - seen)
        extra = sorted(seen - expected)
        raise PublicSourceError(f"export file set mismatch; missing={missing} extra={extra}")


def parse_manifest(root: Path) -> list[tuple[str, str, int, str]]:
    manifest_path = root / MANIFEST
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise PublicSourceError(f"missing regular {MANIFEST}")
    lines = manifest_path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != MANIFEST_HEADER:
        raise PublicSourceError(f"invalid {MANIFEST} header")
    records: list[tuple[str, str, int, str]] = []
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 4:
            raise PublicSourceError(f"invalid {MANIFEST} row")
        raw_path, mode, raw_size, digest = fields
        relative = validated_relative_path(raw_path, label="manifest")
        if not re.fullmatch(r"0[0-7]{3}", mode):
            raise PublicSourceError(f"invalid manifest mode for {raw_path}")
        if not raw_size.isdigit() or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise PublicSourceError(f"invalid manifest metadata for {raw_path}")
        records.append((relative.as_posix(), mode, int(raw_size), digest))
    if records != sorted(records) or len(records) != len({record[0] for record in records}):
        raise PublicSourceError("manifest records must be unique and sorted")
    return records


def verify(root: Path, allowlist_name: str) -> None:
    if root.is_symlink():
        raise PublicSourceError("export root may not be a symlink")
    root = root.resolve(strict=True)
    paths = load_allowlist(root, allowlist_name)
    allowed = {path.as_posix() for path in paths}
    assert_tree_shape(root, allowed)
    expected = [record_for(root, path) for path in paths]
    observed = parse_manifest(root)
    if observed != expected:
        raise PublicSourceError("manifest readback does not match exported bytes, modes, sizes, and paths")


def export(root: Path, destination: Path, allowlist_name: str) -> None:
    if root.is_symlink():
        raise PublicSourceError("source root may not be a symlink")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise PublicSourceError("source root must be a real directory")
    paths = load_allowlist(root, allowlist_name)
    records = [record_for(root, path) for path in paths]

    if destination.exists() or destination.is_symlink():
        raise PublicSourceError("destination must be a caller-specified path that does not exist")
    parent = destination.parent.resolve(strict=True)
    resolved_destination = parent / destination.name
    if resolved_destination == root or root in resolved_destination.parents:
        raise PublicSourceError("destination may not be the source repository or inside it")

    created = False
    try:
        resolved_destination.mkdir(mode=0o755)
        created = True
        for relative, mode, _, _ in records:
            source = root.joinpath(*PurePosixPath(relative).parts)
            target = resolved_destination.joinpath(*PurePosixPath(relative).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target, follow_symlinks=False)
            target.chmod(int(mode, 8))
        (resolved_destination / MANIFEST).write_text(manifest_text(records), encoding="utf-8")
        (resolved_destination / MANIFEST).chmod(0o644)
        verify(resolved_destination, allowlist_name)
    except Exception:
        if created:
            shutil.rmtree(resolved_destination)
        raise
    print(f"Public source export verified: {resolved_destination}")
    print(f"Manifest records: {len(records)}")


def expect_failure(callable_object, message: str) -> None:
    try:
        callable_object()
    except PublicSourceError:
        return
    raise PublicSourceError(f"self-test expected rejection: {message}")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="rationbook-public-source-test-") as temporary:
        sandbox = Path(temporary)
        source = sandbox / "source"
        source.mkdir()
        (source / "scripts").mkdir()
        (source / "README.md").write_text("public\n", encoding="utf-8")
        (source / "scripts" / "run.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (source / "scripts" / "run.sh").chmod(0o755)
        allowlist = source / "allowlist.txt"
        allowlist.write_text("README.md\nallowlist.txt\nscripts/run.sh\n", encoding="utf-8")

        destination = sandbox / "export"
        export(source, destination, "allowlist.txt")
        verify(destination, "allowlist.txt")

        (destination / "README.md").write_text("changed\n", encoding="utf-8")
        expect_failure(lambda: verify(destination, "allowlist.txt"), "changed bytes")

        destination_two = sandbox / "export-two"
        export(source, destination_two, "allowlist.txt")
        (destination_two / "extra").write_text("extra\n", encoding="utf-8")
        expect_failure(lambda: verify(destination_two, "allowlist.txt"), "extra file")
        (destination_two / "extra").unlink()
        (destination_two / "link").symlink_to("README.md")
        expect_failure(lambda: verify(destination_two, "allowlist.txt"), "symlink")

    print("Public source tool self-tests passed")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("destination", type=Path)
    export_parser.add_argument("--root", type=Path, required=True)
    export_parser.add_argument("--allowlist", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--root", type=Path, required=True)
    verify_parser.add_argument("--allowlist", required=True)
    artifact_parser = subparsers.add_parser("scan-artifact")
    artifact_parser.add_argument("path", type=Path)
    subparsers.add_parser("self-test")
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "export":
            export(arguments.root, arguments.destination, arguments.allowlist)
        elif arguments.command == "verify":
            verify(arguments.root, arguments.allowlist)
            print(f"Public source export verified: {arguments.root.resolve()}")
        elif arguments.command == "scan-artifact":
            scan_artifact(arguments.path)
            print(f"Public artifact byte scan passed: {arguments.path.resolve()}")
        else:
            self_test()
    except (OSError, UnicodeError, PublicSourceError) as error:
        print(f"public-source: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
