"""Loader checks that need no database: headers, field counts, empty fields."""

from pathlib import Path

import pytest

from datarift_pipeline.importer import FILES, ImportFailed, read_rows, run_import

COLUMNS = ("a", "b", "c")


def _write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "x.csv"
    path.write_text(text, encoding="utf-8")
    return path


def test_empty_fields_become_null(tmp_path):
    rows = list(read_rows(_write(tmp_path, "a,b,c\n1,,3\n"), COLUMNS))
    assert rows == [["1", None, "3"]]


def test_header_must_match_contract(tmp_path):
    with pytest.raises(ImportFailed, match="nieprawidłowy nagłówek"):
        list(read_rows(_write(tmp_path, "a,c,b\n1,2,3\n"), COLUMNS))


def test_wrong_field_count_is_reported_with_line(tmp_path):
    with pytest.raises(ImportFailed, match="linia 3: 2 pól zamiast 3"):
        list(read_rows(_write(tmp_path, "a,b,c\n1,2,3\n1,2\n"), COLUMNS))


def test_empty_file(tmp_path):
    with pytest.raises(ImportFailed, match="pusty plik"):
        list(read_rows(_write(tmp_path, ""), COLUMNS))


def test_missing_files_fail_before_connecting(tmp_path):
    # The URL is never used: the file check comes first.
    with pytest.raises(ImportFailed, match="brak plików"):
        run_import(tmp_path, tmp_path / "fx.csv", "x", None, None, "t", "postgresql://invalid")


def test_loader_columns_match_generator_output(default_dataset):
    for f in FILES:
        assert tuple(default_dataset.header[f.name]) == f.columns, f.name


def test_period_comes_from_the_dataset(default_dataset):
    from datetime import date

    from datarift_pipeline.importer import dataset_period

    assert dataset_period(default_dataset.path) == (date(2024, 1, 1), date(2025, 12, 31))


def test_period_is_none_without_truth(tmp_path):
    from datarift_pipeline.importer import dataset_period

    assert dataset_period(tmp_path) is None
