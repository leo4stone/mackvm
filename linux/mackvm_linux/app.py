"""Main Ubuntu controlled runtime coordinating asyncio Link/Pairing, X11 input, ripples, and GTK UI."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import signal
import struct
import threading
import time
from typing import Any

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from . import LINK_PORT, VERSION
from .keymap import SHIFT_MAC_KEYCODES, mac_button_to_x11, mac_keycode_to_x11
from .protocol import LinkClient, Msg, PairInviter, PeerSession
from .ripple import RipplePlayer
from .screens import (
    CrossingHit,
    CrossingMap,
    LeaveDebounce,
    ScreenInfo,
    beyond_edge,
    detect_screens,
    outward_component,
    rule_views_from_shared,
)
from .state import Store, config_dir, current_computer_name, log, sanitize_ripple, set_log_role
from .ui import LinuxUI
from .x11_input import HotkeyWatcher, X11Controller


class UbuntuApp:
    def __init__(self, force_show: bool = False) -> None:
        self.store = Store()
        self.state = self.store.load()
        self.me_id = self.state.device_id
        self.me_name = current_computer_name()
        self.force_show = force_show

        self.x11 = X11Controller()
        self.ripple = RipplePlayer(sample_cursor=self.x11.query_pointer)
        if self.state.shared:
            self.ripple.update_config(self.state.shared.get("ripple"))

        self.local_screens: list[ScreenInfo] = []
        self.other_screens: dict[str, list[ScreenInfo]] = {}
        self.active = False
        self.pos_x = 0.0
        self.pos_y = 0.0
        self.entered_at = 0.0
        self.debounce = LeaveDebounce()
        self.held_buttons: set[int] = set()
        self.held_key_map: dict[int, int] = {}
        self.held_shift_mac: set[int] = set()
        self.transition_seq = 0
        self.cursor_hide_seq = 0
        self.link_status = "searching"
        self.link_changed_at = time.monotonic()

        self._inviter: PairInviter | None = None
        self._link: LinkClient | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._net_thread: threading.Thread | None = None
        self._stopping = False

        self.ui = LinuxUI(
            device_name=self.me_name,
            on_regen_code=self._ui_regen_code,
            on_reset_input=lambda: self._schedule_net(self._reset_input("界面点击重置键鼠状态")),
            on_toggle_swap=self._ui_toggle_swap,
            on_unpair=lambda: self._schedule_net(self._unpair_local()),
            on_quit=self._quit_from_ui,
        )
        self.hotkey = HotkeyWatcher(on_trigger=lambda: self._schedule_net(self._reset_input("本机按了重置热键 Ctrl+Alt+Super+L")))

    def run(self) -> None:
        set_log_role("被控" if self.is_paired else "未配对")
        log(f"MacKVM {VERSION} (Ubuntu X11) 启动：pid {os.getpid()}，本机「{self.me_name}」，ID {self.me_id}")
        self._write_pid()
        self._refresh_screens(initial=True)

        self._loop = asyncio.new_event_loop()
        self._net_thread = threading.Thread(target=self._run_net_loop, name="MacKVMNet", daemon=True)
        self._net_thread.start()

        self.hotkey.start()
        GLib.timeout_add_seconds(1, self._tick_status)
        GLib.timeout_add_seconds(5, self._tick_screens)

        if self.force_show or not self.is_paired:
            self.ui.show_window()

        def handle_sigusr1(_signum: int, _frame: Any) -> None:
            self.ui.show_window()

        def handle_sigterm(_signum: int, _frame: Any) -> None:
            GLib.idle_add(self._shutdown_and_quit)

        signal.signal(signal.SIGUSR1, handle_sigusr1)
        signal.signal(signal.SIGTERM, handle_sigterm)
        signal.signal(signal.SIGINT, handle_sigterm)

        Gtk.main()

    @property
    def is_paired(self) -> bool:
        return self.state.pairing is not None and self.state.shared is not None

    def _write_pid(self) -> None:
        try:
            d = config_dir()
            d.mkdir(parents=True, exist_ok=True)
            (d / "instance.pid").write_text(str(os.getpid()), encoding="utf-8")
        except Exception:
            pass

    def _remove_pid(self) -> None:
        try:
            p = config_dir() / "instance.pid"
            if p.exists() and p.read_text(encoding="utf-8").strip() == str(os.getpid()):
                p.unlink()
        except Exception:
            pass

    def _run_net_loop(self) -> None:
        assert self._loop is not None
        asyncio.set_event_loop(self._loop)
        self._loop.create_task(self._net_start())
        try:
            self._loop.run_forever()
        finally:
            self._loop.close()

    def _schedule_net(self, coro: Any) -> None:
        if self._loop is not None and not self._stopping:
            asyncio.run_coroutine_threadsafe(coro, self._loop)

    async def _net_start(self) -> None:
        if self.is_paired:
            await self._start_paired()
        else:
            await self._start_invite()

    # MARK: - Pairing & Link Lifecycle

    async def _start_invite(self) -> None:
        set_log_role("未配对")
        if self._link is not None:
            await self._link.stop()
            self._link = None
        if self._inviter is not None:
            await self._inviter.stop()
        self._inviter = PairInviter(
            my_id=self.me_id,
            my_name=self.me_name,
            on_code_changed=self._on_pair_code_changed,
            on_paired=lambda rec: self._schedule_net(self._pairing_completed(rec)),
        )
        await self._inviter.start()

    def _on_pair_code_changed(self, code: str, renewed: bool) -> None:
        self._write_pair_code(code)
        self.ui.update_unpaired(code, renewed)

    def _write_pair_code(self, code: str | None) -> None:
        p = config_dir() / "pair.code"
        if not code:
            try:
                p.unlink(missing_ok=True)
            except Exception:
                pass
            return
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                os.write(fd, f"{code[:4]}-{code[4:]}\n".encode("utf-8"))
            finally:
                os.close(fd)
        except Exception:
            pass

    async def _pairing_completed(self, rec: dict[str, Any]) -> None:
        self._write_pair_code(None)
        if self._inviter is not None:
            inv = self._inviter
            self._inviter = None
            await asyncio.sleep(0.2)
            await inv.stop()
        self.state.pairing = rec
        self.state.shared = {
            "revision": 0,
            "editor": rec["peerID"],
            "controllerID": rec["peerID"],
            "layout": [],
            "rules": [],
            "rulesInitialized": False,
            "ripple": self.ripple.config,
            "devices": [],
        }
        self.store.save(self.state)
        log(f"配对成功：主控设备「{rec['peerName']}」（{rec['peerID']}）")
        await self._start_paired()

    async def _start_paired(self) -> None:
        rec = self.state.pairing
        assert rec is not None
        set_log_role("被控")
        key = base64.b64decode(rec["keyBase64"])
        self.link_changed_at = time.monotonic()
        self.link_status = "searching"
        self.ui.update_paired(rec["peerName"], self.link_status, self.local_screens, self.state.swap_cmd_ctrl)

        if self._link is not None:
            await self._link.stop()
        self._link = LinkClient(
            my_id=self.me_id,
            my_name=self.me_name,
            peer_id=rec["peerID"],
            peer_name=rec["peerName"],
            key=key,
            last_address=rec.get("lastAddress"),
            on_authenticated=lambda s: self._on_link_up(s),
            on_message=lambda t, d: self._on_message(t, d),
            on_disconnected=lambda: self._on_link_down(),
            on_address_learned=lambda ip: self._on_address_learned(ip),
            port=LINK_PORT,
        )
        await self._link.start()

    def _on_address_learned(self, ip: str) -> None:
        if self.state.pairing is None:
            return
        self.state.pairing["lastAddress"] = ip
        self.store.save(self.state)
        log(f"记住主控地址 {ip}")

    def _on_link_up(self, sess: PeerSession) -> None:
        self.link_changed_at = time.monotonic()
        self.link_status = "connected"
        self._send_info(sess)
        self._send_settings(sess)
        self._send_screens(sess)
        if self.active:
            self._deactivate("主控重新连上（安全兜底）", hide_cursor=False)
        n = len(self._crossing_map().active_views)
        log(f"主控在线：{n} 条相邻规则生效")
        if self.state.pairing is not None:
            self.ui.update_paired(self.state.pairing["peerName"], "connected", self.local_screens, self.state.swap_cmd_ctrl)

    def _on_link_down(self) -> None:
        self.link_changed_at = time.monotonic()
        if self.active:
            self._deactivate("连接断开", hide_cursor=False)
        self._restore_cursor_now("连接断开")
        self._refresh_status_now()

    def _send_info(self, sess: PeerSession) -> None:
        obj = {"id": self.me_id, "name": self.me_name, "laptop": False, "version": VERSION, "platform": "linux"}
        sess.send(Msg.INFO, json.dumps(obj, separators=(",", ":")).encode("utf-8"))

    def _send_settings(self, sess: PeerSession | None = None) -> None:
        target = sess or (self._link.active if self._link else None)
        if target is None or self.state.shared is None:
            return
        target.send(Msg.SETTINGS, json.dumps(self.state.shared, separators=(",", ":")).encode("utf-8"))

    def _send_screens(self, sess: PeerSession | None = None) -> None:
        target = sess or (self._link.active if self._link else None)
        if target is None or not self.local_screens:
            return
        payload = [s.to_dict() for s in self.local_screens]
        target.send(Msg.SCREENS, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def _on_message(self, msg_type: int, data: bytes) -> None:
        if msg_type == Msg.SETTINGS:
            self._receive_settings(data)
        elif msg_type == Msg.SCREENS:
            self._receive_peer_screens(data)
        elif msg_type == Msg.ALL_SCREENS:
            self._receive_all_screens(data)
        elif msg_type == Msg.INFO:
            self._receive_info(data)
        elif msg_type == Msg.UNPAIR:
            log("主控端解除了配对，本机也清除配对")
            self._schedule_net(self._clear_pairing())
        elif msg_type == Msg.ENTER:
            try:
                payload = json.loads(data.decode("utf-8")) if data else None
            except Exception:
                payload = None
            self._enter(payload)
        elif msg_type == Msg.MOVE:
            if self.active and len(data) >= 8:
                dx, dy = struct.unpack(">ii", data[:8])
                self._move(float(dx), float(dy))
        elif msg_type == Msg.BUTTON:
            if self.active and len(data) >= 2:
                self._button(data[0], data[1] != 0)
        elif msg_type == Msg.KEY:
            if self.active and len(data) >= 11:
                kc, action, flags = struct.unpack(">HBQ", data[:11])
                self._key(kc, action, flags)
        elif msg_type == Msg.SCROLL:
            if self.active and len(data) >= 16:
                dx_line, dy_line, dx_pt, dy_pt = struct.unpack(">iiii", data[:16])
                self._scroll(dx_line, dy_line, dx_pt, dy_pt)
        elif msg_type == Msg.RELEASE:
            if self.active:
                self._deactivate("主控用热键 Ctrl+Option+Cmd+L 收回", hide_cursor=True)

    def _receive_info(self, data: bytes) -> None:
        try:
            info = json.loads(data.decode("utf-8"))
        except Exception:
            return
        rec = self.state.pairing
        if not rec or not isinstance(info, dict):
            return
        name = str(info.get("name") or rec["peerName"])
        if name != rec["peerName"]:
            log(f"主控设备名更新：「{rec['peerName']}」→「{name}」")
            rec["peerName"] = name
            self.store.save(self.state)
            self.ui.update_paired(name, self.link_status, self.local_screens, self.state.swap_cmd_ctrl)

    def _receive_peer_screens(self, data: bytes) -> None:
        if self.state.pairing is None:
            return
        try:
            raw = json.loads(data.decode("utf-8"))
            if not isinstance(raw, list):
                return
            peer_id = self.state.pairing["peerID"]
            self.other_screens[peer_id] = [ScreenInfo.from_dict(x) for x in raw]
            self.state.peer_screens[peer_id] = raw
            self.store.save(self.state)
        except Exception as exc:
            log(f"警告：解析主控屏幕清单失败：{exc}")

    def _receive_all_screens(self, data: bytes) -> None:
        try:
            raw = json.loads(data.decode("utf-8"))
            if not isinstance(raw, dict):
                return
            parsed: dict[str, list[ScreenInfo]] = {}
            for dev_id, slist in raw.items():
                if dev_id == self.me_id or not isinstance(slist, list):
                    continue
                parsed[dev_id] = [ScreenInfo.from_dict(x) for x in slist]
            self.other_screens = parsed
        except Exception as exc:
            log(f"警告：解析全局屏幕清单失败：{exc}")

    def _receive_settings(self, data: bytes) -> None:
        cur = self.state.shared
        rec = self.state.pairing
        if cur is None or rec is None:
            return
        try:
            s = json.loads(data.decode("utf-8"))
            if not isinstance(s, dict):
                return
        except Exception:
            return
        allowed = {self.me_id, rec["peerID"]}
        for d in s.get("devices", []):
            if isinstance(d, dict) and isinstance(d.get("id"), str):
                allowed.add(d["id"])
        if s.get("controllerID") != rec["peerID"] or s.get("editor") not in allowed:
            return
        s["ripple"] = sanitize_ripple(s.get("ripple"))
        s_rev = int(s.get("revision", 0))
        c_rev = int(cur.get("revision", 0))
        s_ed = str(s.get("editor", ""))
        c_ed = str(cur.get("editor", ""))
        if (s_rev > c_rev) or (s_rev == c_rev and s_ed > c_ed):
            log(f"采用主控的共享设置（修订号 {c_rev} → {s_rev}）")
            self.state.shared = s
            self.ripple.update_config(s.get("ripple"))
            self.store.save(self.state)
        elif (c_rev > s_rev) or (c_rev == s_rev and c_ed > s_ed):
            self._send_settings()

    # MARK: - Controlled Input & Crossing

    def _crossing_map(self) -> CrossingMap:
        views = rule_views_from_shared(self.state.shared, self.me_id)
        remote = dict(self.other_screens)
        if not remote and self.state.pairing is not None:
            pid = self.state.pairing["peerID"]
            if pid in self.state.peer_screens:
                try:
                    remote[pid] = [ScreenInfo.from_dict(x) for x in self.state.peer_screens[pid]]
                except Exception:
                    pass
        return CrossingMap(views=views, local_screens=self.local_screens, remote_by_device=remote)

    def _enter(self, payload: dict[str, Any] | None) -> None:
        m = self._crossing_map()
        s = m.local.get(payload.get("screen")) if isinstance(payload, dict) else None
        if s is not None and isinstance(payload, dict):
            px, py = CrossingMap.landing(s, str(payload["edge"]), float(payload["mm"]))
        elif self.local_screens:
            main = next((scr for scr in self.local_screens if scr.is_main), self.local_screens[0])
            px, py = main.x + main.w / 2.0, main.y + main.h / 2.0
        else:
            px, py = 500.0, 500.0

        self._restore_cursor_now("主控重新进入")
        self.entered_at = time.monotonic()
        self.debounce.reset()
        self.pos_x, self.pos_y = px, py
        self.active = True
        self.held_buttons.clear()
        self.held_key_map.clear()
        self.held_shift_mac.clear()
        self.x11.reset_scroll_accumulator()
        self.x11.warp(self.pos_x, self.pos_y)

        self.transition_seq += 1
        seq = self.transition_seq
        self.ripple.play(
            "arrive",
            self.pos_x,
            self.pos_y,
            present=lambda: self.active and self.transition_seq == seq,
        )
        if s is not None and isinstance(payload, dict):
            log(f"进入活动状态：落在「{s.name}」{payload['edge']}边 {float(payload['mm']):.1f} 毫米处 ({int(px)}, {int(py)})")
        else:
            log(f"进入活动状态：光标放到 ({int(px)}, {int(py)})")

    def _move(self, dx: float, dy: float) -> None:
        if not self.local_screens:
            return
        m = self._crossing_map()
        p1x, p1y = self.pos_x + dx, self.pos_y + dy
        hit = m.hit(self.pos_x, self.pos_y, p1x, p1y)
        into_own = False
        if hit is not None:
            local_scr = m.local.get(hit.local_screen)
            into_own = any(s.contains(p1x, p1y) for s in self.local_screens) and not (
                local_scr is not None and local_scr.contains(p1x, p1y)
            )
        outward = outward_component(dx, dy, self.debounce.pending_edge) if self.debounce.pending_edge else None
        beyond = beyond_edge(p1x, p1y, hit) if hit is not None else 0.0
        if self.debounce.feed(hit, beyond, into_own, time.monotonic() - self.entered_at, outward) and hit is not None:
            self._send_leave(hit)
            self._deactivate(f"光标从规则 {hit.rule_id[:8]} 的 {hit.local_edge} 边推出", hide_cursor=True)
            return

        nx, ny = p1x, p1y
        if not any(s.contains(nx, ny) for s in self.local_screens):
            cur = next((s for s in self.local_screens if s.contains(self.pos_x, self.pos_y)), self.local_screens[0])
            nx = min(max(nx, cur.x), cur.x + cur.w - 1.0)
            ny = min(max(ny, cur.y), cur.y + cur.h - 1.0)
        self.pos_x, self.pos_y = nx, ny
        self.x11.warp(nx, ny)

    def _button(self, mac_btn: int, down: bool) -> None:
        xbtn = mac_button_to_x11(mac_btn)
        if xbtn is None:
            return
        if down:
            self.held_buttons.add(xbtn)
        else:
            self.held_buttons.discard(xbtn)
        self.x11.button(xbtn, down)

    def _key(self, mac_keycode: int, action: int, _flags: int) -> None:
        if action == 2:
            return  # Xorg handles key repeat natively while key is held
        if mac_keycode in SHIFT_MAC_KEYCODES:
            if action == 1:
                self.held_shift_mac.add(mac_keycode)
            elif action == 0:
                self.held_shift_mac.discard(mac_keycode)
        xkc = mac_keycode_to_x11(mac_keycode, swap_cmd_ctrl=self.state.swap_cmd_ctrl)
        if xkc is None:
            return
        if action == 1:
            if mac_keycode not in self.held_key_map:
                self.held_key_map[mac_keycode] = xkc
                self.x11.key(xkc, True)
        elif action == 0:
            rel_kc = self.held_key_map.pop(mac_keycode, xkc)
            self.x11.key(rel_kc, False)

    def _scroll(self, dx_line: int, dy_line: int, dx_pt: int, dy_pt: int) -> None:
        self.x11.scroll(dx_line, dy_line, dx_pt, dy_pt, shift_held=bool(self.held_shift_mac))

    def _release_all(self) -> None:
        nb, nk = len(self.held_buttons), len(self.held_key_map)
        for b in sorted(self.held_buttons):
            self.x11.button(b, False)
        self.held_buttons.clear()
        for kc in list(self.held_key_map.values()):
            self.x11.key(kc, False)
        self.held_key_map.clear()
        self.held_shift_mac.clear()
        if nb + nk > 0:
            log(f"补发抬起：{nb} 个鼠标键、{nk} 个键盘键")

    def _send_leave(self, hit: CrossingHit | None) -> None:
        sess = self._link.active if self._link else None
        if sess is None:
            return
        if hit is None:
            sess.send(Msg.LEAVE, b"")
            return
        payload = {
            "device": hit.remote_device,
            "screen": hit.remote_screen,
            "edge": hit.remote_edge,
            "mm": hit.remote_mm,
        }
        sess.send(Msg.LEAVE, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def _deactivate(self, reason: str, hide_cursor: bool) -> None:
        self.transition_seq += 1
        seq = self.transition_seq
        self._release_all()
        self.active = False
        log(f"退出活动状态（{reason}）")
        if hide_cursor:
            self.x11.hide_cursor()
            self.cursor_hide_seq += 1
            hseq = self.cursor_hide_seq
            hide_pt = self.x11.query_pointer()

            def watch_local_input() -> bool:
                if self._stopping or not self.x11.cursor_hidden or self.cursor_hide_seq != hseq:
                    return False
                now_pt = self.x11.query_pointer()
                if hide_pt is not None and now_pt is not None:
                    if abs(now_pt[0] - hide_pt[0]) > 2 or abs(now_pt[1] - hide_pt[1]) > 2:
                        self._restore_cursor_now("检测到本机鼠标移动")
                        return False
                if self.x11.any_key_pressed():
                    self._restore_cursor_now("检测到本机键盘按键")
                    return False
                return True

            GLib.idle_add(lambda: (GLib.timeout_add(60, watch_local_input), False)[1])

            self.ripple.play(
                "leave",
                self.pos_x,
                self.pos_y,
                present=lambda: (not self.active) and self.transition_seq == seq,
                on_finished=lambda: self._restore_cursor_if_seq(hseq),
            )

    def _restore_cursor_if_seq(self, hseq: int) -> None:
        if self.cursor_hide_seq == hseq:
            self._restore_cursor_now("离开波纹播完")

    def _restore_cursor_now(self, reason: str) -> None:
        if self.x11.cursor_hidden:
            self.cursor_hide_seq += 1
            self.x11.show_cursor()
            log(f"重新显示本机光标（{reason}）")

    async def _reset_input(self, reason: str) -> None:
        if not self.active:
            log(f"{reason}：当前不在被操作状态")
            return
        self._send_leave(None)
        self._deactivate(f"{reason}，交还主控", hide_cursor=True)

    # MARK: - UI Actions & Periodic Refresh

    def _ui_regen_code(self) -> None:
        if self._inviter is not None:
            self._inviter.regenerate_code()

    def _ui_toggle_swap(self, val: bool) -> None:
        if self.state.swap_cmd_ctrl == val:
            return
        self.state.swap_cmd_ctrl = val
        self.store.save(self.state)
        log(f"快捷键设置：{'开启' if val else '关闭'} Command ↔ Control 互换")

    async def _unpair_local(self) -> None:
        if self._link and self._link.active:
            self._link.active.send(Msg.UNPAIR, b"")
            await asyncio.sleep(0.15)
        await self._clear_pairing()

    async def _clear_pairing(self) -> None:
        if self.active:
            self._deactivate("解除配对", hide_cursor=False)
        self._restore_cursor_now("解除配对")
        if self._link is not None:
            await self._link.stop()
            self._link = None
        self.state.pairing = None
        self.state.shared = None
        self.state.peer_screens = {}
        self.other_screens.clear()
        self.store.save(self.state)
        self.ripple.update_config(None)
        await self._start_invite()

    def _refresh_screens(self, initial: bool = False) -> None:
        screens = detect_screens()
        if not screens:
            if initial:
                log("警告：暂时未检测到 X11 显示器，稍后重试")
            return
        if screens != self.local_screens:
            self.local_screens = screens
            desc = "；".join(
                f"「{s.name}」{'主屏 ' if s.is_main else ''}{int(s.w)}×{int(s.h)} @({int(s.x)},{int(s.y)}), {int(round(s.mm_w))}×{int(round(s.mm_h))}mm"
                for s in screens
            )
            log(f"本机屏幕：{desc}")
            if not initial and self._loop is not None:
                self._schedule_net(self._send_screens_async())
            if self.is_paired and self.state.pairing is not None:
                self.ui.update_paired(self.state.pairing["peerName"], self.link_status, self.local_screens, self.state.swap_cmd_ctrl)

    async def _send_screens_async(self) -> None:
        self._send_screens()

    def _tick_screens(self) -> bool:
        if self._stopping:
            return False
        self._refresh_screens(initial=False)
        return True

    def _refresh_status_now(self) -> None:
        if not self.is_paired or self.state.pairing is None:
            return
        if self._link and self._link.active is not None:
            new_st = "connected"
        elif time.monotonic() - self.link_changed_at < 10.0:
            new_st = "searching"
        else:
            new_st = "offline"
        if new_st != self.link_status:
            self.link_status = new_st
            self.ui.update_paired(self.state.pairing["peerName"], new_st, self.local_screens, self.state.swap_cmd_ctrl)

    def _tick_status(self) -> bool:
        if self._stopping:
            return False
        self._refresh_status_now()
        return True

    def _quit_from_ui(self) -> None:
        log("用户在界面选择「退出 MacKVM」")
        self._shutdown_and_quit()

    def _shutdown_and_quit(self) -> None:
        if self._stopping:
            return
        self._stopping = True
        self.hotkey.stop()
        if self._loop is not None:
            fut = asyncio.run_coroutine_threadsafe(self._async_shutdown(), self._loop)
            try:
                fut.result(timeout=2.0)
            except Exception:
                pass
            self._loop.call_soon_threadsafe(self._loop.stop)
        self.x11.close()
        self._remove_pid()
        Gtk.main_quit()

    async def _async_shutdown(self) -> None:
        if self.active:
            self._release_all()
            self.active = False
        if self._inviter is not None:
            await self._inviter.stop()
        if self._link is not None:
            await self._link.stop()
