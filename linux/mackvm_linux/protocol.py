"""MacKVM CPace pairing, ChaCha20-Poly1305 encrypted Link, and Avahi mDNS discovery."""

from __future__ import annotations

import asyncio
import atexit
import base64
import hashlib
import hmac
import json
import os
import secrets
import shutil
import socket
import struct
import time
from enum import IntEnum
from typing import Any, Callable

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import LINK_PORT, LINK_SERVICE_TYPE, PAIR_SERVICE_TYPE, VERSION
from .state import log


class Msg(IntEnum):
    HELLO = 1
    HEARTBEAT = 2
    ENTER = 3
    LEAVE = 4
    MOVE = 5
    BUTTON = 6
    EVENT = 7
    RELEASE = 8
    SETTINGS = 9
    UNPAIR = 10
    INFO = 11
    SCREENS = 12
    ALL_SCREENS = 13
    KEY = 14
    SCROLL = 15


# MARK: - Pure CPace Pairing Crypto (1:1 match with Sources/Pairing.swift)

MAX_PAIR_FAILURES = 5


def new_pair_code() -> str:
    return f"{secrets.randbelow(100_000_000):08d}"


def _lp(data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + data


def cpace_generator(code: str, nonce_c: bytes, nonce_i: bytes, id_c: str, id_i: str) -> bytes:
    h = hashlib.sha256()
    for part in (
        b"MacKVM-CPace-X25519-v1",
        code.encode("utf-8"),
        nonce_c,
        nonce_i,
        id_c.encode("utf-8"),
        id_i.encode("utf-8"),
    ):
        h.update(_lp(part))
    g = bytearray(h.digest())
    g[31] &= 0x7F
    return bytes(g)


def x25519_exchange(priv: X25519PrivateKey, pub_bytes: bytes) -> bytes:
    if len(pub_bytes) != 32:
        raise ValueError("invalid X25519 key length")
    pub = X25519PublicKey.from_public_bytes(pub_bytes)
    shared = priv.exchange(pub)
    if not any(shared):
        raise ValueError("invalid X25519 shared secret (low-order point)")
    return shared


def pairing_transcript(
    c_id: str,
    c_name: str,
    c_nonce: bytes,
    i_id: str,
    i_name: str,
    i_nonce: bytes,
    y_i: bytes,
    y_c: bytes,
) -> bytes:
    h = hashlib.sha256()
    h.update(_lp(b"MacKVM-pair-transcript-v1"))
    for part in (
        c_id.encode("utf-8"),
        c_name.encode("utf-8"),
        c_nonce,
        i_id.encode("utf-8"),
        i_name.encode("utf-8"),
        i_nonce,
        y_i,
        y_c,
    ):
        h.update(_lp(part))
    return h.digest()


def derive_pairing_keys(k: bytes, transcript: bytes) -> tuple[bytes, bytes, bytes]:
    def derive(info: bytes) -> bytes:
        return HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=transcript,
            info=info,
        ).derive(k)

    return (
        derive(b"MacKVM confirm controller v1"),
        derive(b"MacKVM confirm controlled v1"),
        derive(b"MacKVM long-term key v1"),
    )


def hmac_mac(key: bytes, transcript: bytes) -> bytes:
    return hmac.new(key, transcript, hashlib.sha256).digest()


def hmac_verify(mac_bytes: bytes, key: bytes, transcript: bytes) -> bool:
    return hmac.compare_digest(mac_bytes, hmac_mac(key, transcript))


def key_fingerprint(key: bytes) -> str:
    return hashlib.sha256(key).digest()[:4].hex()


def bonjour_name(s: str) -> str:
    out = []
    byte_len = 0
    for ch in s:
        b = ch.encode("utf-8")
        if byte_len + len(b) > 63:
            break
        out.append(ch)
        byte_len += len(b)
    return "".join(out) or "MacKVM"


def peer_ip_from_writer(writer: asyncio.StreamWriter) -> str | None:
    info = writer.get_extra_info("peername")
    if not info:
        return None
    host = str(info[0])
    if host.startswith("::ffff:"):
        return host[7:]
    if "%" in host:
        return host
    if host.lower().startswith("fe80:") and len(info) >= 4 and info[3]:
        try:
            return f"{host}%{socket.if_indextoname(int(info[3]))}"
        except OSError:
            return host
    return host


