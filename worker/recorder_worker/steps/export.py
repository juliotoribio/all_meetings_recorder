"""Paso 6: copiar el resultado a la bandeja de resúmenes y avisar."""

from __future__ import annotations

import re
import shutil
import time

from ..config import Config
from ..session import Session
from ..util import atomic_write_json, notify


def _slug(text: str) -> str:
    text = re.sub(r"[/\\:*?\"<>|]+", "-", text).strip()
    return re.sub(r"\s+", " ", text)[:80] or "sesion"


class Export:
    name = "export"

    def is_done(self, s: Session, cfg: Config) -> bool:
        return s.export_marker.is_file()

    def run(self, s: Session, cfg: Config) -> None:
        cfg.paths.inbox.mkdir(parents=True, exist_ok=True)
        m = s.manifest()
        title = m.get("title") if m.get("title_user_set") else (m.get("suggested_title") or s.title)
        date = s.id[:15].replace("_", " ") if re.match(r"\d{4}-\d{2}-\d{2}_\d{4}", s.id) else time.strftime("%Y-%m-%d")
        src = s.summary_md if s.summary_md.is_file() else s.transcript_md
        kind = "" if src == s.summary_md else " (transcripción)"
        dest = cfg.paths.inbox / f"{date} - {_slug(title)}{kind}.md"
        shutil.copyfile(src, dest)
        atomic_write_json(s.export_marker, {"exported_to": str(dest), "at": time.time()})
        if cfg.worker.notify:
            what = "Resumen listo" if src == s.summary_md else "Transcripción lista"
            notify("Recorder JT", f"{what}: {title}")
