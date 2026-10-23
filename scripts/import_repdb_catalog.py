#!/usr/bin/env python3
"""Import RepDB's free exercise data into the app's Supabase catalog."""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from pathlib import Path


SOURCE_NAME = "RepDB"
SOURCE_SCHEMA_VERSION = 3
EXPECTED_CATEGORY_COUNTS = {
    "stretching": 81,
    "strength": 530,
    "cardio": 19,
    "olympic": 16,
    "plyometrics": 4,
}
IMPORTED_CATEGORY_COUNTS = {
    "strength": 530,
    "cardio": 19,
    "olympic": 16,
    "plyometrics": 4,
}
MUSCLE_GROUPS = {
    "abductors": ("Glutes",),
    "adductors": ("Quads",),
    "anterior_deltoid": ("Shoulders",),
    "biceps_brachii": ("Biceps",),
    "brachialis": ("Biceps",),
    "brachioradialis": ("Biceps", "Forearms"),
    "erector_spinae": ("Back",),
    "forearm_extensors": ("Forearms",),
    "forearm_flexors": ("Forearms",),
    "forearms": ("Forearms",),
    "gastrocnemius": ("Calves",),
    "gluteus_maximus": ("Glutes",),
    "gluteus_medius": ("Glutes",),
    "hamstrings": ("Hamstrings",),
    "hip_flexors": ("Core",),
    "lateral_deltoid": ("Shoulders",),
    "latissimus_dorsi": ("Back",),
    "obliques": ("Core",),
    "pectoralis_major": ("Chest",),
    "posterior_deltoid": ("Shoulders",),
    "quadratus_lumborum": ("Core",),
    "quadriceps": ("Quads",),
    "rectus_abdominis": ("Core",),
    "rhomboids": ("Back",),
    "serratus_anterior": ("Chest", "Shoulders"),
    "soleus": ("Calves",),
    "supraspinatus": ("Shoulders",),
    "tibialis_anterior": ("Calves",),
    "transverse_abdominis": ("Core",),
    "trapezius": ("Back", "Shoulders"),
    "triceps_brachii": ("Triceps",),
}
UUID_NAMESPACE = uuid.UUID("3b11ea21-0ae4-4d6f-9fe3-1f5dc20f4704")
DEFAULT_ARCHIVE = Path(__file__).resolve().parents[1] / "repdb-free.zip"
REST_BATCH_SIZE = 50


def normalize_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def validate_dataset(payload: object) -> list[dict]:
    if not isinstance(payload, dict) or not isinstance(payload.get("exercises"), list):
        raise ValueError("The archive must contain free.json with an exercises array.")
    if payload.get("schema_version") != SOURCE_SCHEMA_VERSION:
        raise ValueError(
            f"Expected RepDB schema version {SOURCE_SCHEMA_VERSION}; "
            f"found {payload.get('schema_version')!r}."
        )

    exercises = payload["exercises"]
    category_counts = collections.Counter(
        exercise.get("category") for exercise in exercises if isinstance(exercise, dict)
    )
    if len(exercises) != sum(EXPECTED_CATEGORY_COUNTS.values()):
        raise ValueError(f"Unexpected RepDB record count: {len(exercises)}.")
    if dict(category_counts) != EXPECTED_CATEGORY_COUNTS:
        raise ValueError(f"Unexpected RepDB category counts: {dict(category_counts)}.")

    identifiers = set()
    imported = []
    for exercise in exercises:
        if not isinstance(exercise, dict):
            raise ValueError("Every exercise entry must be a JSON object.")
        identifier = exercise.get("id")
        name = exercise.get("name_en")
        if not isinstance(identifier, str) or not identifier.strip():
            raise ValueError("Every exercise must have a non-empty stable id.")
        if identifier in identifiers:
            raise ValueError(f"Duplicate RepDB exercise id: {identifier}.")
        identifiers.add(identifier)
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"Exercise {identifier} has no English display name.")

        for field in ("primary_muscles", "secondary_muscles", "goals", "tags", "synonyms"):
            values = exercise.get(field, [])
            if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                raise ValueError(f"Exercise {identifier} has an invalid {field} field.")
        if exercise["category"] != "stretching":
            imported.append(exercise)

    imported_counts = collections.Counter(exercise["category"] for exercise in imported)
    if dict(imported_counts) != IMPORTED_CATEGORY_COUNTS:
        raise ValueError(f"Unexpected import scope: {dict(imported_counts)}.")
    return imported


