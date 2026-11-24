#!/usr/bin/env python3
"""Unit tests for MacKVM Ubuntu X11 client (no live X11 server required)."""

from __future__ import annotations

import asyncio
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from mackvm_linux.keymap import mac_button_to_x11, mac_keycode_to_x11
from mackvm_linux.protocol import (
    Msg,
    _create_dualstack_socket,
    cpace_generator,
    derive_pairing_keys,
    hmac_mac,
    hmac_verify,
    open_frame,
    pairing_transcript,
    parse_avahi_browse_line,
    seal_frame,
    seal_session_frame,
    x25519_exchange,
)
from mackvm_linux.screens import (
    CrossingMap,
    LeaveDebounce,
    ScreenInfo,
    beyond_edge,
    outward_component,
    parse_edid_info,
    parse_xrandr_output,
    rule_views_from_shared,
)
from mackvm_linux.state import PersistedState, Store, sanitize_ripple

SAMPLE_XRANDR = """\
Screen 0: minimum 8 x 8, current 2048 x 1152, maximum 32767 x 32767
DP-0 disconnected (normal left inverted right x axis y axis)
DP-1 connected primary 2048x1152+0+0 (normal left inverted right x axis y axis) 600mm x 340mm
\tEDID: 
\t\t00ffffffffffff0010acb9414c524c46
\t\t1d1f0103803c2278eeee95a3544c9926
\t\t0f5054a54b00e1c0d100d1c0b300a940
\t\t81808100714f08e80030f2705a80b058
\t\t8a0055502100001e000000ff00475737
\t\t535838330a2020202020000000fc0044
\t\t454c4c205532373230514d0a000000fd
\t\t00184b1e8c3c000a2020202020200117
"""


