"""XRandR / EDID screen detection and millimeter adjacency / crossing math."""

from __future__ import annotations

import hashlib
import math
import os
import re
import subprocess
from dataclasses import dataclass
from typing import Any

K_MIN_TOUCH_MM = 10.0
_CONNECTED_RE = re.compile(
    r"^(\S+)\s+connected\s*(primary\s+)?(\d+)x(\d+)\+(-?\d+)\+(-?\d+)(?:\s+[^(]*)?\([^)]*\)\s*(?:(\d+)mm\s+x\s+(\d+)mm)?",
)


@dataclass
class ScreenInfo:
    id: str
    name: str
    is_main: bool
    is_builtin: bool
    x: float
    y: float
    w: float
    h: float
    mm_w: float
    mm_h: float
    estimated: bool
    ux: float | None = None
    uy: float | None = None
    uw: float | None = None
    uh: float | None = None

    @property
    def usable_frame(self) -> tuple[float, float, float, float]:
        if self.ux is None or self.uy is None or self.uw is None or self.uh is None:
            return (self.x, self.y, self.w, self.h)
        x0 = max(self.x, self.ux)
        y0 = max(self.y, self.uy)
        x1 = min(self.x + self.w, self.ux + self.uw)
        y1 = min(self.y + self.h, self.uy + self.uh)
        rw, rh = x1 - x0, y1 - y0
        if rw < 100 or rh < 100:
            return (self.x, self.y, self.w, self.h)
        return (x0, y0, rw, rh)

    def edge_length_pt(self, edge: str) -> float:
        return self.w if edge in ("up", "down") else self.h

    def edge_length_mm(self, edge: str) -> float:
        return self.mm_w if edge in ("up", "down") else self.mm_h

    def edge_start_pt(self, edge: str) -> float:
        return self.x if edge in ("up", "down") else self.y

    def pt_to_mm(self, along_pt: float, edge: str) -> float:
        length = self.edge_length_pt(edge)
        return (along_pt - self.edge_start_pt(edge)) / length * self.edge_length_mm(edge) if length > 0 else 0.0

    def mm_to_pt(self, mm: float, edge: str) -> float:
        length = self.edge_length_mm(edge)
        return self.edge_start_pt(edge) + (mm / length * self.edge_length_pt(edge) if length > 0 else 0.0)

    def contains(self, px: float, py: float) -> bool:
        return self.x <= px < self.x + self.w and self.y <= py < self.y + self.h

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "id": self.id,
            "name": self.name,
            "isMain": self.is_main,
            "isBuiltin": self.is_builtin,
            "x": self.x,
            "y": self.y,
            "w": self.w,
            "h": self.h,
            "mmW": self.mm_w,
            "mmH": self.mm_h,
            "estimated": self.estimated,
        }
        if self.ux is not None and self.uy is not None and self.uw is not None and self.uh is not None:
            d["ux"] = self.ux
            d["uy"] = self.uy
            d["uw"] = self.uw
            d["uh"] = self.uh
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "ScreenInfo":
        return cls(
            id=str(d["id"]),
            name=str(d["name"]),
            is_main=bool(d.get("isMain", False)),
            is_builtin=bool(d.get("isBuiltin", False)),
            x=float(d["x"]),
            y=float(d["y"]),
            w=float(d["w"]),
            h=float(d["h"]),
            mm_w=float(d["mmW"]),
            mm_h=float(d["mmH"]),
            estimated=bool(d.get("estimated", False)),
            ux=float(d["ux"]) if d.get("ux") is not None else None,
            uy=float(d["uy"]) if d.get("uy") is not None else None,
            uw=float(d["uw"]) if d.get("uw") is not None else None,
            uh=float(d["uh"]) if d.get("uh") is not None else None,
        )