def read_archive(archive_path: Path) -> list[dict]:
    try:
        with zipfile.ZipFile(archive_path) as archive:
            payload = json.loads(archive.read("free.json"))
    except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        raise ValueError(f"Could not read free.json from {archive_path}: {error}") from error
    return validate_dataset(payload)


def match_legacy_exercises(
    exercises: list[dict], legacy_rows: list[dict]
) -> tuple[dict[str, str], list[str]]:
    alias_to_ids: dict[str, set[str]] = collections.defaultdict(set)
    name_to_ids: dict[str, set[str]] = collections.defaultdict(set)
    source_by_id = {exercise["id"]: exercise for exercise in exercises}
    for exercise in exercises:
        name_to_ids[normalize_name(exercise["name_en"])].add(exercise["id"])
        for alias in [exercise["name_en"], *exercise.get("synonyms", [])]:
            normalized = normalize_name(alias)
            if normalized:
                alias_to_ids[normalized].add(exercise["id"])

    matched: dict[str, str] = {}
    claimed_ids = set()
    unmatched = []
    for legacy in legacy_rows:
        name = legacy.get("name", "")
        normalized = normalize_name(name)
        compatible_names = [
            identifier for identifier in name_to_ids.get(normalized, set())
            if ("cardio" if source_by_id[identifier]["category"] == "cardio" else "strength")
            == legacy.get("exercise_type")
        ]
        compatible = compatible_names if compatible_names else [
            identifier for identifier in alias_to_ids.get(normalized, set())
            if ("cardio" if source_by_id[identifier]["category"] == "cardio" else "strength")
            == legacy.get("exercise_type")
        ]
        if len(compatible) == 1 and compatible[0] not in claimed_ids:
            matched[compatible[0]] = legacy["exercise_listing_id"]
            claimed_ids.add(compatible[0])
        else:
            unmatched.append(name)
    return matched, unmatched


def build_catalog_row(exercise: dict, listing_id: str) -> dict:
    category = exercise["category"]
    return {
        "exercise_listing_id": listing_id,
        "user_id": None,
        "name": exercise["name_en"].strip(),
        "description": exercise.get("description_en"),
        "exercise_type": "cardio" if category == "cardio" else "strength",
        "source_name": SOURCE_NAME,
        "source_exercise_id": exercise["id"],
        "category": category,
        "is_active": True,
        "equipment": exercise.get("equipment"),
        "body_part": exercise.get("body_part"),
        "difficulty": exercise.get("difficulty"),
        "force_type": exercise.get("force_type"),
        "mechanic": exercise.get("mechanic"),
        "met": exercise.get("met"),
        "is_unilateral": exercise.get("is_unilateral"),
        "is_bodyweight": exercise.get("is_bodyweight"),
        "goals": exercise.get("goals") or [],
        "tags": exercise.get("tags") or [],
        "synonyms": exercise.get("synonyms") or [],
        "primary_muscles": exercise.get("primary_muscles") or [],
        "secondary_muscles": exercise.get("secondary_muscles") or [],
        "localized_names": {
            language: exercise.get(f"name_{language}")
            for language in ("en", "de", "es")
        },
        "localized_descriptions": {
            language: exercise.get(f"description_{language}")
            for language in ("en", "de", "es")
        },
        "localized_instructions": {
            language: exercise.get(f"instructions_{language}", [])
            for language in ("en", "de", "es")
        },
        "localized_tips": {
            language: exercise.get(f"tips_{language}", [])
            for language in ("en", "de", "es")
        },
        "image_paths": exercise.get("images") or {},
        "source_data": exercise,
    }


