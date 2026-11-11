# -*- coding: utf-8 -*-
"""ITtool в терминале: учёт техники, недельный отчёт, заявки, картриджи.

Запуск: ./ittool (или python3 ittool.py). Данные — ~/.local/share/ITtool/itmanager.db,
выгрузки — в папку из настроек (по умолчанию ~/ITtool-выгрузки).
"""
from __future__ import annotations

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, Header, TabbedContent, TabPane

import db
from tui_assets import AssetsTab
from tui_office import CartridgesTab, PurchasesTab, SettingsTab
from tui_reports import ReportsTab

APP_VERSION = "3.1.0"

TABS = [("assets", "F1 Учёт", AssetsTab), ("reports", "F2 Отчёт", ReportsTab),
        ("purchase", "F3 Заявки", PurchasesTab), ("cart", "F4 Картриджи", CartridgesTab),
        ("settings", "F5 Настройки", SettingsTab)]


class ITtool(App):
    TITLE = "ITtool"
    SUB_TITLE = APP_VERSION
    CSS = """
    TabPane { padding: 0 1; }
    """
    BINDINGS = [
        *[Binding(f"f{i}", f"tab('{tid}')", label, show=False)
          for i, (tid, label, _cls) in enumerate(TABS, 1)],
        Binding("ctrl+r", "reload_all", "Обновить", show=False),
        Binding("ctrl+q", "quit", "Выход", priority=True),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(initial="assets"):
            for tid, label, cls in TABS:
                with TabPane(label, id=tid):
                    yield cls(id="tab_" + tid)
        yield Footer()

    def on_mount(self):
        self.theme = "tokyo-night"
        self.focus_tab("assets")
        if not db.get_ui_prefs().get("setup_done") and not db.get_org_profile().get("fio"):
            self.action_tab("settings")
            self.notify("Заполните данные организации и сохраните (Ctrl+S).", timeout=10)

    def focus_tab(self, tid):
        """Фокус на главный список вкладки, чтобы горячие клавиши сразу работали."""
        from textual.widgets import DataTable, Input, Tree
        tab = self.query_one("#tab_" + tid)
        for kind in (Tree, DataTable, Input):
            found = tab.query(kind)
            if found:
                found.first().focus()
                return

    def action_tab(self, tid):
        self.set_focus(None)          # фокус в старой вкладке вернул бы её обратно
        self.query_one(TabbedContent).active = tid
        self.call_after_refresh(self.focus_tab, tid)

    def on_tabbed_content_tab_activated(self, ev):
        tid = ev.pane.id
        tab = self.query_one("#tab_" + tid)
        if hasattr(tab, "reload"):             # данные могли поменяться (бот, другая вкладка)
            tab.reload()
        self.call_after_refresh(self.focus_tab, tid)

    def action_reload_all(self):
        for tid, _l, _c in TABS:
            tab = self.query_one("#tab_" + tid)
            if hasattr(tab, "reload"):
                tab.reload()
        self.notify("Данные перечитаны")

    def reload_all(self):
        self.action_reload_all()


def main():
    ITtool().run()


if __name__ == "__main__":
    main()
