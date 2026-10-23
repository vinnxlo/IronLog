import unittest
import uuid
from unittest.mock import patch

from scripts.import_repdb_catalog import (
    EXPECTED_CATEGORY_COUNTS,
    IMPORTED_CATEGORY_COUNTS,
    SOURCE_SCHEMA_VERSION,
    SupabaseRest,
    build_catalog_row,
    import_dataset,
    match_legacy_exercises,
    muscle_assignments,
    validate_dataset,
)


def synthetic_dataset():
    exercises = []
    index = 0
    for category, count in EXPECTED_CATEGORY_COUNTS.items():
        for _ in range(count):
            exercises.append({
                "id": f"exercise-{index}",
                "name_en": f"Exercise {index}",
                "category": category,
                "primary_muscles": [],
                "secondary_muscles": [],
                "goals": [],
                "tags": [],
                "synonyms": [],
            })
            index += 1
    return {"schema_version": SOURCE_SCHEMA_VERSION, "exercises": exercises}


class MemorySupabase:
    def __init__(self):
        self.rows = [
            {
                "exercise_listing_id": "legacy-match",
                "user_id": None,
                "name": "Exercise 81",
                "exercise_type": "strength",
                "source_name": None,
                "source_exercise_id": None,
                "is_active": True,
            },
            {
                "exercise_listing_id": "legacy-retire",
                "user_id": None,
                "name": "Legacy Move",
                "exercise_type": "strength",
                "source_name": None,
                "source_exercise_id": None,
                "is_active": True,
            },
        ]
        self.groups = [
            {"muscle_group_id": f"{name}-id", "name": name}
            for name in (
                "Chest", "Triceps", "Shoulders", "Biceps", "Forearms", "Back",
                "Quads", "Glutes", "Hamstrings", "Calves", "Core",
            )
        ]
        self.relations = []

    def request(self, method, table, params=None, payload=None, prefer=None):
        if method == "GET" and table == "exercise_listing":
            return [dict(row) for row in self.rows]
        if method == "GET" and table == "muscle_groups":
            return self.groups
        if method == "POST" and table == "exercise_listing":
            for incoming in payload:
                existing = next(
                    (row for row in self.rows
                     if row.get("source_name") == incoming["source_name"]
                     and row.get("source_exercise_id") == incoming["source_exercise_id"]),
                    None,
                )
                if existing:
                    existing.update(incoming)
                else:
                    self.rows.append(dict(incoming))
            return None
        if method == "DELETE" and table == "exercise_muscle_groups":
            return None
        if method == "POST" and table == "exercise_muscle_groups":
            self.relations.extend(payload)
            return None
        if method == "PATCH" and table == "exercise_listing":
            listing_filter = (params or {}).get("exercise_listing_id")
            if listing_filter:
                listing_id = listing_filter.removeprefix("eq.")
                for row in self.rows:
                    if row["exercise_listing_id"] == listing_id:
                        row.update(payload)
            else:
                for row in self.rows:
                    if row.get("user_id") is None and row.get("source_name") is None:
                        row.update(payload)
            return None
        raise AssertionError(f"Unexpected fake REST request: {method} {table}")


