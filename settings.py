# -*- coding: utf-8 -*-
"""ITtool: настройки — организация, ИИ, почта, Telegram, папка выгрузок, копии базы."""
from __future__ import annotations

import datetime
import os
from pathlib import Path

import db
import reports


def export_dir() -> Path:
    """Куда класть выгрузки: из настроек или ~/ITtool-выгрузки."""
    d = Path(os.path.expanduser(db.get_ui_prefs().get("export_dir") or "~/ITtool-выгрузки"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def export_path(name) -> str:
    """Свободное имя в папке выгрузок: «Отчёт.docx», «Отчёт (2).docx»…"""
    d = export_dir()
    p = d / name
    stem, ext, i = p.stem, p.suffix, 2
    while p.exists():
        p = d / f"{stem} ({i}){ext}"
        i += 1
    return str(p)


def get_all():
    """Всё, что показывает экран настроек."""
    data = reports.load_data()
    st = data["settings"]
    ai, em = st.get("ai") or {}, st.get("email") or {}
    pd = db.get_purchase_defaults()
    return {
        "org": db.get_org_profile(),
        "report": {"branch": st.get("branch", ""), "responsible": st.get("responsible", "")},
        "director": {"title": pd.get("director_title", "Директор"),
                     "name": pd.get("director", "")},
        "ai": {"base_url": ai.get("base_url", ""), "model": ai.get("model", ""),
               "api_key": ai.get("api_key", "")},
        "email": {"server": em.get("server", ""), "port": str(em.get("port", "465")),
                  "security": em.get("security", "SSL"), "sender": em.get("sender", ""),
                  "password": em.get("password", ""), "recipient": em.get("recipient", "")},
        "tg": db.get_tg_config(),
        "export_dir": db.get_ui_prefs().get("export_dir", "") or "",
    }


def save_all(d):
    """Сохранить экран настроек. ИИ — в обе копии (отчёт и учёт), как раньше."""
    org = d.get("org") or {}
    db.set_org_profile(**{k: str(org.get(k, "")) for k in
                          ("org_name", "branch", "branch_gen", "fio", "position", "accountant")})
    ai = {k: str((d.get("ai") or {}).get(k, "")).strip() for k in ("base_url", "model", "api_key")}
    e = d.get("email") or {}
    rep = d.get("report") or {}
    with reports.report_tx() as data:
        st = data["settings"]
        st["branch"] = str(rep.get("branch", "")).strip()
        st["responsible"] = str(rep.get("responsible", "")).strip()
        st["ai"].update(ai)
        em = st["email"]
        em["server"] = str(e.get("server", "")).strip()
        em["port"] = str(e.get("port", "")).strip()
        em["security"] = e.get("security") or "SSL"
        em["sender"] = str(e.get("sender", "")).strip()
        em["password"] = str(e.get("password", ""))
        em["recipient"] = str(e.get("recipient", "")).strip()
    cfg = dict(db.get_config() or {})
    cfg.update(ai_base_url=ai["base_url"], ai_model=ai["model"], ai_key=ai["api_key"])
    db.put_config(cfg)
    dr = d.get("director") or {}
    db.set_purchase_defaults(str(dr.get("title", "")), str(dr.get("name", "")))
    tg = d.get("tg") or {}
    allowed = tg.get("allowed", [])
    if isinstance(allowed, str):
        allowed = allowed.replace(",", " ").split()
    db.set_tg_config(token=str(tg.get("token", "")).strip(), allowed=list(allowed),
                     enabled=bool(tg.get("enabled")))
    db.set_ui_prefs(export_dir=str(d.get("export_dir", "")).strip(), setup_done=True)


def assets_ai_config():
    """Настройки ИИ учёта; не заданы — понятный отказ."""
    import assets
    cfg = assets.load_config()
    if not cfg.get("ai_base_url") or not cfg.get("ai_model"):
        raise ValueError("Укажите адрес, модель и ключ в настройках (раздел «ИИ»).")
    return cfg


def backups():
    """[(путь, когда, размер)] — новые первыми."""
    return [(p, datetime.datetime.fromtimestamp(t).strftime("%d.%m.%Y %H:%M"), s)
            for p, t, s in db.list_backups()]


def backup_now():
    db.make_backup(throttle_sec=0)


def restore(path):
    if not db.restore_backup(path):
        raise ValueError("Не удалось восстановить копию.")