def _create_dualstack_socket(port: int) -> socket.socket:
    """Create a single dual-stack TCP socket accepting IPv4 and IPv6 on the same port."""
    if socket.has_ipv6:
        sock: socket.socket | None = None
        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            sock.bind(("::", port))
            sock.setblocking(False)
            return sock
        except OSError:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    sock.setblocking(False)
    return sock


# MARK: - Avahi Publish & Browse


class AvahiPublisher:
    def __init__(self) -> None:
        self._proc: asyncio.subprocess.Process | None = None
        atexit.register(self._cleanup_sync)

    def _cleanup_sync(self) -> None:
        if self._proc is not None and self._proc.returncode is None:
            try:
                self._proc.terminate()
            except Exception:
                pass

    async def start(self, name: str, service_type: str, port: int, dev_id: str, dev_name: str) -> None:
        await self.stop()
        exe = shutil.which("avahi-publish-service")
        if not exe:
            log("警告：找不到 avahi-publish-service，无法广播局域网服务")
            return
        args = [
            exe,
            bonjour_name(name),
            service_type,
            str(port),
            f"id={dev_id}",
            f"name={dev_name}",
            f"v={VERSION}",
        ]
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            log(f"局域网广播已启动：{service_type}（端口 {port}）")
        except Exception as exc:
            log(f"警告：启动 avahi-publish-service 失败：{exc}")

    async def stop(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is not None and proc.returncode is None:
            try:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=1.5)
                except asyncio.TimeoutError:
                    proc.kill()
                    await proc.wait()
            except Exception:
                pass


def parse_avahi_browse_line(line: str) -> tuple[str, str, str, int] | None:
    """Parse one resolved `avahi-browse -r -p -t` line into (dev_id, proto, addr_with_scope, port)."""
    if not line.startswith("=;"):
        return None
    parts = line.split(";")
    if len(parts) < 10:
        return None
    iface, proto, addr, port_str, txt = parts[1], parts[2], parts[7], parts[8], parts[9]
    if not addr or not port_str.isdigit():
        return None
    dev_id: str | None = None
    for tok in txt.split('" "'):
        tok = tok.strip().strip('"')
        if tok.startswith("id="):
            dev_id = tok[3:]
            break
    if not dev_id:
        return None
    if proto == "IPv6" and addr.lower().startswith("fe80:") and "%" not in addr and iface:
        addr = f"{addr}%{iface}"
    return (dev_id, proto, addr, int(port_str))


async def avahi_resolve_peer(peer_id: str, service_type: str = LINK_SERVICE_TYPE) -> tuple[str, int] | None:
    exe = shutil.which("avahi-browse")
    if not exe:
        return None
    try:
        proc = await asyncio.create_subprocess_exec(
            exe,
            "-r",
            "-p",
            "-t",
            service_type,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=4.0)
    except Exception:
        return None
    ipv4_match: tuple[str, int] | None = None
    ipv6_match: tuple[str, int] | None = None
    for line in stdout.decode("utf-8", errors="ignore").splitlines():
        parsed = parse_avahi_browse_line(line)
        if not parsed:
            continue
        did, proto, addr, port = parsed
        if did != peer_id:
            continue
        if proto == "IPv4" and ipv4_match is None:
            ipv4_match = (addr, port)
        elif proto == "IPv6" and ipv6_match is None:
            ipv6_match = (addr, port)
    return ipv4_match or ipv6_match


# MARK: - Encrypted Peer Framing (1:1 match with Sources/Peer.swift)


def seal_frame(key: bytes, msg_type: Msg, payload: bytes, session_id: int) -> bytes:
    plain = bytes([int(msg_type)]) + struct.pack(">Q", session_id) + payload
    nonce = os.urandom(12)
    ct = ChaCha20Poly1305(key).encrypt(nonce, plain, None)
    combined = nonce + ct
    return struct.pack(">I", len(combined)) + combined