class MacKVMLinuxTests(unittest.TestCase):
    def test_x25519_matches_swift_cryptokit_vector(self) -> None:
        a0 = X25519PrivateKey.from_private_bytes(bytes(range(1, 33)))
        g0 = bytearray(range(100, 132))
        g0[31] &= 0x7F
        shared = x25519_exchange(a0, bytes(g0))
        self.assertEqual(
            shared.hex(),
            "1b3f833f379c27193820ad98f0d17202f60eddd76c88076d667f3a2e7144a70e",
        )

    def test_cpace_pairing_agreement(self) -> None:
        nc = os.urandom(16)
        ni = os.urandom(16)
        priv_c = X25519PrivateKey.generate()
        priv_i = X25519PrivateKey.generate()
        gc = cpace_generator("58291604", nc, ni, "c-id", "i-id")
        gi = cpace_generator("58291604", nc, ni, "c-id", "i-id")
        yc = x25519_exchange(priv_c, gc)
        yi = x25519_exchange(priv_i, gi)
        kc = x25519_exchange(priv_c, yi)
        ki = x25519_exchange(priv_i, yc)
        self.assertEqual(kc, ki)

        tr = pairing_transcript("c-id", "Mac", nc, "i-id", "Ubuntu", ni, yi, yc)
        cc1, ci1, lt1 = derive_pairing_keys(kc, tr)
        cc2, ci2, lt2 = derive_pairing_keys(ki, tr)
        self.assertEqual(lt1, lt2)
        mac_c = hmac_mac(cc1, tr)
        self.assertTrue(hmac_verify(mac_c, cc2, tr))
        mac_i = hmac_mac(ci2, tr)
        self.assertTrue(hmac_verify(mac_i, ci1, tr))

    def test_chachapoly_framing(self) -> None:
        key = os.urandom(32)
        hello = seal_frame(key, Msg.HELLO, b"", 0x1122334455667788)
        length = int.from_bytes(hello[:4], "big")
        self.assertEqual(length, len(hello) - 4)
        plain = open_frame(key, hello[4:])
        self.assertEqual(plain[0], Msg.HELLO)
        self.assertEqual(int.from_bytes(plain[1:9], "big"), 0x1122334455667788)

        msg = seal_session_frame(key, Msg.MOVE, 99, 7, b"abcd")
        plain2 = open_frame(key, msg[4:])
        self.assertEqual(plain2[0], Msg.MOVE)
        self.assertEqual(int.from_bytes(plain2[1:9], "big"), 99)
        self.assertEqual(int.from_bytes(plain2[9:17], "big"), 7)
        self.assertEqual(plain2[17:], b"abcd")

    def test_edid_and_xrandr_parser(self) -> None:
        screens = parse_xrandr_output(SAMPLE_XRANDR, workarea=(70.0, 27.0, 1978.0, 1125.0))
        self.assertEqual(len(screens), 1)
        s = screens[0]
        self.assertEqual(s.name, "DELL U2720QM")
        self.assertTrue(s.is_main)
        self.assertEqual((s.w, s.h, s.mm_w, s.mm_h), (2048.0, 1152.0, 600.0, 340.0))
        self.assertEqual(s.usable_frame, (70.0, 27.0, 1978.0, 1125.0))
        self.assertFalse(s.estimated)
        sid, name = parse_edid_info("00" * 10)
        self.assertIsNone(sid)
        self.assertIsNone(name)

    def test_keymap_cmd_ctrl_swap_and_buttons(self) -> None:
        # Cmd_L (0x37) -> Ctrl_L (evdev 29 -> X11 37) when swapped, Super_L (125+8=133) when unswapped
        self.assertEqual(mac_keycode_to_x11(0x37, swap_cmd_ctrl=True), 29 + 8)
        self.assertEqual(mac_keycode_to_x11(0x37, swap_cmd_ctrl=False), 125 + 8)
        # Ctrl_L (0x3B) -> Super_L (133) when swapped
        self.assertEqual(mac_keycode_to_x11(0x3B, swap_cmd_ctrl=True), 125 + 8)
        self.assertEqual(mac_keycode_to_x11(0x3B, swap_cmd_ctrl=False), 29 + 8)
        # C key (0x08) -> evdev 46 + 8 = 54
        self.assertEqual(mac_keycode_to_x11(0x08, swap_cmd_ctrl=True), 46 + 8)
        # Media play (0xFF10) -> evdev 164 + 8 = 172
        self.assertEqual(mac_keycode_to_x11(0xFF10, swap_cmd_ctrl=True), 164 + 8)
        # Mouse buttons
        self.assertEqual(mac_button_to_x11(0), 1)
        self.assertEqual(mac_button_to_x11(1), 3)
        self.assertEqual(mac_button_to_x11(2), 2)

    def test_multidevice_crossing_and_debounce(self) -> None:
        ubu = ScreenInfo("U-SCR", "DELL U2720QM", True, False, 0, 0, 2048, 1152, 600, 340, False)
        book = ScreenInfo("U-SCR", "内建屏幕", True, True, 0, 0, 1512, 982, 301, 195, False)
        shared = {
            "rules": [
                {
                    "id": "r-book-ubu",
                    "aDevice": "book",
                    "aScreen": "U-SCR",
                    "aEdge": "right",
                    "bDevice": "ubu",
                    "bScreen": "U-SCR",
                    "offsetMM": 0.0,
                }
            ]
        }
        views = rule_views_from_shared(shared, "ubu")
        cmap = CrossingMap(views=views, local_screens=[ubu], remote_by_device={"book": [book]})
        hit = cmap.hit(2.0, 200.0, -1.0, 200.0)
        self.assertIsNotNone(hit)
        assert hit is not None
        self.assertEqual(hit.remote_device, "book")
        self.assertEqual(hit.remote_edge, "right")

        db = LeaveDebounce()
        self.assertFalse(db.feed(hit, 5.0, False, 0.10, None))
        self.assertFalse(db.feed(hit, 10.0, False, 0.30, None))
        self.assertTrue(db.feed(hit, 6.0, False, 0.31, outward_component(-6.0, 0.0, hit.local_edge)))
        self.assertGreaterEqual(beyond_edge(-10.0, 200.0, hit), 10.0)

    def test_state_and_avahi_parse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp))
            st = store.load()
            st.swap_cmd_ctrl = False
            store.save(st)
            st2 = store.load()
            self.assertEqual(st2.device_id, st.device_id)
            self.assertFalse(st2.swap_cmd_ctrl)

        rc = sanitize_ripple({"leaveSize": 9999, "leaveColors": ["bad", "#112233"]})
        self.assertEqual(rc["leaveSize"], 300.0)
        self.assertEqual(rc["leaveColors"], ["#112233"])

        line = '=;eno1;IPv4;MacKVM\\03228808056;_mackvm._tcp;local;mac.local;192.168.31.15;24810;"v=17.0" "name=Studio" "id=abc-123"'
        parsed = parse_avahi_browse_line(line)
        self.assertEqual(parsed, ("abc-123", "IPv4", "192.168.31.15", 24810))

    def test_dualstack_socket_accepts_ipv4_and_ipv6(self) -> None:
        async def probe() -> None:
            accepted = 0

            async def handle(_r: asyncio.StreamReader, w: asyncio.StreamWriter) -> None:
                nonlocal accepted
                accepted += 1
                w.close()
                await w.wait_closed()

            sock = _create_dualstack_socket(0)
            port = sock.getsockname()[1]
            server = await asyncio.start_server(handle, sock=sock)
            try:
                _r4, w4 = await asyncio.open_connection("127.0.0.1", port)
                w4.close()
                await w4.wait_closed()
                if sock.family == socket.AF_INET6:
                    _r6, w6 = await asyncio.open_connection("::1", port)
                    w6.close()
                    await w6.wait_closed()
                await asyncio.sleep(0.05)
                expected = 2 if sock.family == socket.AF_INET6 else 1
                self.assertEqual(accepted, expected)
            finally:
                server.close()
                await server.wait_closed()

        asyncio.run(probe())


if __name__ == "__main__":
    unittest.main(verbosity=2)