def parse_edid_info(edid_hex: str) -> tuple[str | None, str | None]:
    """Extract (stable_id, display_name) from a 128+ byte EDID hex string."""
    raw_hex = re.sub(r"\s+", "", edid_hex)
    if len(raw_hex) < 256:
        return (None, None)
    try:
        raw = bytes.fromhex(raw_hex)
    except ValueError:
        return (None, None)
    if len(raw) < 128:
        return (None, None)
    stable_id = hashlib.sha256(raw[:128]).hexdigest()[:16].upper()
    name: str | None = None
    for off in (54, 72, 90, 108):
        blk = raw[off : off + 18]
        if len(blk) == 18 and blk[0] == 0 and blk[1] == 0 and blk[2] == 0 and blk[3] == 0xFC:
            text = blk[5:18].decode("ascii", errors="ignore").split("\n", 1)[0].strip("\x00 ")
            if text:
                name = text
                break
    return (stable_id, name)


def parse_xrandr_output(text: str, workarea: tuple[float, float, float, float] | None = None) -> list[ScreenInfo]:
    screens: list[ScreenInfo] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = _CONNECTED_RE.match(lines[i])
        if not m:
            i += 1
            continue
        out_name = m.group(1)
        is_primary = bool(m.group(2))
        w = float(int(m.group(3)))
        h = float(int(m.group(4)))
        x = float(int(m.group(5)))
        y = float(int(m.group(6)))
        mm_w = float(int(m.group(7))) if m.group(7) else 0.0
        mm_h = float(int(m.group(8))) if m.group(8) else 0.0

        edid_lines: list[str] = []
        j = i + 1
        while j < len(lines) and (lines[j].startswith("\t") or lines[j].startswith(" ")):
            stripped = lines[j].strip()
            if stripped == "EDID:":
                k = j + 1
                while k < len(lines) and lines[k].startswith("\t\t"):
                    edid_lines.append(lines[k].strip())
                    k += 1
                j = k
                continue
            j += 1
        i = j

        stable_id, edid_name = parse_edid_info("".join(edid_lines))
        scr_id = stable_id or out_name
        scr_name = edid_name or out_name
        estimated = False
        if mm_w <= 0 or mm_h <= 0:
            # Estimate assuming ~96 DPI when monitor EDID lacks physical dimensions
            mm_w = round(w / 96.0 * 25.4)
            mm_h = round(h / 96.0 * 25.4)
            estimated = True
        is_builtin = out_name.lower().startswith(("edp", "lvds", "dsi"))

        ux = uy = uw = uh = None
        if workarea is not None:
            wx, wy, ww, wh = workarea
            ix0, iy0 = max(x, wx), max(y, wy)
            ix1, iy1 = min(x + w, wx + ww), min(y + h, wy + wh)
            if ix1 - ix0 >= 100 and iy1 - iy0 >= 100:
                ux, uy, uw, uh = ix0, iy0, ix1 - ix0, iy1 - iy0

        screens.append(
            ScreenInfo(
                id=scr_id,
                name=scr_name,
                is_main=is_primary,
                is_builtin=is_builtin,
                x=x,
                y=y,
                w=w,
                h=h,
                mm_w=mm_w,
                mm_h=mm_h,
                estimated=estimated,
                ux=ux,
                uy=uy,
                uw=uw,
                uh=uh,
            )
        )

    if screens and not any(s.is_main for s in screens):
        screens[0].is_main = True
    return screens


def query_workarea(env: dict[str, str] | None = None) -> tuple[float, float, float, float] | None:
    try:
        res = subprocess.run(
            ["xprop", "-root", "_NET_WORKAREA"],
            capture_output=True,
            text=True,
            timeout=2.0,
            env=env,
        )
        if res.returncode != 0:
            return None
        m = re.search(r"=\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)", res.stdout)
        if not m:
            return None
        return (float(m.group(1)), float(m.group(2)), float(m.group(3)), float(m.group(4)))
    except Exception:
        return None


def detect_screens(display: str | None = None) -> list[ScreenInfo]:
    env = dict(os.environ)
    if display:
        env["DISPLAY"] = display
    try:
        res = subprocess.run(
            ["xrandr", "--prop"],
            capture_output=True,
            text=True,
            timeout=3.0,
            env=env,
        )
        if res.returncode != 0:
            return []
        wa = query_workarea(env)
        return parse_xrandr_output(res.stdout, workarea=wa)
    except Exception:
        return []