class RepDBImportTests(unittest.TestCase):
    def test_rest_client_builds_service_authorization_header(self):
        client = SupabaseRest("https://project.supabase.co/", "local-test-key")

        self.assertEqual(client.base_url, "https://project.supabase.co/rest/v1")
        self.assertEqual(client.headers["Authorization"], "Bearer local-test-key")

    def test_rest_client_decodes_json_response(self):
        client = SupabaseRest("https://project.supabase.co", "local-test-key")
        with patch("scripts.import_repdb_catalog.urllib.request.urlopen") as urlopen:
            response = urlopen.return_value.__enter__.return_value
            response.read.return_value = b'[{"name":"Chest"}]'

            result = client.request("GET", "muscle_groups")

        self.assertEqual(result, [{"name": "Chest"}])

    def test_rest_client_returns_none_for_empty_response(self):
        client = SupabaseRest("https://project.supabase.co", "local-test-key")
        with patch("scripts.import_repdb_catalog.urllib.request.urlopen") as urlopen:
            response = urlopen.return_value.__enter__.return_value
            response.read.return_value = b""

            result = client.request("PATCH", "exercise_listing")

        self.assertIsNone(result)

    def test_rest_client_reports_invalid_json_without_leaking_service_key(self):
        service_key = "local-test-secret"
        client = SupabaseRest("https://project.supabase.co", service_key)
        with patch("scripts.import_repdb_catalog.urllib.request.urlopen") as urlopen:
            response = urlopen.return_value.__enter__.return_value
            response.read.return_value = (
                b"<html>" + service_key.encode("utf-8") + b"x" * 300
            )
            response.status = 200
            response.headers = {"Content-Type": "text/html"}

            with self.assertRaisesRegex(
                RuntimeError, "Supabase REST GET muscle_groups returned invalid JSON"
            ) as raised:
                client.request("GET", "muscle_groups")

        message = str(raised.exception)
        self.assertIn("HTTP 200", message)
        self.assertIn("Content-Type: text/html", message)
        self.assertIn("[REDACTED]", message)
        self.assertIn("...", message)
        self.assertNotIn(service_key, message)

    def test_validation_excludes_stretching_and_keeps_supported_categories(self):
        imported = validate_dataset(synthetic_dataset())

        self.assertEqual(len(imported), sum(IMPORTED_CATEGORY_COUNTS.values()))
        self.assertEqual(
            {category: sum(row["category"] == category for row in imported)
             for category in IMPORTED_CATEGORY_COUNTS},
            IMPORTED_CATEGORY_COUNTS,
        )
        self.assertNotIn("stretching", {row["category"] for row in imported})

    def test_validation_rejects_an_unexpected_snapshot(self):
        payload = synthetic_dataset()
        payload["exercises"].pop()

        with self.assertRaisesRegex(ValueError, "Unexpected RepDB record count"):
            validate_dataset(payload)

    def test_catalog_row_maps_categories_without_losing_source_metadata(self):
        exercise = {
            "id": "clean-and-jerk",
            "name_en": "Clean and Jerk",
            "name_de": "Umsetzen und Stoßen",
            "category": "olympic",
            "description_en": "A barbell lift.",
            "primary_muscles": ["quadriceps"],
            "secondary_muscles": [],
            "goals": ["strength"],
            "tags": [],
            "synonyms": [],
            "instructions_en": ["Lift the bar."],
            "images": {"flat": {"main": "images/flat/clean-and-jerk-main.webp"}},
        }

        row = build_catalog_row(exercise, str(uuid.uuid4()))

        self.assertEqual(row["exercise_type"], "strength")
        self.assertEqual(row["category"], "olympic")
        self.assertEqual(row["localized_names"]["de"], "Umsetzen und Stoßen")
        self.assertEqual(row["image_paths"], exercise["images"])
        self.assertEqual(row["source_data"], exercise)

    def test_legacy_matching_uses_explicit_names_and_synonyms_only(self):
        exercises = [
            {
                "id": "bench-press",
                "name_en": "Bench Press",
                "category": "strength",
                "synonyms": ["Barbell Bench Press"],
            },
            {
                "id": "running",
                "name_en": "Running",
                "category": "cardio",
                "synonyms": [],
            },
        ]
        legacy = [
            {"exercise_listing_id": "legacy-bench", "name": "Barbell Bench-Press", "exercise_type": "strength"},
            {"exercise_listing_id": "legacy-run", "name": "Running", "exercise_type": "cardio"},
            {"exercise_listing_id": "legacy-unknown", "name": "Unlisted Move", "exercise_type": "strength"},
        ]

        matched, unmatched = match_legacy_exercises(exercises, legacy)

        self.assertEqual(matched, {"bench-press": "legacy-bench", "running": "legacy-run"})
        self.assertEqual(unmatched, ["Unlisted Move"])

    def test_ambiguous_legacy_alias_is_not_mapped(self):
        exercises = [
            {"id": "move-a", "name_en": "Move A", "category": "strength", "synonyms": ["Shared Alias"]},
            {"id": "move-b", "name_en": "Move B", "category": "strength", "synonyms": ["Shared Alias"]},
        ]

        matched, unmatched = match_legacy_exercises(
            exercises,
            [{"exercise_listing_id": "legacy", "name": "Shared Alias", "exercise_type": "strength"}],
        )

        self.assertEqual(matched, {})
        self.assertEqual(unmatched, ["Shared Alias"])

    def test_exact_name_takes_precedence_over_an_ambiguous_synonym(self):
        exercises = [
            {"id": "cycling", "name_en": "Cycling", "category": "cardio", "synonyms": []},
            {"id": "air-bike", "name_en": "Air Bike", "category": "cardio", "synonyms": ["Cycling"]},
        ]

        matched, unmatched = match_legacy_exercises(
            exercises,
            [{"exercise_listing_id": "legacy-cycling", "name": "Cycling", "exercise_type": "cardio"}],
        )

        self.assertEqual(matched, {"cycling": "legacy-cycling"})
        self.assertEqual(unmatched, [])

    def test_muscle_mapping_preserves_primary_and_secondary_roles(self):
        groups = {"Chest": "chest-id", "Triceps": "triceps-id", "Shoulders": "shoulders-id"}
        exercise = {
            "primary_muscles": ["pectoralis_major", "triceps_brachii"],
            "secondary_muscles": ["anterior_deltoid"],
        }

        assignments = muscle_assignments(exercise, "listing-id", groups)

        self.assertEqual(assignments, {
            ("listing-id", "chest-id", "primary"),
            ("listing-id", "triceps-id", "primary"),
            ("listing-id", "shoulders-id", "secondary"),
        })

    def test_import_is_repeatable_and_retires_only_unmatched_shared_rows(self):
        exercises = validate_dataset(synthetic_dataset())
        client = MemorySupabase()

        first_result = import_dataset(exercises, client)
        first_source_row = next(
            row for row in client.rows if row.get("source_exercise_id") == "exercise-81"
        )
        first_listing_id = first_source_row["exercise_listing_id"]
        second_result = import_dataset(exercises, client)
        second_source_row = next(
            row for row in client.rows if row.get("source_exercise_id") == "exercise-81"
        )

        self.assertEqual(first_result, (1, 1))
        self.assertEqual(second_result, (0, 1))
        self.assertEqual(first_listing_id, "legacy-match")
        self.assertEqual(second_source_row["exercise_listing_id"], first_listing_id)
        self.assertEqual(
            sum(row.get("source_name") == "RepDB" for row in client.rows),
            sum(IMPORTED_CATEGORY_COUNTS.values()),
        )
        self.assertFalse(next(row for row in client.rows if row["exercise_listing_id"] == "legacy-retire")["is_active"])


if __name__ == "__main__":
    unittest.main()