def seal_session_frame(key: bytes, msg_type: Msg, peer_session: int, seq: int, payload: bytes) -> bytes:
    plain = bytes([int(msg_type)]) + struct.pack(">QQ", peer_session, seq) + payload
    nonce = os.urandom(12)
    ct = ChaCha20Poly1305(key).encrypt(nonce, plain, None)
    combined = nonce + ct
    return struct.pack(">I", len(combined)) + combined


def open_frame(key: bytes, combined: bytes) -> bytes:
    return ChaCha20Poly1305(key).decrypt(combined[:12], combined[12:], None)


# MARK: - PairInviter (Controlled side)


class PairInviter:
    def __init__(
        self,
        my_id: str,
        my_name: str,
        on_code_changed: Callable[[str, bool], None],
        on_paired: Callable[[dict[str, Any]], None],
    ) -> None:
        self.my_id = my_id
        self.my_name = my_name
        self.on_code_changed = on_code_changed
        self.on_paired = on_paired
        self.code = new_pair_code()
        self.failures = 0
        self.port = 0
        self._server: asyncio.AbstractServer | None = None
        self._publisher = AvahiPublisher()
        self._busy = False
        self._stopped = True

    async def start(self) -> None:
        self._stopped = False
        sock = _create_dualstack_socket(0)
        self.port = sock.getsockname()[1]
        self._server = await asyncio.start_server(self._handle_client, sock=sock)
        log(f"配对：开始等待主控方连接（端口 {self.port}，正在局域网广播 {PAIR_SERVICE_TYPE}）")
        await self._publisher.start(self.my_name, PAIR_SERVICE_TYPE, self.port, self.my_id, self.my_name)
        self.on_code_changed(self.code, False)

    async def stop(self) -> None:
        self._stopped = True
        await self._publisher.stop()
        if self._server is not None:
            self._server.close()
            try:
                await self._server.wait_closed()
            except Exception:
                pass
            self._server = None

    def regenerate_code(self) -> None:
        self.failures = 0
        self.code = new_pair_code()
        self.on_code_changed(self.code, False)
        log("配对：手动生成了新的配对码")

    async def _send_json(self, writer: asyncio.StreamWriter, obj: dict[str, Any]) -> None:
        body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        writer.write(struct.pack(">I", len(body)) + body)
        await writer.drain()

    async def _recv_json(self, reader: asyncio.StreamReader) -> dict[str, Any] | None:
        hdr = await asyncio.wait_for(reader.readexactly(4), timeout=10.0)
        (length,) = struct.unpack(">I", hdr)
        if length <= 0 or length > 65536:
            return None
        body = await asyncio.wait_for(reader.readexactly(length), timeout=10.0)
        obj = json.loads(body.decode("utf-8"))
        return obj if isinstance(obj, dict) else None

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self._busy or self._stopped:
            try:
                await self._send_json(writer, {"t": "busy"})
            except Exception:
                pass
            writer.close()
            return

        self._busy = True
        code_at_start = self.code
        try:
            m1 = await self._recv_json(reader)
            if not m1 or m1.get("t") != "hello":
                return
            c_id = str(m1.get("id") or "")
            c_name = str(m1.get("name") or "")
            c_laptop = bool(m1.get("laptop", False))
            c_nonce_b64 = m1.get("nonce")
            if not c_id or not isinstance(c_nonce_b64, str):
                return
            c_nonce = base64.b64decode(c_nonce_b64)
            if len(c_nonce) != 16:
                return

            i_nonce = os.urandom(16)
            secret = X25519PrivateKey.generate()
            g = cpace_generator(code_at_start, c_nonce, i_nonce, c_id, self.my_id)
            y_i = x25519_exchange(secret, g)
            log(f"配对：对方是「{c_name}」（{c_id}），等它提交配对码")
            await self._send_json(
                writer,
                {
                    "t": "hello",
                    "v": 1,
                    "id": self.my_id,
                    "name": self.my_name,
                    "laptop": False,
                    "platform": "linux",
                    "nonce": base64.b64encode(i_nonce).decode("ascii"),
                    "y": base64.b64encode(y_i).decode("ascii"),
                },
            )

            m2 = await self._recv_json(reader)
            if not m2 or m2.get("t") != "confirm":
                return
            y_c = base64.b64decode(str(m2.get("y") or ""))
            mac_c = base64.b64decode(str(m2.get("mac") or ""))
            if len(y_c) != 32 or len(mac_c) != 32:
                return

            tr = pairing_transcript(c_id, c_name, c_nonce, self.my_id, self.my_name, i_nonce, y_i, y_c)
            try:
                k = x25519_exchange(secret, y_c)
                confirm_c, confirm_i, long_term = derive_pairing_keys(k, tr)
                ok = hmac_verify(mac_c, confirm_c, tr)
            except Exception:
                ok = False

            if not ok:
                self.failures += 1
                if self.failures >= MAX_PAIR_FAILURES:
                    self.failures = 0
                    self.code = new_pair_code()
                    log(f"配对：对方连续 {MAX_PAIR_FAILURES} 次输错配对码，旧码作废，已换新码")
                    await self._send_json(writer, {"t": "wrong", "left": 0, "renewed": True})
                    self.on_code_changed(self.code, True)
                else:
                    left = MAX_PAIR_FAILURES - self.failures
                    log(f"配对：对方输入的配对码不对（还可再试 {left} 次）")
                    await self._send_json(writer, {"t": "wrong", "left": left, "renewed": False})
                return

            mac_i = hmac_mac(confirm_i, tr)
            await self._send_json(writer, {"t": "confirm", "mac": base64.b64encode(mac_i).decode("ascii")})
            try:
                await self._recv_json(reader)  # wait for "done" or EOF cleanly
            except Exception:
                pass

            addr = peer_ip_from_writer(writer)
            log(f"配对：配对码校验通过，与「{c_name}」配对成功（密钥指纹 {key_fingerprint(long_term)}）")
            result = {
                "peerID": c_id,
                "peerName": c_name,
                "peerIsLaptop": c_laptop,
                "keyBase64": base64.b64encode(long_term).decode("ascii"),
                "lastAddress": addr,
                "platform": m1.get("platform") or "macos",
            }
            self.on_paired(result)
        except Exception as exc:
            log(f"配对：本次握手结束（{exc}）")
        finally:
            self._busy = False
            try:
                writer.close()
            except Exception:
                pass


