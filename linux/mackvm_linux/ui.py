"""Lightweight GTK3 status/pairing window and AppIndicator3 tray menu for Ubuntu."""

from __future__ import annotations

from typing import Any, Callable

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

try:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3
except Exception:
    AppIndicator3 = None  # type: ignore[assignment]

from .screens import ScreenInfo
from .state import log

_CSS = b"""
window.mackvm-win {
    background-color: #F7F8FA;
}
.title-lbl {
    font-size: 20px;
    font-weight: 700;
    color: #202632;
}
.sub-lbl {
    font-size: 12px;
    color: #6B7482;
}
.card {
    background-color: #FFFFFF;
    border: 1px solid #E3E7EE;
    border-radius: 12px;
    padding: 18px;
}
.code-cell {
    background-color: #F0F4FC;
    border-radius: 8px;
    font-size: 24px;
    font-weight: 600;
    color: #202632;
    padding: 10px 0px;
}
.dash-lbl {
    font-size: 20px;
    color: #6B7482;
}
.pill-connected {
    background-color: #E4F4EC;
    color: #237A4D;
    border-radius: 999px;
    padding: 4px 12px;
    font-size: 12px;
    font-weight: 600;
}
.pill-searching {
    background-color: #FBF1DF;
    color: #9B6917;
    border-radius: 999px;
    padding: 4px 12px;
    font-size: 12px;
    font-weight: 600;
}
.pill-offline {
    background-color: #EDEFF2;
    color: #6B7482;
    border-radius: 999px;
    padding: 4px 12px;
    font-size: 12px;
    font-weight: 600;
}
.btn-primary {
    background: #2869E8;
    color: #FFFFFF;
    border-radius: 8px;
    padding: 7px 14px;
    border: none;
    font-weight: 600;
}
.btn-secondary {
    background: #FFFFFF;
    color: #202632;
    border: 1px solid #E3E7EE;
    border-radius: 8px;
    padding: 7px 14px;
}
.btn-danger {
    background: #C13E3E;
    color: #FFFFFF;
    border-radius: 8px;
    padding: 7px 14px;
    border: none;
    font-weight: 600;
}
"""