_OPPOSITE = {"up": "down", "down": "up", "left": "right", "right": "left"}


@dataclass
class RuleView:
    rule_id: str
    local_screen: str
    local_edge: str
    remote_device: str
    remote_screen: str
    offset_mm: float

    @property
    def remote_edge(self) -> str:
        return _OPPOSITE[self.local_edge]

    def touch(self, local: ScreenInfo, remote: ScreenInfo) -> tuple[float, float]:
        lo = max(0.0, self.offset_mm)
        hi = min(local.edge_length_mm(self.local_edge), self.offset_mm + remote.edge_length_mm(self.remote_edge))
        return (lo, hi)

    def remote_mm(self, local_mm: float) -> float:
        return local_mm - self.offset_mm


def rule_views_from_shared(shared: dict[str, Any] | None, me_id: str) -> list[RuleView]:
    if not shared:
        return []
    out: list[RuleView] = []
    for r in shared.get("rules", []):
        a_dev = r.get("aDevice")
        b_dev = r.get("bDevice")
        rid = r.get("id", "")
        a_edge = r.get("aEdge", "right")
        offset = float(r.get("offsetMM", 0.0))
        if a_dev == me_id:
            out.append(
                RuleView(
                    rule_id=rid,
                    local_screen=r["aScreen"],
                    local_edge=a_edge,
                    remote_device=b_dev,
                    remote_screen=r["bScreen"],
                    offset_mm=offset,
                )
            )
        elif b_dev == me_id:
            out.append(
                RuleView(
                    rule_id=rid,
                    local_screen=r["bScreen"],
                    local_edge=_OPPOSITE[a_edge],
                    remote_device=a_dev,
                    remote_screen=r["aScreen"],
                    offset_mm=-offset,
                )
            )
    return out


@dataclass
class CrossingHit:
    rule_id: str
    local_screen: str
    local_edge: str
    cross_x: float
    cross_y: float
    local_mm: float
    remote_device: str
    remote_screen: str
    remote_edge: str
    remote_mm: float