# MARK: - Encrypted Peer Session & LinkClient


class PeerSession:
    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        key: bytes,
        name: str,
        on_authenticated: Callable[["PeerSession"], None],
        on_message: Callable[["PeerSession", int, bytes], None],
        on_close: Callable[["PeerSession", str], None],
    ) -> None:
        self.reader = reader
        self.writer = writer
        self.key = key
        self.name = name
        self.on_authenticated = on_authenticated
        self.on_message = on_message
        self.on_close = on_close

        self.authenticated = False
        self.closed = False
        self.my_session = secrets.randbits(63) + 1
        self.peer_session: int | None = None
        self.send_seq = 0
        self.recv_seq = 0
        self.last_recv = time.monotonic()
        self._hb_count = 0
        self._hb_window_start = time.monotonic()
        self._first_report = True
        self._tasks: list[asyncio.Task[Any]] = []
        self.remote_ip = peer_ip_from_writer(writer)

    def start(self) -> None:
        self.last_recv = time.monotonic()
        self._send_raw(seal_frame(self.key, Msg.HELLO, b"", self.my_session))
        self._tasks.append(asyncio.create_task(self._read_loop()))
        self._tasks.append(asyncio.create_task(self._heartbeat_loop()))

    def _send_raw(self, frame: bytes) -> None:
        if self.closed:
            return
        try:
            self.writer.write(frame)
        except Exception as exc:
            self.close(f"发送出错：{exc}")

    def send(self, msg_type: int, payload: bytes = b"") -> None:
        if self.closed or self.peer_session is None:
            return
        self.send_seq += 1
        frame = seal_session_frame(self.key, Msg(msg_type), self.peer_session, self.send_seq, payload)
        self._send_raw(frame)

    async def _read_loop(self) -> None:
        try:
            while not self.closed:
                hdr = await self.reader.readexactly(4)
                (length,) = struct.unpack(">I", hdr)
                if length < 29 or length > (1 << 20):
                    self.close(f"帧长度异常（{length} 字节）")
                    return
                frame = await self.reader.readexactly(length)
                try:
                    plain = open_frame(self.key, frame)
                except Exception:
                    self.close("解密失败：配对密钥不一致或数据被篡改")
                    return
                self._handle_plain(plain)
        except asyncio.IncompleteReadError:
            self.close("对端关闭了连接")
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            self.close(f"接收出错：{exc}")

    def _handle_plain(self, plain: bytes) -> None:
        if not plain:
            self.close("收到空消息")
            return
        t = plain[0]
        if t == Msg.HELLO:
            if self.peer_session is not None or len(plain) < 9:
                self.close("hello 消息不合法或重复")
                return
            (self.peer_session,) = struct.unpack(">Q", plain[1:9])
            self.send(Msg.HEARTBEAT)
            return
        if len(plain) < 17:
            self.close("消息太短")
            return
        sess, seq = struct.unpack(">QQ", plain[1:17])
        if sess != self.my_session:
            self.close("会话号不符，断开")
            return
        if seq <= self.recv_seq:
            self.close("序号未递增，断开")
            return
        self.recv_seq = seq
        self.last_recv = time.monotonic()
        if not self.authenticated:
            self.authenticated = True
            self._hb_window_start = time.monotonic()
            self._hb_count = 0
            self._first_report = True
            log(f"对端已连上并通过密钥校验：{self.name}")
            self.on_authenticated(self)
        if t == Msg.HEARTBEAT:
            self._hb_count += 1
            return
        self.on_message(self, t, plain[17:])

    async def _heartbeat_loop(self) -> None:
        try:
            while not self.closed:
                await asyncio.sleep(1.0)
                if self.closed:
                    return
                if self.peer_session is not None:
                    self.send(Msg.HEARTBEAT)
                now = time.monotonic()
                if now - self.last_recv > 3.0:
                    self.close("心跳超时（超过 3 秒没收到对端消息）" if self.authenticated else "握手超时")
                    return
                w = now - self._hb_window_start
                if self.authenticated and w >= (10.0 if self._first_report else 60.0):
                    self._first_report = False
                    log(f"心跳正常：过去 {int(w)} 秒收到 {self._hb_count} 个心跳（{self.name}）")
                    self._hb_count = 0
                    self._hb_window_start = now
        except asyncio.CancelledError:
            pass

    def close(self, reason: str) -> None:
        if self.closed:
            return
        self.closed = True
        for t in self._tasks:
            t.cancel()
        self._tasks.clear()
        try:
            self.writer.close()
        except Exception:
            pass
        if self.authenticated:
            log(f"连接断开（{self.name}）：{reason}")
        self.on_close(self, reason)