class LinuxUI:
    def __init__(
        self,
        device_name: str,
        on_regen_code: Callable[[], None],
        on_reset_input: Callable[[], None],
        on_toggle_swap: Callable[[bool], None],
        on_unpair: Callable[[], None],
        on_quit: Callable[[], None],
    ) -> None:
        self.device_name = device_name
        self.on_regen_code = on_regen_code
        self.on_reset_input = on_reset_input
        self.on_toggle_swap = on_toggle_swap
        self.on_unpair = on_unpair
        self.on_quit = on_quit

        provider = Gtk.CssProvider()
        provider.load_from_data(_CSS)
        screen = Gdk.Screen.get_default()
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.window = Gtk.Window(title="MacKVM")
        self.window.get_style_context().add_class("mackvm-win")
        self.window.set_default_size(520, 340)
        self.window.set_resizable(False)
        self.window.set_position(Gtk.WindowPosition.CENTER)
        self.window.connect("delete-event", self._on_delete)

        root_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root_box.set_margin_top(18)
        root_box.set_margin_bottom(18)
        root_box.set_margin_start(20)
        root_box.set_margin_end(20)
        self.window.add(root_box)

        # Header
        hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        title = Gtk.Label(label="MacKVM")
        title.get_style_context().add_class("title-lbl")
        sub = Gtk.Label(label=f"{device_name} · Ubuntu 被控端")
        sub.get_style_context().add_class("sub-lbl")
        hdr.pack_start(title, False, False, 0)
        hdr.pack_end(sub, False, False, 0)
        root_box.pack_start(hdr, False, False, 0)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        root_box.pack_start(self.stack, True, True, 0)

        # --- Unpaired page ---
        unpaired_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        unpaired_card.get_style_context().add_class("card")
        u_title = Gtk.Label(label="等待 Mac 主控端配对")
        u_title.set_xalign(0.0)
        u_title.set_markup("<b>等待 Mac 主控端连接</b>")
        u_hint = Gtk.Label(label="在 Mac 主控端点击「添加设备」选择本机，并输入下方 8 位配对码：")
        u_hint.set_xalign(0.0)
        u_hint.set_line_wrap(True)
        u_hint.get_style_context().add_class("sub-lbl")

        code_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self._code_cells: list[Gtk.Label] = []
        for idx in range(8):
            if idx == 4:
                dash = Gtk.Label(label="–")
                dash.get_style_context().add_class("dash-lbl")
                code_row.pack_start(dash, False, False, 2)
            cell = Gtk.Label(label="0")
            cell.get_style_context().add_class("code-cell")
            cell.set_size_request(46, 52)
            self._code_cells.append(cell)
            code_row.pack_start(cell, True, True, 0)

        self._invite_status = Gtk.Label(label="正在局域网广播 · 等待配对…")
        self._invite_status.set_xalign(0.0)
        self._invite_status.get_style_context().add_class("sub-lbl")

        u_btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        regen_btn = Gtk.Button(label="重新生成配对码")
        regen_btn.get_style_context().add_class("btn-secondary")
        regen_btn.connect("clicked", lambda _b: self.on_regen_code())
        u_btn_row.pack_start(regen_btn, False, False, 0)

        unpaired_card.pack_start(u_title, False, False, 0)
        unpaired_card.pack_start(u_hint, False, False, 0)
        unpaired_card.pack_start(code_row, False, False, 4)
        unpaired_card.pack_start(self._invite_status, False, False, 0)
        unpaired_card.pack_end(u_btn_row, False, False, 0)
        self.stack.add_named(unpaired_card, "unpaired")

        # --- Paired page ---
        paired_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        paired_card.get_style_context().add_class("card")

        top_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self._status_pill = Gtk.Label(label="● 正在寻找主控")
        self._status_pill.get_style_context().add_class("pill-searching")
        self._peer_lbl = Gtk.Label(label="")
        self._peer_lbl.set_xalign(0.0)
        top_row.pack_start(self._status_pill, False, False, 0)
        top_row.pack_start(self._peer_lbl, True, True, 4)

        self._screens_lbl = Gtk.Label(label="")
        self._screens_lbl.set_xalign(0.0)
        self._screens_lbl.set_line_wrap(True)
        self._screens_lbl.get_style_context().add_class("sub-lbl")

        self._swap_check = Gtk.CheckButton(label="交换 Command ↔ Control（使用 Mac 快捷键习惯，如 Cmd+C/V）")
        self._swap_check.set_active(True)
        self._swap_check_handler = self._swap_check.connect("toggled", self._on_swap_toggled)

        note_lbl = Gtk.Label(label="屏幕摆放与波纹特效请在 Mac 主控端调整 · 卡住时可按 Ctrl+Alt+Super+L 交还控制")
        note_lbl.set_xalign(0.0)
        note_lbl.set_line_wrap(True)
        note_lbl.get_style_context().add_class("sub-lbl")

        p_btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self._reset_btn = Gtk.Button(label="重置键鼠状态")
        self._reset_btn.get_style_context().add_class("btn-primary")
        self._reset_btn.connect("clicked", lambda _b: self.on_reset_input())

        unpair_btn = Gtk.Button(label="解除配对")
        unpair_btn.get_style_context().add_class("btn-secondary")
        unpair_btn.connect("clicked", self._confirm_unpair)

        quit_btn = Gtk.Button(label="退出服务")
        quit_btn.get_style_context().add_class("btn-secondary")
        quit_btn.connect("clicked", lambda _b: self.on_quit())

        p_btn_row.pack_start(self._reset_btn, False, False, 0)
        p_btn_row.pack_start(unpair_btn, False, False, 0)
        p_btn_row.pack_end(quit_btn, False, False, 0)

        paired_card.pack_start(top_row, False, False, 0)
        paired_card.pack_start(self._screens_lbl, False, False, 0)
        paired_card.pack_start(self._swap_check, False, False, 4)
        paired_card.pack_start(note_lbl, False, False, 0)
        paired_card.pack_end(p_btn_row, False, False, 0)
        self.stack.add_named(paired_card, "paired")

        # Tray indicator
        self._indicator: Any = None
        self._tray_status_item: Gtk.MenuItem | None = None
        self._tray_reset_item: Gtk.MenuItem | None = None
        self._tray_unpair_item: Gtk.MenuItem | None = None
        self._init_indicator()

    def _init_indicator(self) -> None:
        if AppIndicator3 is None:
            log("提示：未检测到 AppIndicator3，仅提供主窗口与命令行控制")
            return
        try:
            ind = AppIndicator3.Indicator.new(
                "mackvm-linux",
                "input-keyboard",
                AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
            )
            ind.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
            ind.set_title("MacKVM")

            menu = Gtk.Menu()
            self._tray_status_item = Gtk.MenuItem(label="MacKVM · 未配对")
            self._tray_status_item.set_sensitive(False)
            menu.append(self._tray_status_item)
            menu.append(Gtk.SeparatorMenuItem())

            open_item = Gtk.MenuItem(label="打开 MacKVM 窗口")
            open_item.connect("activate", lambda _i: self.show_window())
            menu.append(open_item)

            self._tray_reset_item = Gtk.MenuItem(label="重置键鼠状态")
            self._tray_reset_item.connect("activate", lambda _i: self.on_reset_input())
            menu.append(self._tray_reset_item)

            self._tray_unpair_item = Gtk.MenuItem(label="解除配对")
            self._tray_unpair_item.connect("activate", self._confirm_unpair)
            menu.append(self._tray_unpair_item)

            menu.append(Gtk.SeparatorMenuItem())
            quit_item = Gtk.MenuItem(label="退出 MacKVM")
            quit_item.connect("activate", lambda _i: self.on_quit())
            menu.append(quit_item)

            menu.show_all()
            ind.set_menu(menu)
            self._indicator = ind
        except Exception as exc:
            log(f"提示：创建顶栏托盘图标失败（{exc}）")

    def _on_delete(self, _w: Gtk.Widget, _ev: Gdk.Event) -> bool:
        self.window.hide()
        return True

    def _on_swap_toggled(self, btn: Gtk.CheckButton) -> None:
        self.on_toggle_swap(bool(btn.get_active()))

    def _confirm_unpair(self, _w: Any) -> None:
        self.show_window()
        dlg = Gtk.MessageDialog(
            transient_for=self.window,
            flags=Gtk.DialogFlags.MODAL,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.NONE,
            text="确定解除与主控设备的配对吗？",
        )
        dlg.format_secondary_text("解除后本机将回到未配对状态并显示新的配对码，需要重新在 Mac 主控端添加。")
        dlg.add_button("取消", Gtk.ResponseType.CANCEL)
        danger = dlg.add_button("解除配对", Gtk.ResponseType.OK)
        danger.get_style_context().add_class("btn-danger")
        resp = dlg.run()
        dlg.destroy()
        if resp == Gtk.ResponseType.OK:
            self.on_unpair()

    def show_window(self) -> None:
        GLib.idle_add(self._show_now)

    def _show_now(self) -> bool:
        self.window.show_all()
        self.window.present()
        return False

    def hide_window(self) -> None:
        GLib.idle_add(lambda: (self.window.hide(), False)[1])

    def update_unpaired(self, code: str, renewed: bool = False) -> None:
        def apply() -> bool:
            digits = (code + "00000000")[:8]
            for cell, ch in zip(self._code_cells, digits):
                cell.set_text(ch)
            if renewed:
                self._invite_status.set_text("对方输错次数过多，密钥已自动更新 · 请使用上方新配对码")
            else:
                self._invite_status.set_text("正在局域网广播 · 等待 Mac 主控连接…")
            self.stack.set_visible_child_name("unpaired")
            if self._tray_status_item is not None:
                self._tray_status_item.set_label(f"● 未配对 · 配对码 {digits[:4]}-{digits[4:]}")
            if self._tray_reset_item is not None:
                self._tray_reset_item.hide()
            if self._tray_unpair_item is not None:
                self._tray_unpair_item.hide()
            return False

        GLib.idle_add(apply)

    def update_paired(
        self,
        peer_name: str,
        status: str,
        screens: list[ScreenInfo],
        swap_cmd_ctrl: bool,
    ) -> None:
        def apply() -> bool:
            ctx = self._status_pill.get_style_context()
            for cls in ("pill-connected", "pill-searching", "pill-offline"):
                ctx.remove_class(cls)
            if status == "connected":
                ctx.add_class("pill-connected")
                self._status_pill.set_text("● 已连接")
                tray_text = f"● 已连接 · {peer_name}"
            elif status == "searching":
                ctx.add_class("pill-searching")
                self._status_pill.set_text("● 正在寻找主控")
                tray_text = f"● 正在寻找 · {peer_name}"
            else:
                ctx.add_class("pill-offline")
                self._status_pill.set_text("● 主控离线")
                tray_text = f"● 离线 · {peer_name}"

            self._peer_lbl.set_markup(f"主控设备：<b>{GLib.markup_escape_text(peer_name)}</b>")
            if screens:
                lines = [
                    f"{s.name} · {int(s.w)}×{int(s.h)} · {int(round(s.mm_w))}×{int(round(s.mm_h))} mm"
                    + (" · 主屏" if s.is_main else "")
                    for s in screens
                ]
                self._screens_lbl.set_text("本机显示器：" + "；".join(lines))
            else:
                self._screens_lbl.set_text("本机显示器：正在检测…")

            self._swap_check.handler_block(self._swap_check_handler)
            self._swap_check.set_active(swap_cmd_ctrl)
            self._swap_check.handler_unblock(self._swap_check_handler)

            self._reset_btn.set_sensitive(status == "connected")
            self.stack.set_visible_child_name("paired")
            if self._tray_status_item is not None:
                self._tray_status_item.set_label(tray_text)
            if self._tray_reset_item is not None:
                self._tray_reset_item.show()
                self._tray_reset_item.set_sensitive(status == "connected")
            if self._tray_unpair_item is not None:
                self._tray_unpair_item.show()
            return False

        GLib.idle_add(apply)
