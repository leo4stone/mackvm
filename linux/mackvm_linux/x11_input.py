"""X11 ctypes input injection, XFixes cursor hiding, and global Ctrl+Alt+Super+L hotkey."""

from __future__ import annotations

import atexit
import ctypes
import ctypes.util
import select
import threading
import time
from typing import Callable

from .state import log

_libx11 = ctypes.CDLL("libX11.so.6")
_libxtst = ctypes.CDLL("libXtst.so.6")
_libxfixes = ctypes.CDLL("libXfixes.so.3")

# Initialize Xlib thread safety before opening any Display connections
_libx11.XInitThreads.argtypes = []
_libx11.XInitThreads.restype = ctypes.c_int
_libx11.XInitThreads()

# Explicit 64-bit ctypes prototypes
_libx11.XOpenDisplay.argtypes = [ctypes.c_char_p]
_libx11.XOpenDisplay.restype = ctypes.c_void_p

_libx11.XCloseDisplay.argtypes = [ctypes.c_void_p]
_libx11.XCloseDisplay.restype = ctypes.c_int

_libx11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
_libx11.XDefaultRootWindow.restype = ctypes.c_ulong

_libx11.XFlush.argtypes = [ctypes.c_void_p]
_libx11.XFlush.restype = ctypes.c_int

_libx11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
_libx11.XSync.restype = ctypes.c_int

_libx11.XQueryPointer.argtypes = [
    ctypes.c_void_p,
    ctypes.c_ulong,
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_uint),
]
_libx11.XQueryPointer.restype = ctypes.c_int

_libx11.XQueryKeymap.argtypes = [ctypes.c_void_p, ctypes.c_ubyte * 32]
_libx11.XQueryKeymap.restype = ctypes.c_int

_libx11.XConnectionNumber.argtypes = [ctypes.c_void_p]
_libx11.XConnectionNumber.restype = ctypes.c_int

_libx11.XPending.argtypes = [ctypes.c_void_p]
_libx11.XPending.restype = ctypes.c_int

_libx11.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_libx11.XNextEvent.restype = ctypes.c_int

_libx11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
_libx11.XKeysymToKeycode.restype = ctypes.c_ubyte

_libx11.XGrabKey.argtypes = [
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.c_uint,
    ctypes.c_ulong,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
]
_libx11.XGrabKey.restype = ctypes.c_int

_libx11.XUngrabKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong]
_libx11.XUngrabKey.restype = ctypes.c_int

_libx11.XSetErrorHandler.argtypes = [ctypes.c_void_p]
_libx11.XSetErrorHandler.restype = ctypes.c_void_p

_libxtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
_libxtst.XTestFakeMotionEvent.restype = ctypes.c_int

_libxtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
_libxtst.XTestFakeButtonEvent.restype = ctypes.c_int

_libxtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
_libxtst.XTestFakeKeyEvent.restype = ctypes.c_int

_libxtst.XTestGrabControl.argtypes = [ctypes.c_void_p, ctypes.c_int]
_libxtst.XTestGrabControl.restype = ctypes.c_int

_libxfixes.XFixesHideCursor.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
_libxfixes.XFixesHideCursor.restype = None

_libxfixes.XFixesShowCursor.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
_libxfixes.XFixesShowCursor.restype = None

_XErrorCB = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)


@_XErrorCB
def _ignore_x_error(_dpy: int, _err: int) -> int:
    return 0


# Keep callback alive
_ERROR_CB_REF = _ignore_x_error


class _XAnyEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("pad", ctypes.c_long * 20),
    ]