class CrossingMap:
    def __init__(
        self,
        views: list[RuleView],
        local_screens: list[ScreenInfo],
        remote_by_device: dict[str, list[ScreenInfo]],
    ) -> None:
        self.views = views
        self.local: dict[str, ScreenInfo] = {s.id: s for s in local_screens}
        self.remote_by_device: dict[str, dict[str, ScreenInfo]] = {
            dev: {s.id: s for s in slist} for dev, slist in remote_by_device.items()
        }

    def remote_screen(self, v: RuleView) -> ScreenInfo | None:
        return self.remote_by_device.get(v.remote_device, {}).get(v.remote_screen)

    @property
    def active_views(self) -> list[RuleView]:
        out: list[RuleView] = []
        for v in self.views:
            l = self.local.get(v.local_screen)
            r = self.remote_screen(v)
            if l is None or r is None:
                continue
            lo, hi = v.touch(l, r)
            if hi - lo >= K_MIN_TOUCH_MM - 0.001:
                out.append(v)
        return out

    def hit(self, p0x: float, p0y: float, p1x: float, p1y: float) -> CrossingHit | None:
        best_t: float | None = None
        best_hit: CrossingHit | None = None
        still = (p1x == p0x and p1y == p0y)
        for v in self.active_views:
            s = self.local.get(v.local_screen)
            r = self.remote_screen(v)
            if s is None or r is None:
                continue
            fmin_x, fmin_y, fmax_x, fmax_y = s.x, s.y, s.x + s.w, s.y + s.h
            ux, uy, uw, uh = s.usable_frame
            umax_x, umax_y = ux + uw, uy + uh
            if not (p0x >= fmin_x - 0.5 and p0x <= fmax_x and p0y >= fmin_y - 0.5 and p0y <= fmax_y):
                continue
            e = v.local_edge
            if e == "right":
                line = fmax_x - 1
                crossed = (p1x >= line and (p0x < line or p1x > p0x)) or (still and line - p0x < 1)
            elif e == "left":
                line = fmin_x
                crossed = (p1x <= line and (p0x > line or p1x < p0x)) or (still and p0x - line < 1)
            elif e == "down":
                line = fmax_y - 1
                crossed = (p1y >= line and (p0y < line or p1y > p0y)) or (still and line - p0y < 1)
            else:
                line = fmin_y
                crossed = (p1y <= line and (p0y > line or p1y < p0y)) or (still and p0y - line < 1)
            if not crossed:
                continue
            if e in ("up", "down"):
                t = 1.0 if p1y == p0y else (line - p0y) / (p1y - p0y)
                t = min(max(t, 0.0), 1.0)
                along = p0x + t * (p1x - p0x)
            else:
                t = 1.0 if p1x == p0x else (line - p0x) / (p1x - p0x)
                t = min(max(t, 0.0), 1.0)
                along = p0y + t * (p1y - p0y)
            t_lo, t_hi = v.touch(s, r)
            lo_pt, hi_pt = s.mm_to_pt(t_lo, e), s.mm_to_pt(t_hi, e)
            if along < lo_pt - 0.5 or along > hi_pt + 0.5:
                continue
            mm = min(max(s.pt_to_mm(along, e), t_lo), t_hi)
            if e in ("up", "down"):
                cpx = min(max(along, ux), umax_x - 1)
                cpy = umax_y - 1 if e == "down" else uy
            else:
                cpx = umax_x - 1 if e == "right" else ux
                cpy = min(max(along, uy), umax_y - 1)
            rmm = min(max(v.remote_mm(mm), 0.0), r.edge_length_mm(v.remote_edge))
            hit = CrossingHit(
                rule_id=v.rule_id,
                local_screen=s.id,
                local_edge=e,
                cross_x=cpx,
                cross_y=cpy,
                local_mm=mm,
                remote_device=v.remote_device,
                remote_screen=r.id,
                remote_edge=v.remote_edge,
                remote_mm=rmm,
            )
            if best_t is None or t < best_t:
                best_t = t
                best_hit = hit
        return best_hit

    @staticmethod
    def landing(s: ScreenInfo, edge: str, mm: float) -> tuple[float, float]:
        ux, uy, uw, uh = s.usable_frame
        umax_x, umax_y = ux + uw, uy + uh
        length = s.edge_length_mm(edge)
        along = s.mm_to_pt(min(max(mm, 0.0), length), edge)
        if edge in ("up", "down"):
            x = min(max(along, ux), umax_x - 1)
            return (x, umax_y - 2 if edge == "down" else uy + 1)
        y = min(max(along, uy), umax_y - 1)
        return (umax_x - 2 if edge == "right" else ux + 1, y)


def outward_component(dx: float, dy: float, edge: str) -> float:
    if edge == "right":
        return dx
    if edge == "left":
        return -dx
    if edge == "down":
        return dy
    return -dy


def beyond_edge(p1x: float, p1y: float, hit: CrossingHit) -> float:
    if hit.local_edge == "right":
        return p1x - hit.cross_x
    if hit.local_edge == "left":
        return hit.cross_x - p1x
    if hit.local_edge == "down":
        return p1y - hit.cross_y
    return hit.cross_y - p1y


class LeaveDebounce:
    def __init__(self) -> None:
        self.pending_rule: str | None = None
        self.pending_edge: str | None = None
        self.push: float = 0.0

    def reset(self) -> None:
        self.pending_rule = None
        self.pending_edge = None
        self.push = 0.0

    def feed(
        self,
        hit: CrossingHit | None,
        beyond: float,
        into_own_screen: bool,
        since_enter: float,
        outward_on_pending: float | None,
    ) -> bool:
        if since_enter < 0.15:
            self.reset()
            return False
        if hit is not None:
            if into_own_screen:
                return True
            if hit.rule_id != self.pending_rule or hit.local_edge != self.pending_edge:
                self.pending_rule = hit.rule_id
                self.pending_edge = hit.local_edge
                self.push = 0.0
            self.push += max(beyond, 0.0)
            return self.push >= 15.0
        if outward_on_pending is not None and outward_on_pending >= 0.0 and self.pending_rule is not None:
            return False
        self.reset()
        return False
