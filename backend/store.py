#!/usr/bin/env python3
"""Persistencia SQLite del backend: estado de zonas, cuotas diarias y cache
de geocodificacion. Sin logica de negocio (eso vive en quotas.py/worker.py) --
solo CRUD."""
import json
import sqlite3
from datetime import datetime, timezone


def _connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def init_db(db_path: str) -> None:
    conn = _connect(db_path)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS zones (
                zone_id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                stage TEXT,
                reason TEXT,
                lat REAL,
                lon REAL,
                size TEXT,
                name TEXT,
                created_at TEXT NOT NULL,
                meta_summary_json TEXT
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS quotas (
                kind TEXT NOT NULL,
                identifier TEXT NOT NULL,
                date TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (kind, identifier, date)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS geocode_cache (
                query TEXT PRIMARY KEY,
                results_json TEXT NOT NULL,
                cached_at TEXT NOT NULL
            )
        """)
        conn.commit()
        # Recuperacion de caidas: un proceso que muere a mitad de generar deja
        # una zona "generating" huerfana para siempre si nadie la re-encola.
        conn.execute("UPDATE zones SET status = 'queued', stage = NULL WHERE status = 'generating'")
        conn.commit()
    finally:
        conn.close()


def insert_zone_queued(db_path: str, zone_id: str, lat: float, lon: float, size: str, name: str) -> None:
    conn = _connect(db_path)
    try:
        conn.execute(
            "INSERT INTO zones (zone_id, status, stage, reason, lat, lon, size, name, created_at, meta_summary_json) "
            "VALUES (?, 'queued', NULL, NULL, ?, ?, ?, ?, ?, NULL)",
            (zone_id, lat, lon, size, name, _now()),
        )
        conn.commit()
    finally:
        conn.close()


def get_zone(db_path: str, zone_id: str):
    conn = _connect(db_path)
    try:
        row = conn.execute("SELECT * FROM zones WHERE zone_id = ?", (zone_id,)).fetchone()
        return dict(row) if row is not None else None
    finally:
        conn.close()


def get_queue_position(db_path: str, zone_id: str) -> int:
    """1-indexado, FIFO por orden de insercion real (rowid), no por timestamp
    (evita empates cuando dos zonas se encolan dentro del mismo segundo)."""
    conn = _connect(db_path)
    try:
        row = conn.execute(
            "SELECT COUNT(*) AS n FROM zones WHERE status = 'queued' "
            "AND rowid <= (SELECT rowid FROM zones WHERE zone_id = ?)",
            (zone_id,),
        ).fetchone()
        return row["n"]
    finally:
        conn.close()


def next_queued_zone(db_path: str):
    conn = _connect(db_path)
    try:
        row = conn.execute(
            "SELECT * FROM zones WHERE status = 'queued' ORDER BY rowid ASC LIMIT 1"
        ).fetchone()
        return dict(row) if row is not None else None
    finally:
        conn.close()


def update_zone_stage(db_path: str, zone_id: str, stage: str) -> None:
    conn = _connect(db_path)
    try:
        conn.execute(
            "UPDATE zones SET status = 'generating', stage = ? WHERE zone_id = ?", (stage, zone_id)
        )
        conn.commit()
    finally:
        conn.close()


def mark_zone_ready(db_path: str, zone_id: str, meta_summary: dict) -> None:
    conn = _connect(db_path)
    try:
        conn.execute(
            "UPDATE zones SET status = 'ready', stage = NULL, reason = NULL, meta_summary_json = ? "
            "WHERE zone_id = ?",
            (json.dumps(meta_summary), zone_id),
        )
        conn.commit()
    finally:
        conn.close()


def mark_zone_failed(db_path: str, zone_id: str, reason: str) -> None:
    conn = _connect(db_path)
    try:
        conn.execute(
            "UPDATE zones SET status = 'failed', stage = NULL, reason = ? WHERE zone_id = ?",
            (reason, zone_id),
        )
        conn.commit()
    finally:
        conn.close()


def list_catalog(db_path: str) -> list:
    conn = _connect(db_path)
    try:
        rows = conn.execute(
            "SELECT zone_id, name, size, meta_summary_json FROM zones WHERE status = 'ready' ORDER BY rowid ASC"
        ).fetchall()
        catalog = []
        for row in rows:
            summary = json.loads(row["meta_summary_json"])
            catalog.append({
                "zone_id": row["zone_id"],
                "name": row["name"],
                "zone_size": row["size"],
                "flags": summary["stats"]["flags"],
            })
        return catalog
    finally:
        conn.close()


def get_quota_count(db_path: str, kind: str, identifier: str, date: str) -> int:
    conn = _connect(db_path)
    try:
        row = conn.execute(
            "SELECT count FROM quotas WHERE kind = ? AND identifier = ? AND date = ?",
            (kind, identifier, date),
        ).fetchone()
        return row["count"] if row is not None else 0
    finally:
        conn.close()


def increment_quota(db_path: str, kind: str, identifier: str, date: str) -> None:
    conn = _connect(db_path)
    try:
        conn.execute(
            "INSERT INTO quotas (kind, identifier, date, count) VALUES (?, ?, ?, 1) "
            "ON CONFLICT(kind, identifier, date) DO UPDATE SET count = count + 1",
            (kind, identifier, date),
        )
        conn.commit()
    finally:
        conn.close()


def get_geocode_cache(db_path: str, query: str):
    conn = _connect(db_path)
    try:
        row = conn.execute(
            "SELECT results_json FROM geocode_cache WHERE query = ?", (query,)
        ).fetchone()
        return json.loads(row["results_json"]) if row is not None else None
    finally:
        conn.close()


def save_geocode_cache(db_path: str, query: str, results: list) -> None:
    conn = _connect(db_path)
    try:
        conn.execute(
            "INSERT INTO geocode_cache (query, results_json, cached_at) VALUES (?, ?, ?) "
            "ON CONFLICT(query) DO UPDATE SET results_json = excluded.results_json, cached_at = excluded.cached_at",
            (query, json.dumps(results), _now()),
        )
        conn.commit()
    finally:
        conn.close()
