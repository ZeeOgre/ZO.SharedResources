#!/usr/bin/env python3
"""
Renumber Starfield .mat local IDs in a CK Save As shaped way.

Observed CK Save As behavior:

    Changes:
      - top-level Filename
      - BSComponentDB::CTName Data.Name strings
      - local Objects[].ID values
      - local BSMaterial::*ID component Data.ID values
      - internal references/edges pointing to those local IDs

    Does not change:
      - Import
      - external Parent IDs
      - Summary
      - Version

Default mode is dry run. Use --apply to write files.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


RESOURCE_ID_RE = re.compile(
    r"\bres:(?P<head>[0-9a-fA-F]{8}):(?P<mid>[0-9a-fA-F]{8}):(?P<tail>[0-9a-fA-F]{8})\b",
    re.IGNORECASE,
)

FILENAME_RE = re.compile(
    r'"Filename"\s*:\s*"(?P<filename>[^"]*)"',
    re.IGNORECASE | re.DOTALL,
)

LOCAL_COMPONENT_ID_RE = re.compile(
    r'(?is)"Data"\s*:\s*\{\s*"ID"\s*:\s*"(?P<id>res:[0-9a-f]{8}:[0-9a-f]{8}:[0-9a-f]{8})"\s*\}\s*,\s*"Index"\s*:\s*\d+\s*,\s*"Type"\s*:\s*"BSMaterial::[^"]*ID"',
    re.IGNORECASE,
)

OBJECT_ID_RE = re.compile(
    r'(?is)"ID"\s*:\s*"(?P<id>res:[0-9a-f]{8}:[0-9a-f]{8}:[0-9a-f]{8})"\s*,\s*"Parent"\s*:',
    re.IGNORECASE,
)

CTNAME_COMPONENT_RE = re.compile(
    r'(?is)(?P<prefix>"Data"\s*:\s*\{\s*"Name"\s*:\s*")(?P<name>[^"]*)(?P<suffix>"\s*\}\s*,\s*"Index"\s*:\s*\d+\s*,\s*"Type"\s*:\s*"BSComponentDB::CTName")',
    re.IGNORECASE,
)


@dataclass
class MatFileInfo:
    path: Path
    text: str
    json_data: Any | None = None
    parse_error: str = ""
    all_ids: set[str] = field(default_factory=set)
    local_ids: list[str] = field(default_factory=list)
    internal_filename: str = ""


@dataclass
class ReplacementRecord:
    file: str
    relative_path: str
    internal_filename_before: str
    internal_filename_after: str
    old_id: str
    new_id: str
    occurrences_in_file: int
    colliding_files: str
    local_id_count: int
    ids_selected_count: int
    mode: str
    applied: bool
    filename_updated: bool
    ctnames_updated: int


def normalize_path_token(value: str) -> str:
    value = value.strip().replace("/", "\\")
    while value.startswith(".\\"):
        value = value[2:]
    while value.startswith("\\"):
        value = value[1:]
    return value


def normalize_resource_id(value: str) -> str:
    return value.upper()


def json_escape_string_value(value: str) -> str:
    # Produces a JSON string, then strips the surrounding quotes.
    return json.dumps(value)[1:-1]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig", errors="replace")


def write_text_utf8_no_bom(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="")


def get_mat_files(root: Path) -> list[Path]:
    if not root.exists():
        print(f"WARNING: root does not exist: {root}", file=sys.stderr)
        return []

    return sorted(p.resolve() for p in root.rglob("*.mat") if p.is_file())


def extract_all_resource_ids(text: str) -> set[str]:
    return {normalize_resource_id(m.group(0)) for m in RESOURCE_ID_RE.finditer(text)}


def get_internal_filename_from_text(text: str) -> str:
    match = FILENAME_RE.search(text)
    if not match:
        return ""

    return normalize_path_token(match.group("filename"))


def json_load_or_none(text: str) -> tuple[Any | None, str]:
    try:
        return json.loads(text), ""
    except Exception as ex:
        return None, str(ex)


def get_objects_array(json_data: Any) -> list[Any]:
    if not isinstance(json_data, dict):
        return []

    objects = json_data.get("Objects")
    if isinstance(objects, list):
        return objects

    for key, value in json_data.items():
        if isinstance(key, str) and key.lower() == "objects" and isinstance(value, list):
            return value

    return []


def append_unique(ids: list[str], value: str) -> None:
    normalized = normalize_resource_id(value)
    if normalized not in ids:
        ids.append(normalized)


def collect_local_ids_from_json(json_data: Any) -> list[str]:
    """
    Collect local IDs that CK Save As appears to regenerate:
      - Objects[].ID
      - BSMaterial::*ID component Data.ID
    """
    local_ids: list[str] = []

    for obj in get_objects_array(json_data):
        if not isinstance(obj, dict):
            continue

        object_id = obj.get("ID")
        if isinstance(object_id, str) and RESOURCE_ID_RE.fullmatch(object_id):
            append_unique(local_ids, object_id)

        components = obj.get("Components")
        if not isinstance(components, list):
            continue

        for component in components:
            if not isinstance(component, dict):
                continue

            component_type = component.get("Type")
            if not isinstance(component_type, str):
                continue

            if not (component_type.startswith("BSMaterial::") and component_type.endswith("ID")):
                continue

            data = component.get("Data")
            if not isinstance(data, dict):
                continue

            component_id = data.get("ID")
            if isinstance(component_id, str) and RESOURCE_ID_RE.fullmatch(component_id):
                append_unique(local_ids, component_id)

    return local_ids


def collect_local_ids_fallback(text: str) -> list[str]:
    local_ids: list[str] = []

    for match in OBJECT_ID_RE.finditer(text):
        append_unique(local_ids, match.group("id"))

    for match in LOCAL_COMPONENT_ID_RE.finditer(text):
        append_unique(local_ids, match.group("id"))

    return local_ids


def physical_material_path_from_data_root(data_root: Path, file_path: Path) -> str:
    relative = file_path.resolve().relative_to(data_root.resolve())
    return normalize_path_token(str(relative))


def update_internal_filename_text(text: str, new_filename: str) -> tuple[str, bool]:
    if not FILENAME_RE.search(text):
        return text, False

    escaped = json_escape_string_value(new_filename)

    def replace_once(_match: re.Match[str]) -> str:
        return f'"Filename" : "{escaped}"'

    new_text = FILENAME_RE.sub(replace_once, text, count=1)
    return new_text, new_text != text


def derive_ck_ctname(old_name: str, new_base_name: str) -> str:
    """
    CK Save As seems to turn:

        Data\\Materials\\Foo\\Old.mat
        Data\\Materials\\Foo\\Old.mat_Blender1

    into:

        NewBase
        NewBase_Blender1

    This preserves the suffix after ".mat" when present.
    """
    normalized = normalize_path_token(old_name)
    leaf = normalized.split("\\")[-1]

    match = re.search(r"(?i)\.mat(?P<suffix>_.*)?$", leaf)
    if match:
        suffix = match.group("suffix") or ""
        return f"{new_base_name}{suffix}"

    # Already CK-shaped, maybe OldBase_Layer1. Preserve known object suffixes when possible.
    known_suffix_match = re.search(
        r"(?i)(?P<suffix>_(?:Blender|Layer|Material|TextureSet|UVStream|Root|Node|Color|Scalar|Vector).*)$",
        leaf,
    )

    if known_suffix_match:
        return f"{new_base_name}{known_suffix_match.group('suffix')}"

    return new_base_name


def update_ctnames_text(text: str, new_base_name: str) -> tuple[str, int]:
    count = 0

    def repl(match: re.Match[str]) -> str:
        nonlocal count

        old_name = match.group("name")
        new_name = derive_ck_ctname(old_name, new_base_name)

        if new_name != old_name:
            count += 1

        return f'{match.group("prefix")}{json_escape_string_value(new_name)}{match.group("suffix")}'

    new_text = CTNAME_COMPONENT_RE.sub(repl, text)
    return new_text, count


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest().upper()


def new_full_resource_id_for_file(
    old_id: str,
    relative_path: str,
    ordinal: int,
    namespace: str,
    reserved_ids: set[str],
) -> str:
    if not RESOURCE_ID_RE.fullmatch(old_id):
        raise ValueError(f"Invalid resource ID: {old_id}")

    # CK-shaped: one shared middle/tail pair per target material,
    # and per-local-object first chunks.
    mid = sha256_hex(f"{namespace}|{relative_path}|MID")[:8]
    tail = sha256_hex(f"{namespace}|{relative_path}|TAIL")[:8]

    counter = 0

    while True:
        head = sha256_hex(f"{namespace}|{relative_path}|HEAD|{ordinal}|{old_id}|{counter}")[:8]
        new_id = f"res:{head}:{mid}:{tail}".upper()

        if new_id not in reserved_ids:
            reserved_ids.add(new_id)
            return new_id

        counter += 1

        if counter > 100000:
            raise RuntimeError(f"Could not generate non-colliding ID for {old_id} in {relative_path}")


def replace_mapped_resource_ids(text: str, id_map: dict[str, str]) -> str:
    if not id_map:
        return text

    def repl(match: re.Match[str]) -> str:
        old_id = normalize_resource_id(match.group(0))
        return id_map.get(old_id, match.group(0))

    return RESOURCE_ID_RE.sub(repl, text)


def backup_file(path: Path) -> Path:
    candidate = path.with_name(path.name + ".bak")

    if not candidate.exists():
        shutil.copy2(path, candidate)
        return candidate

    index = 1

    while True:
        candidate = path.with_name(path.name + f".bak.{index}")

        if not candidate.exists():
            shutil.copy2(path, candidate)
            return candidate

        index += 1


def id_appears_outside_file(res_id: str, this_file: Path, id_to_files: dict[str, set[Path]]) -> bool:
    normalized_id = normalize_resource_id(res_id)
    this_file = this_file.resolve()

    for other in id_to_files.get(normalized_id, set()):
        if other.resolve() != this_file:
            return True

    return False


def load_mat_info(path: Path) -> MatFileInfo:
    text = read_text(path)
    json_data, parse_error = json_load_or_none(text)

    info = MatFileInfo(
        path=path.resolve(),
        text=text,
        json_data=json_data,
        parse_error=parse_error,
        all_ids=extract_all_resource_ids(text),
        internal_filename=get_internal_filename_from_text(text),
    )

    if json_data is not None:
        info.local_ids = collect_local_ids_from_json(json_data)
    else:
        info.local_ids = collect_local_ids_fallback(text)

    return info


def should_skip_by_internal_prefix(info: MatFileInfo, required_prefix: str) -> bool:
    if not required_prefix.strip():
        return False

    if not info.internal_filename:
        return True

    return not info.internal_filename.lower().startswith(
        normalize_path_token(required_prefix).lower()
    )


def write_report(report_path: Path, records: list[ReplacementRecord]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = list(ReplacementRecord.__dataclass_fields__.keys())

    with report_path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for record in records:
            writer.writerow(record.__dict__)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Renumber Starfield .mat local IDs in a CK Save As shaped way."
    )

    parser.add_argument(
        "--target-root",
        required=True,
        help="Folder containing .mat files allowed to be modified.",
    )

    parser.add_argument(
        "--scan-root",
        action="append",
        default=[],
        help="Folder to scan for existing IDs. Can be passed multiple times.",
    )

    parser.add_argument(
        "--namespace",
        default="TG_Mat_CKShapeFullRemap_v2",
        help="Stable namespace for deterministic ID generation.",
    )

    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually modify files. Without this, dry run only.",
    )

    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Do not create .bak files when applying.",
    )

    parser.add_argument(
        "--report-path",
        default="",
        help="Optional CSV report path.",
    )

    parser.add_argument(
        "--require-internal-filename-prefix",
        default="",
        help='Optional gate, e.g. "Materials\\tankgirl\\". Files not matching are skipped.',
    )

    parser.add_argument(
        "--update-internal-filename",
        action="store_true",
        help='Update top-level "Filename" to match physical path relative to --data-root.',
    )

    parser.add_argument(
        "--update-ctnames",
        action="store_true",
        help='Update BSComponentDB::CTName Data.Name values to CK Save As style using the .mat file stem.',
    )

    parser.add_argument(
        "--data-root",
        default="",
        help='Required with --update-internal-filename, e.g. "G:\\SteamLibrary\\steamapps\\common\\Starfield\\Data".',
    )

    parser.add_argument(
        "--mode",
        choices=["all-local", "colliding-local"],
        default="all-local",
        help=(
            "all-local imitates CK Save As: remap every local ID in each target file. "
            "colliding-local only remaps local IDs seen outside the file."
        ),
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    target_root = Path(args.target_root).resolve()

    if not target_root.exists():
        print(f"ERROR: Target root does not exist: {target_root}", file=sys.stderr)
        return 1

    scan_roots = [Path(p).resolve() for p in args.scan_root]

    data_root: Path | None = None

    if args.update_internal_filename:
        if not args.data_root:
            print("ERROR: --data-root is required with --update-internal-filename.", file=sys.stderr)
            return 1

        data_root = Path(args.data_root).resolve()

        if not data_root.exists():
            print(f"ERROR: Data root does not exist: {data_root}", file=sys.stderr)
            return 1

    target_files = get_mat_files(target_root)

    scan_files_set: set[Path] = set()

    for root in scan_roots:
        scan_files_set.update(get_mat_files(root))

    # Always include target files so we can parse/process them.
    # But if no --scan-root was supplied, this is only the target set,
    # not the entire Materials tree.
    scan_files_set.update(p.resolve() for p in target_files)
    scan_files = sorted(scan_files_set)

    if not target_files:
        print(f"ERROR: No .mat files found under target root: {target_root}", file=sys.stderr)
        return 1

    if not scan_files:
        print("ERROR: No .mat files found to scan or process.", file=sys.stderr)
        return 1

    if args.report_path:
        report_path = Path(args.report_path).resolve()
    else:
        report_path = target_root / f"Renumber-MatIds_Report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"

    print()
    print("Target root:")
    print(f"  {target_root}")
    print()
    print("Scan roots:")

    if scan_roots:
        for root in scan_roots:
            print(f"  {root}")
    else:
        print("  <none; target files only>")

    for root in scan_roots:
        print(f"  {root}")

    print()
    print(f"Mode: {'APPLY' if args.apply else 'DRY RUN'}")
    print(f"Renumber mode: {args.mode}")
    print(f"Namespace: {args.namespace}")

    if args.require_internal_filename_prefix:
        print(f"Required internal Filename prefix: {args.require_internal_filename_prefix}")

    if args.update_internal_filename:
        print("Update internal Filename: True")
        print(f"Data root: {data_root}")

    if args.update_ctnames:
        print("Update CTNames: True")

    print()
    print(f"Target .mat files: {len(target_files)}")
    print(f"Scanned .mat files: {len(scan_files)}")
    print()

    print("Scanning MAT files...")

    info_by_path: dict[Path, MatFileInfo] = {}
    all_existing_ids: set[str] = set()
    id_to_files: dict[str, set[Path]] = {}
    parse_failures = 0

    for index, mat_file in enumerate(scan_files, start=1):
        if index % 1000 == 0:
            print(f"  scanned {index} / {len(scan_files)}")

        info = load_mat_info(mat_file)
        info_by_path[mat_file] = info

        if info.json_data is None:
            parse_failures += 1

        for res_id in info.all_ids:
            all_existing_ids.add(res_id)
            id_to_files.setdefault(res_id, set()).add(mat_file)

    reserved_ids = set(all_existing_ids)
    records: list[ReplacementRecord] = []

    total_files_changed = 0
    total_files_skipped_by_prefix = 0
    total_files_with_filename_updated = 0
    total_ctnames_updated = 0
    total_local_ids_seen = 0
    total_local_ids_selected = 0
    total_local_ids_colliding = 0
    total_occurrences_replaced = 0

    print()
    print(f"All existing resource IDs reserved: {len(all_existing_ids)}")
    print(f"JSON parse failures: {parse_failures}")
    print()
    print("Processing target files...")

    for mat_file in target_files:
        mat_file = mat_file.resolve()
        info = info_by_path.get(mat_file) or load_mat_info(mat_file)

        if should_skip_by_internal_prefix(info, args.require_internal_filename_prefix):
            total_files_skipped_by_prefix += 1
            print(f"Skipping due to internal Filename prefix: {mat_file}")
            continue

        original_text = info.text
        working_text = original_text

        relative_path = str(mat_file.relative_to(target_root)).replace("/", "\\")
        internal_filename_before = info.internal_filename
        internal_filename_after = internal_filename_before
        filename_updated = False
        ctnames_updated = 0

        if args.update_internal_filename and data_root is not None:
            try:
                new_filename = physical_material_path_from_data_root(data_root, mat_file)
            except ValueError:
                print(f"WARNING: file is not under data root, cannot update Filename: {mat_file}", file=sys.stderr)
                new_filename = internal_filename_before

            internal_filename_after = new_filename
            working_text, filename_updated = update_internal_filename_text(working_text, new_filename)

            if filename_updated:
                total_files_with_filename_updated += 1

        if args.update_ctnames:
            working_text, ctnames_updated = update_ctnames_text(working_text, mat_file.stem)
            total_ctnames_updated += ctnames_updated

        local_ids = list(info.local_ids)
        total_local_ids_seen += len(local_ids)

        ids_to_change: list[str] = []
        colliding_ids: set[str] = set()

        for local_id in local_ids:
            collides = id_appears_outside_file(local_id, mat_file, id_to_files)

            if collides:
                colliding_ids.add(local_id)

            if args.mode == "all-local" or collides:
                ids_to_change.append(local_id)

        total_local_ids_colliding += len(colliding_ids)
        total_local_ids_selected += len(ids_to_change)

        if not ids_to_change and not filename_updated and ctnames_updated == 0:
            continue

        id_map: dict[str, str] = {}

        for ordinal, old_id in enumerate(ids_to_change):
            new_id = new_full_resource_id_for_file(
                old_id=old_id,
                relative_path=relative_path,
                ordinal=ordinal,
                namespace=args.namespace,
                reserved_ids=reserved_ids,
            )

            id_map[old_id] = new_id

            occurrences = len(re.findall(re.escape(old_id), working_text, flags=re.IGNORECASE))
            total_occurrences_replaced += occurrences

            colliding_files = ";".join(
                str(p)
                for p in sorted(id_to_files.get(old_id, set()))
                if p.resolve() != mat_file
            )

            records.append(
                ReplacementRecord(
                    file=str(mat_file),
                    relative_path=relative_path,
                    internal_filename_before=internal_filename_before,
                    internal_filename_after=internal_filename_after,
                    old_id=old_id,
                    new_id=new_id,
                    occurrences_in_file=occurrences,
                    colliding_files=colliding_files,
                    local_id_count=len(local_ids),
                    ids_selected_count=len(ids_to_change),
                    mode=args.mode,
                    applied=args.apply,
                    filename_updated=filename_updated,
                    ctnames_updated=ctnames_updated,
                )
            )

        if id_map:
            working_text = replace_mapped_resource_ids(working_text, id_map)

        if (filename_updated or ctnames_updated > 0) and not id_map:
            records.append(
                ReplacementRecord(
                    file=str(mat_file),
                    relative_path=relative_path,
                    internal_filename_before=internal_filename_before,
                    internal_filename_after=internal_filename_after,
                    old_id="",
                    new_id="",
                    occurrences_in_file=0,
                    colliding_files="",
                    local_id_count=len(local_ids),
                    ids_selected_count=0,
                    mode=args.mode,
                    applied=args.apply,
                    filename_updated=filename_updated,
                    ctnames_updated=ctnames_updated,
                )
            )

        if working_text != original_text:
            total_files_changed += 1

            if args.apply:
                if not args.no_backup:
                    backup = backup_file(mat_file)
                    print(f"Backup: {backup}")

                write_text_utf8_no_bom(mat_file, working_text)
                print(f"Updated: {mat_file}")
            else:
                print(f"Would update: {mat_file}")

    write_report(report_path, records)

    print()
    print("Report written:")
    print(f"  {report_path}")
    print()
    print("Summary:")
    print(f"  Files changed or would change: {total_files_changed}")
    print(f"  Target files skipped by internal Filename prefix: {total_files_skipped_by_prefix}")
    print(f"  Files with internal Filename updated: {total_files_with_filename_updated}")
    print(f"  CTName values updated: {total_ctnames_updated}")
    print(f"  Local IDs seen in target files: {total_local_ids_seen}")
    print(f"  Local IDs colliding outside their file: {total_local_ids_colliding}")
    print(f"  Local IDs selected for renumbering: {total_local_ids_selected}")
    print(f"  ID occurrences replaced: {total_occurrences_replaced}")
    print()

    if not args.apply:
        print("Dry run only. Re-run with --apply to modify files.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())