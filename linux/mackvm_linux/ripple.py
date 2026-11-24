"""GTK3 + Cairo transparent X11 cursor ripple effects matching MacKVM Ripple.swift."""

from __future__ import annotations

import math
import time
from typing import Any, Callable

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

from .state import DEFAULT_RIPPLE, log, sanitize_ripple


def _parse_hex_rgb(hex_color: str) -> tuple[float, float, float]:
    s = hex_color.strip().lstrip("#")
    if len(s) != 6:
        return (1.0, 1.0, 1.0)
    try:
        v = int(s, 16)
        return (((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0)
    except ValueError:
        return (1.0, 1.0, 1.0)


class _RingWindow(Gtk.Window):
    def __init__(self, cx: float, cy: float, max_radius: float, duration: float, rgb: tuple[float, float, float]) -> None:
        super().__init__(type=Gtk.WindowType.POPUP)
        self.max_radius = float(max_radius)
        self.line_width = 2.0
        self.duration = max(0.05, float(duration))
        self.rgb = rgb
        self.start_time = time.monotonic()
        self.radius = 1.0
        self.opacity = 0.8
        self.pad = self.max_radius + self.line_width + 2.0
        self.size = int(math.ceil(self.pad * 2.0))

        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(False)
        self.set_keep_above(True)
        self.set_app_paintable(True)
        self.set_default_size(self.size, self.size)
        self.set_size_request(self.size, self.size)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)

        self.connect("realize", self._on_realize)
        self.connect("draw", self._on_draw)
        self.move(int(round(cx - self.pad)), int(round(cy - self.pad)))
        self.show_all()
        self._timer_id = GLib.timeout_add(16, self._tick)

    def _on_realize(self, _w: Gtk.Widget) -> None:
        # Click-through overlay: never intercept mouse or keyboard
        try:
            self.input_shape_combine_region(cairo.Region())
        except Exception:
            pass
        gdk_win = self.get_window()
        if gdk_win is not None:
            try:
                gdk_win.set_pass_through(True)
            except Exception:
                pass

    def _tick(self) -> bool:
        elapsed = time.monotonic() - self.start_time
        progress = min(1.0, elapsed / self.duration)
        # Cubic ease-out expansion + linear fade-out matching RipplePreview / CoreAnimation
        eased = 1.0 - (1.0 - progress) ** 3
        self.radius = 1.0 + (self.max_radius - 1.0) * eased
        self.opacity = 0.8 * (1.0 - progress)
        self.queue_draw()
        if progress >= 1.0:
            self._timer_id = 0
            self.destroy()
            return False
        return True

    def _on_draw(self, _w: Gtk.Widget, ctx: cairo.Context) -> bool:
        ctx.save()
        ctx.set_operator(cairo.OPERATOR_SOURCE)
        ctx.set_source_rgba(0.0, 0.0, 0.0, 0.0)
        ctx.paint()
        ctx.set_operator(cairo.OPERATOR_OVER)
        r, g, b = self.rgb
        ctx.set_source_rgba(r, g, b, max(0.0, self.opacity))
        ctx.set_line_width(self.line_width)
        ctx.arc(self.pad, self.pad, self.radius, 0.0, math.tau)
        ctx.stroke()
        ctx.restore()
        return True


class RipplePlayer:
    def __init__(self, sample_cursor: Callable[[], tuple[float, float] | None]) -> None:
        self.sample_cursor = sample_cursor
        self.config: dict[str, Any] = dict(DEFAULT_RIPPLE)
        self._live_trails: set[int] = set()
        self._next_id = 1

    def update_config(self, cfg: dict[str, Any] | None) -> None:
        self.config = sanitize_ripple(cfg)

    def play(
        self,
        kind: str,
        x: float,
        y: float,
        present: Callable[[], bool],
        on_finished: Callable[[], None] | None = None,
    ) -> None:
        def start_on_main() -> bool:
            cfg = self.config
            if not cfg.get("enabled", True):
                if on_finished is not None:
                    on_finished()
                return False

            if kind == "leave":
                max_r = float(cfg["leaveSize"])
                ring_dur = float(cfg["leaveDuration"])
                interval = max(0.02, float(cfg["leaveInterval"]))
                min_dur = float(cfg["leaveTotal"])
                idle_stop = math.inf
                max_dur = float(cfg["leaveTotal"])
                colors = cfg["leaveColors"]
                label = "离开波纹"
            else:
                max_r = float(cfg["arriveSize"])
                ring_dur = float(cfg["arriveDuration"])
                interval = max(0.02, float(cfg["spawnInterval"]))
                min_dur = float(cfg["minDuration"])
                idle_stop = float(cfg["idleStop"])
                max_dur = max(float(cfg["maxDuration"]), min_dur)
                colors = cfg["arriveColors"]
                label = "进入波纹"

            log(f"{label}开始：({int(x)}, {int(y)})")
            trail_id = self._next_id
            self._next_id += 1
            self._live_trails.add(trail_id)

            start_t = time.monotonic()
            state = {
                "last_move": start_t,
                "last_x": x,
                "last_y": y,
                "rings": 0,
                "last_spawn": start_t,
                "done": False,
            }

            def spawn(px: float, py: float, idx: int) -> None:
                hex_c = colors[idx % len(colors)]
                _RingWindow(px, py, max_r, ring_dur, _parse_hex_rgb(hex_c))

            spawn(x, y, 0)
            state["rings"] = 1

            def finish(reason: str) -> None:
                if state["done"]:
                    return
                state["done"] = True
                self._live_trails.discard(trail_id)
                secs = time.monotonic() - start_t
                log(f"{label}结束（{reason}）：共出 {state['rings']} 个环，持续 {secs:.1f} 秒")
                if on_finished is not None:
                    wait_ms = max(0, int(round((state["last_spawn"] + ring_dur - time.monotonic()) * 1000)))
                    if wait_ms <= 0:
                        on_finished()
                    else:
                        GLib.timeout_add(wait_ms, lambda: (on_finished(), False)[1])

            def tick() -> bool:
                if state["done"]:
                    return False
                now = time.monotonic()
                pt = self.sample_cursor()
                px, py = pt if pt is not None else (state["last_x"], state["last_y"])
                if math.hypot(px - state["last_x"], py - state["last_y"]) > 1.0:
                    state["last_move"] = now
                state["last_x"] = px
                state["last_y"] = py

                if not (cfg.get("enabled", True) and present()):
                    finish("光标回到主控" if kind == "leave" else "光标离开本机")
                    return False

                slack = interval / 2.0
                elapsed = now - start_t
                since_move = now - state["last_move"]
                if kind == "leave":
                    if elapsed + slack >= max_dur:
                        finish("到达持续时间")
                        return False
                else:
                    if elapsed + slack >= max_dur:
                        finish("到达上限")
                        return False
                    if elapsed + slack >= min_dur and since_move + slack >= idle_stop:
                        finish("鼠标停下")
                        return False

                rx, ry = (x, y) if kind == "leave" else (px, py)
                spawn(rx, ry, state["rings"])
                state["rings"] += 1
                state["last_spawn"] = now
                return True

            GLib.timeout_add(int(round(interval * 1000)), tick)
            return False

        GLib.idle_add(start_on_main)