def muscle_assignments(exercise: dict, listing_id: str, group_ids: dict[str, str]) -> set[tuple[str, str, str]]:
    assignments = set()
    for role, field in (
        ("primary", "primary_muscles"),
        ("secondary", "secondary_muscles"),
    ):
        for source_muscle in exercise.get(field, []):
            if source_muscle not in MUSCLE_GROUPS:
                raise ValueError(f"Unmapped RepDB muscle slug: {source_muscle}.")
            for group_name in MUSCLE_GROUPS[source_muscle]:
                group_id = group_ids.get(group_name)
                if not group_id:
                    raise ValueError(f"Required muscle group is missing from Supabase: {group_name}.")
                assignments.add((listing_id, group_id, role))
    return assignments


class SupabaseRest:
    def __init__(self, url: str, service_key: str):
        self.base_url = url.rstrip("/") + "/rest/v1"
        self.headers = {
            "apikey": service_key,
            "Authorization": "Bearer " + service_key,
            "Content-Type": "application/json",
        }

    def request(self, method: str, table: str, params: dict | None = None,
                payload: object | None = None, prefer: str | None = None) -> object:
        query = urllib.parse.urlencode(params or {}, doseq=True)
        url = f"{self.base_url}/{table}"
        if query:
            url += "?" + query
        headers = dict(self.headers)
        if prefer:
            headers["Prefer"] = prefer
        body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                response_body = response.read()
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8", errors="replace")[:500]
            raise RuntimeError(
                f"Supabase REST {method} {table} failed (HTTP {error.code}): {details}"
            ) from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"Could not connect to Supabase: {error.reason}") from error
        if not response_body:
            return None
        try:
            return json.loads(response_body)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            status = getattr(response, "status", "unknown")
            content_type = response.headers.get("Content-Type", "unknown")
            content_type = content_type.replace(self.headers["apikey"], "[REDACTED]")
            preview = response_body[:200].decode("utf-8", errors="replace")
            preview = re.sub(r"\s+", " ", preview)
            preview = preview.replace(self.headers["apikey"], "[REDACTED]")
            if len(response_body) > 200:
                preview += "..."
            raise RuntimeError(
                f"Supabase REST {method} {table} returned invalid JSON "
                f"(HTTP {status}, Content-Type: {content_type}); "
                f"response starts with {preview!r}."
            ) from error