class X11Controller:
    """Thread-safe XTest + XFixes controller for a single X11 Display."""

    PIXELS_PER_NOTCH = 36.0

    def __init__(self, display_name: str | None = None) -> None:
        self._lock = threading.Lock()
        dpy_bytes = display_name.encode("utf-8") if display_name else None
        self._dpy = _libx11.XOpenDisplay(dpy_bytes)
        if not self._dpy:
            raise RuntimeError(f"无法打开 X11 Display（{display_name or '默认'}）")
        self._root = _libx11.XDefaultRootWindow(self._dpy)
        _libxtst.XTestGrabControl(self._dpy, 1)
        _libx11.XFlush(self._dpy)
        self._hidden = False
        self._acc_x = 0.0
        self._acc_y = 0.0
        atexit.register(self.close)

    def close(self) -> None:
        with self._lock:
            if not self._dpy:
                return
            if self._hidden:
                try:
                    _libxfixes.XFixesShowCursor(self._dpy, self._root)
                    _libx11.XFlush(self._dpy)
                except Exception:
                    pass
                self._hidden = False
            try:
                _libx11.XCloseDisplay(self._dpy)
            except Exception:
                pass
            self._dpy = None

    def query_pointer(self) -> tuple[int, int] | None:
        with self._lock:
            if not self._dpy:
                return None
            r_win = ctypes.c_ulong()
            c_win = ctypes.c_ulong()
            rx = ctypes.c_int()
            ry = ctypes.c_int()
            wx = ctypes.c_int()
            wy = ctypes.c_int()
            mask = ctypes.c_uint()
            ok = _libx11.XQueryPointer(
                self._dpy,
                self._root,
                ctypes.byref(r_win),
                ctypes.byref(c_win),
                ctypes.byref(rx),
                ctypes.byref(ry),
                ctypes.byref(wx),
                ctypes.byref(wy),
                ctypes.byref(mask),
            )
            return (rx.value, ry.value) if ok else None

    def any_key_pressed(self) -> bool:
        with self._lock:
            if not self._dpy:
                return False
            buf = (ctypes.c_ubyte * 32)()
            _libx11.XQueryKeymap(self._dpy, buf)
            return any(b != 0 for b in buf)

    def warp(self, x: float, y: float) -> None:
        with self._lock:
            if not self._dpy:
                return
            _libxtst.XTestFakeMotionEvent(self._dpy, -1, int(round(x)), int(round(y)), 0)
            _libx11.XFlush(self._dpy)

    def button(self, x11_button: int, down: bool) -> None:
        with self._lock:
            if not self._dpy:
                return
            _libxtst.XTestFakeButtonEvent(self._dpy, x11_button, 1 if down else 0, 0)
            _libx11.XFlush(self._dpy)

    def key(self, x11_keycode: int, down: bool) -> None:
        with self._lock:
            if not self._dpy:
                return
            _libxtst.XTestFakeKeyEvent(self._dpy, x11_keycode, 1 if down else 0, 0)
            _libx11.XFlush(self._dpy)

    def reset_scroll_accumulator(self) -> None:
        with self._lock:
            self._acc_x = 0.0
            self._acc_y = 0.0

    def scroll(self, dx_line: int, dy_line: int, dx_pt: int, dy_pt: int, shift_held: bool) -> None:
        if shift_held and dx_line == 0 and dx_pt == 0 and (dy_line != 0 or dy_pt != 0):
            dx_line, dy_line = dy_line, 0
            dx_pt, dy_pt = dy_pt, 0

        with self._lock:
            if not self._dpy:
                return
            clicks_x = self._scroll_clicks(dx_line, dx_pt, axis="x")
            clicks_y = self._scroll_clicks(dy_line, dy_pt, axis="y")
            # X11 scroll buttons: 4=Up (+Y), 5=Down (-Y), 6=Left (+X), 7=Right (-X)
            for _ in range(abs(clicks_y)):
                btn = 4 if clicks_y > 0 else 5
                _libxtst.XTestFakeButtonEvent(self._dpy, btn, 1, 0)
                _libxtst.XTestFakeButtonEvent(self._dpy, btn, 0, 0)
            for _ in range(abs(clicks_x)):
                btn = 6 if clicks_x > 0 else 7
                _libxtst.XTestFakeButtonEvent(self._dpy, btn, 1, 0)
                _libxtst.XTestFakeButtonEvent(self._dpy, btn, 0, 0)
            if clicks_x or clicks_y:
                _libx11.XFlush(self._dpy)

    def _scroll_clicks(self, line_delta: int, pt_delta: int, axis: str) -> int:
        if pt_delta != 0:
            acc = (self._acc_x if axis == "x" else self._acc_y) + float(pt_delta)
            clicks = int(acc / self.PIXELS_PER_NOTCH)
            rem = acc - clicks * self.PIXELS_PER_NOTCH
            if clicks == 0 and abs(pt_delta) > 0 and abs(acc) >= self.PIXELS_PER_NOTCH:
                clicks = 1 if acc > 0 else -1
                rem = acc - clicks * self.PIXELS_PER_NOTCH
            if axis == "x":
                self._acc_x = rem
            else:
                self._acc_y = rem
            return max(-4, min(4, clicks))
        if line_delta != 0:
            return max(-4, min(4, line_delta))
        return 0

    def hide_cursor(self) -> None:
        with self._lock:
            if not self._dpy or self._hidden:
                return
            _libxfixes.XFixesHideCursor(self._dpy, self._root)
            _libx11.XFlush(self._dpy)
            self._hidden = True

    def show_cursor(self) -> None:
        with self._lock:
            if not self._dpy or not self._hidden:
                return
            _libxfixes.XFixesShowCursor(self._dpy, self._root)
            _libx11.XFlush(self._dpy)
            self._hidden = False

    @property
    def cursor_hidden(self) -> bool:
        return self._hidden


class HotkeyWatcher:
    """Listens on a dedicated X11 Display for local Ctrl + Alt + Super + L."""

    def __init__(self, on_trigger: Callable[[], None], display_name: str | None = None) -> None:
        self.on_trigger = on_trigger
        self.display_name = display_name
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, name="MacKVMHotkeyWatcher", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    def _run(self) -> None:
        dpy_bytes = self.display_name.encode("utf-8") if self.display_name else None
        dpy = _libx11.XOpenDisplay(dpy_bytes)
        if not dpy:
            log("警告：本机重置热键监听打开 Display 失败")
            return
        _libx11.XSetErrorHandler(_ERROR_CB_REF)
        root = _libx11.XDefaultRootWindow(dpy)
        kc = _libx11.XKeysymToKeycode(dpy, 0x006C)  # XK_l
        # ControlMask (4) | Mod1Mask (8) | Mod4Mask (64)
        base_mask = 4 | 8 | 64
        lock_variants = (0, 2, 16, 18)  # None, LockMask(2), Mod2Mask/NumLock(16), both
        if kc:
            for extra in lock_variants:
                _libx11.XGrabKey(dpy, int(kc), base_mask | extra, root, 0, 1, 1)
            _libx11.XSync(dpy, 0)
            log("本机重置热键 Ctrl+Alt+Super+L 的监听已装上")
        fd = _libx11.XConnectionNumber(dpy)
        ev = _XAnyEvent()
        last_fire = 0.0
        try:
            while not self._stop_event.is_set():
                r, _, _ = select.select([fd], [], [], 0.25)
                if not r:
                    continue
                while _libx11.XPending(dpy) > 0:
                    _libx11.XNextEvent(dpy, ctypes.byref(ev))
                    if ev.type == 2:  # KeyPress
                        now = time.monotonic()
                        if now - last_fire > 0.25:
                            last_fire = now
                            self.on_trigger()
        finally:
            if kc:
                for extra in lock_variants:
                    _libx11.XUngrabKey(dpy, int(kc), base_mask | extra, root)
                _libx11.XSync(dpy, 1)
            _libx11.XCloseDisplay(dpy)
