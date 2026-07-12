#!/usr/bin/env python3
"""Cuota diaria de generaciones frias: 3/dia UTC por X-Client-Id Y por IP, la
mas restrictiva bloquea (contrato ESPEC_SESION_CIUDADES2 §4). Solo se llama al
encolar una zona NUEVA -- descargar o reconsultar una zona ya existente nunca
pasa por aqui, por lo que nunca consume cuota."""
from datetime import datetime, timedelta, timezone

import store

MAX_COLD_GENERATIONS_PER_DAY = 3


def _today_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _next_reset_utc() -> str:
    tomorrow = (datetime.now(timezone.utc) + timedelta(days=1)).date()
    reset = datetime(tomorrow.year, tomorrow.month, tomorrow.day, tzinfo=timezone.utc)
    return reset.isoformat(timespec="seconds").replace("+00:00", "Z")


def check_and_increment(db_path: str, client_id: str, ip: str) -> dict:
    today = _today_utc()
    client_count = store.get_quota_count(db_path, "client", client_id, today)
    ip_count = store.get_quota_count(db_path, "ip", ip, today)
    if client_count >= MAX_COLD_GENERATIONS_PER_DAY or ip_count >= MAX_COLD_GENERATIONS_PER_DAY:
        return {"allowed": False, "resets_at": _next_reset_utc()}
    store.increment_quota(db_path, "client", client_id, today)
    store.increment_quota(db_path, "ip", ip, today)
    return {"allowed": True, "resets_at": None}