def import_dataset(exercises: list[dict], client: SupabaseRest) -> tuple[int, int]:
    shared_rows = client.request(
        "GET",
        "exercise_listing",
        {
            "select": "exercise_listing_id,user_id,name,exercise_type,source_name,source_exercise_id",
            "user_id": "is.null",
            "limit": "1000",
        },
    )
    muscle_rows = client.request(
        "GET", "muscle_groups", {"select": "muscle_group_id,name", "limit": "1000"}
    )
    if not isinstance(shared_rows, list) or not isinstance(muscle_rows, list):
        raise RuntimeError("Supabase returned an unexpected catalog response.")

    group_ids = {row["name"]: row["muscle_group_id"] for row in muscle_rows}
    source_muscles = {
        muscle
        for exercise in exercises
        for muscle in exercise.get("primary_muscles", []) + exercise.get("secondary_muscles", [])
    }
    unmapped = sorted(source_muscles - MUSCLE_GROUPS.keys())
    if unmapped:
        raise ValueError(f"Unmapped RepDB muscle slugs: {', '.join(unmapped)}.")
    for muscle in source_muscles:
        for group_name in MUSCLE_GROUPS[muscle]:
            if group_name not in group_ids:
                raise RuntimeError(f"Required muscle group is missing from Supabase: {group_name}.")

    source_rows = {
        row["source_exercise_id"]: row
        for row in shared_rows
        if row.get("source_name") == SOURCE_NAME and row.get("source_exercise_id")
    }
    legacy_rows = [
        row for row in shared_rows
        if row.get("source_name") is None
    ]
    legacy_matches, unmatched_legacy = match_legacy_exercises(exercises, legacy_rows)
    listing_ids = {}
    catalog_rows = []
    for exercise in exercises:
        source_id = exercise["id"]
        existing = source_rows.get(source_id)
        listing_id = (
            existing["exercise_listing_id"] if existing
            else legacy_matches.get(source_id)
            or str(uuid.uuid5(UUID_NAMESPACE, f"{SOURCE_NAME}:{source_id}"))
        )
        listing_ids[source_id] = listing_id
        catalog_rows.append(build_catalog_row(exercise, listing_id))

    catalog_by_source_id = {
        row["source_exercise_id"]: row for row in catalog_rows
    }
    for source_id, listing_id in legacy_matches.items():
        client.request(
            "PATCH",
            "exercise_listing",
            {"exercise_listing_id": f"eq.{listing_id}"},
            catalog_by_source_id[source_id],
            prefer="return=minimal",
        )

    for offset in range(0, len(catalog_rows), REST_BATCH_SIZE):
        client.request(
            "POST",
            "exercise_listing",
            {"on_conflict": "source_name,source_exercise_id"},
            catalog_rows[offset:offset + REST_BATCH_SIZE],
            prefer="resolution=merge-duplicates,return=minimal",
        )

    assignments = set()
    for exercise in exercises:
        assignments.update(muscle_assignments(
            exercise, listing_ids[exercise["id"]], group_ids
        ))

    identifiers = list(listing_ids.values())
    for offset in range(0, len(identifiers), REST_BATCH_SIZE):
        batch = identifiers[offset:offset + REST_BATCH_SIZE]
        client.request(
            "DELETE",
            "exercise_muscle_groups",
            {"exercise_listing_id": f"in.({','.join(batch)})"},
            prefer="return=minimal",
        )

    relation_rows = [
        {
            "exercise_listing_id": listing_id,
            "muscle_group_id": group_id,
            "role": role,
        }
        for listing_id, group_id, role in sorted(assignments)
    ]
    for offset in range(0, len(relation_rows), REST_BATCH_SIZE):
        client.request(
            "POST",
            "exercise_muscle_groups",
            {"on_conflict": "exercise_listing_id,muscle_group_id,role"},
            relation_rows[offset:offset + REST_BATCH_SIZE],
            prefer="resolution=merge-duplicates,return=minimal",
        )

    client.request(
        "PATCH",
        "exercise_listing",
        {"user_id": "is.null", "source_name": "is.null"},
        {"is_active": False},
        prefer="return=minimal",
    )
    return len(legacy_matches), len(unmatched_legacy)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--archive",
        type=Path,
        default=DEFAULT_ARCHIVE,
        help="Path to RepDB's local free-tier ZIP (default: %(default)s).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate the archive and show the import scope without contacting Supabase.",
    )
    args = parser.parse_args(argv)

    try:
        exercises = read_archive(args.archive)
        counts = collections.Counter(exercise["category"] for exercise in exercises)
        print(f"Validated RepDB schema v{SOURCE_SCHEMA_VERSION}: {len(exercises)} exercises.")
        print("Import categories: " + ", ".join(
            f"{category}={counts[category]}" for category in IMPORTED_CATEGORY_COUNTS
        ))
        print("Stretching exercises excluded: 81.")
        if args.dry_run:
            return 0

        supabase_url = os.environ.get("SUPABASE_URL")
        service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        if not supabase_url or not service_key:
            raise ValueError(
                "Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment."
            )
        matched, unmatched = import_dataset(exercises, SupabaseRest(supabase_url, service_key))
        print(f"Imported {len(exercises)} exercises; preserved {matched} legacy exercise IDs.")
        print(f"Unmatched legacy shared exercises retained but hidden from pickers: {unmatched}.")
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print(f"RepDB import failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