class LinkClient:
    def __init__(
        self,
        my_id: str,
        my_name: str,
        peer_id: str,
        peer_name: str,
        key: bytes,
        last_address: str | None,
        on_authenticated: Callable[[PeerSession], None],
        on_message: Callable[[int, bytes], None],
        on_disconnected: Callable[[], None],
        on_address_learned: Callable[[str], None],
        port: int = LINK_PORT,
    ) -> None:
        self.my_id = my_id
        self.my_name = my_name
        self.peer_id = peer_id
        self.peer_name = peer_name
        self.key = key
        self.last_address = last_address
        self.on_authenticated = on_authenticated
        self.on_message = on_message
        self.on_disconnected = on_disconnected
        self.on_address_learned = on_address_learned
        self.port = port

        self.active: PeerSession | None = None
        self._pending: set[PeerSession] = set()
        self._server: asyncio.AbstractServer | None = None
        self._publisher = AvahiPublisher()
        self._dial_task: asyncio.Task[Any] | None = None
        self._stopped = True
        self._attempt = 0

    @property
    def is_initiator(self) -> bool:
        return self.my_id < self.peer_id

    async def start(self) -> None:
        self._stopped = False
        log(
            f"连接：开始{'主动寻找并连接对方' if self.is_initiator else '等待对方连接'}"
            f"（本机 ID {self.my_id[:8]}，对方 ID {self.peer_id[:8]}，上次地址 {self.last_address or '无'}）"
        )
        sock = _create_dualstack_socket(self.port)
        self._server = await asyncio.start_server(self._accept, sock=sock)
        await self._publisher.start(f"MacKVM {self.my_id[:8]}", LINK_SERVICE_TYPE, self.port, self.my_id, self.my_name)
        if self.is_initiator:
            self._dial_task = asyncio.create_task(self._dial_loop())

    async def stop(self) -> None:
        self._stopped = True
        if self._dial_task is not None:
            self._dial_task.cancel()
            self._dial_task = None
        await self._publisher.stop()
        if self._server is not None:
            self._server.close()
            try:
                await self._server.wait_closed()
            except Exception:
                pass
            self._server = None
        sessions = list(self._pending) + ([self.active] if self.active else [])
        self._pending.clear()
        self.active = None
        for s in sessions:
            s.close("本机停止连接")

    def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self._stopped:
            writer.close()
            return
        sock = writer.get_extra_info("socket")
        if sock is not None:
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except Exception:
                pass
        sess = PeerSession(
            reader,
            writer,
            self.key,
            f"对方 {peer_ip_from_writer(writer) or ''}".strip(),
            self._peer_authed,
            self._peer_msg,
            self._peer_closed,
        )
        self._pending.add(sess)
        sess.start()

    async def _dial_loop(self) -> None:
        fail_streak = 0
        try:
            while not self._stopped:
                if self.active is None:
                    targets: list[tuple[str, int, str]] = []
                    resolved = await avahi_resolve_peer(self.peer_id)
                    if resolved:
                        targets.append((resolved[0], resolved[1], f"局域网发现的 {resolved[0]}:{resolved[1]}"))
                    if self.last_address:
                        targets.append((self.last_address, self.port, f"上次的地址 {self.last_address}:{self.port}"))
                    if targets:
                        host, port, desc = targets[self._attempt % len(targets)]
                        self._attempt += 1
                        if fail_streak < 3 or fail_streak % 30 == 0:
                            log(f"连接：正在连接{desc}（连续失败 {fail_streak} 次）")
                        ok = await self._dial_once(host, port, desc)
                        if ok:
                            fail_streak = 0
                        else:
                            fail_streak += 1
                    else:
                        if fail_streak % 30 == 0:
                            log("连接：还没在局域网发现对方，也没有上次的地址，继续等")
                        fail_streak += 1
                await asyncio.sleep(2.0)
        except asyncio.CancelledError:
            pass

    async def _dial_once(self, host: str, port: int, desc: str) -> bool:
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=5.0)
        except Exception:
            return False
        sock = writer.get_extra_info("socket")
        if sock is not None:
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except Exception:
                pass
        done = asyncio.get_running_loop().create_future()

        def authed(s: PeerSession) -> None:
            self._peer_authed(s)
            if not done.done():
                done.set_result(True)

        def closed(s: PeerSession, reason: str) -> None:
            self._peer_closed(s, reason)
            if not done.done():
                done.set_result(False)

        sess = PeerSession(reader, writer, self.key, f"对方（{desc}）", authed, self._peer_msg, closed)
        self._pending.add(sess)
        sess.start()
        try:
            return await asyncio.wait_for(done, timeout=5.0)
        except asyncio.TimeoutError:
            sess.close("握手超时")
            return False

    def _peer_authed(self, sess: PeerSession) -> None:
        self._pending.discard(sess)
        old = self.active
        self.active = sess
        if old is not None and old is not sess:
            old.close("被新连接替换")
        if sess.remote_ip and sess.remote_ip != self.last_address:
            self.last_address = sess.remote_ip
            self.on_address_learned(sess.remote_ip)
        self.on_authenticated(sess)

    def _peer_msg(self, sess: PeerSession, msg_type: int, payload: bytes) -> None:
        if sess is self.active:
            self.on_message(msg_type, payload)

    def _peer_closed(self, sess: PeerSession, _reason: str) -> None:
        self._pending.discard(sess)
        if sess is self.active:
            self.active = None
            self.on_disconnected()
