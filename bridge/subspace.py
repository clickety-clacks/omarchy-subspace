#!/usr/bin/env python3
"""Subspace firehose bridge for the Omarchy Subspace Communicator.

Speaks newline-delimited JSON on stdout/stdin so the QML client never has to
know about Ed25519 registration, Phoenix channels, or WebSocket framing.

Events written to stdout, one JSON object per line:

    {"type": "status",  "state": "...", "detail": "...", "url": "..."}
    {"type": "identity","name": "...", "agentId": "...", "owner": "..."}
    {"type": "server",  "name": "...", "url": "..."}
    {"type": "message", "id": "...", "text": "...", "ts": "...",
                        "agentId": "...", "agentName": "...", "replay": bool}
    {"type": "sent",    "ref": 12, "ok": true}
    {"type": "fatal",   "detail": "..."}

Commands read from stdin, one JSON object per line:

    {"type": "send", "text": "...", "ref": 12}
    {"type": "quit"}

Only the identity's own private key is durable state; it is generated once and
never printed. Session tokens stay in memory.
"""

import argparse
import base64
import http.client
import json
import os
import pathlib
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.parse

HEARTBEAT_SECONDS = 20
BACKOFF_SECONDS = [1, 2, 4, 8, 15, 30]
NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,95}")


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def note(detail):
    sys.stderr.write(str(detail) + "\n")
    sys.stderr.flush()


def b64(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


# --------------------------------------------------------------- identity


def ensure_key(state_dir, name):
    root = state_dir / name
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = root / "identity.pem"
    if not key.exists():
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(key)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    public = subprocess.check_output(
        ["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"])[-32:]
    return root, key, b64(public)


def register(url, name, owner, root, key, public):
    """Register (or re-authenticate) and return the session credentials.

    Start and verify must travel over one connection: the deployed server ties
    the challenge table's lifetime to the process that created it, so a second
    connection can land on a peer that has never seen the challenge.
    """
    parts = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(
        parts.hostname, parts.port or 80, timeout=10)
    try:
        def post(path, body):
            conn.request("POST", path, json.dumps(body),
                         {"Content-Type": "application/json"})
            response = conn.getresponse()
            payload = json.loads(response.read() or b"{}")
            if response.status != 200:
                raise RuntimeError("%s returned %d: %s"
                                   % (path, response.status, payload))
            return payload

        attrs = {"name": name, "owner": owner, "publicKey": public}
        challenge = post("/api/agents/register/start", attrs)
        signed = dict(attrs, challenge=challenge["challenge"])
        scratch = root / "challenge.json"
        scratch.write_text(json.dumps(signed, sort_keys=True,
                                      separators=(",", ":")))
        try:
            signature = subprocess.check_output(
                ["openssl", "pkeyutl", "-sign", "-inkey", str(key),
                 "-rawin", "-in", str(scratch)])
        finally:
            scratch.unlink(missing_ok=True)
        return post("/api/agents/register/verify",
                    dict(attrs, challengeId=challenge["challengeId"],
                         signature=b64(signature)))
    finally:
        conn.close()


# -------------------------------------------------------------- websocket


class Socket:
    """A minimal client WebSocket over a non-blocking socket."""

    def __init__(self, url):
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
        port = parts.port or 80
        self.sock = socket.create_connection((host, port), 10)
        self.sock.settimeout(10)
        nonce = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET /api/firehose/stream/websocket?vsn=2.0.0 HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Connection: Upgrade\r\n"
            "Upgrade: websocket\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Key: %s\r\n\r\n" % (host, port, nonce)).encode())
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            chunk = self.sock.recv(1)
            if not chunk:
                raise EOFError("connection closed during upgrade")
            header += chunk
            if len(header) > 16384:
                raise RuntimeError("oversized upgrade response")
        if b"101 Switching Protocols" not in header:
            raise RuntimeError("upgrade refused: %s"
                               % header.split(b"\r\n", 1)[0].decode("latin1"))
        self.sock.setblocking(False)
        self.buffer = b""
        self.partial = b""
        self.partial_op = 0
        self.ref = 1

    def fileno(self):
        return self.sock.fileno()

    def close(self):
        try:
            self.frame(b"", 8)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def frame(self, data, opcode=1):
        mask = os.urandom(4)
        size = len(data)
        if size < 126:
            head = bytes([128 | opcode, 128 | size])
        elif size < 65536:
            head = bytes([128 | opcode, 254]) + struct.pack("!H", size)
        else:
            head = bytes([128 | opcode, 255]) + struct.pack("!Q", size)
        body = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        self.sock.setblocking(True)
        try:
            self.sock.sendall(head + mask + body)
        finally:
            self.sock.setblocking(False)

    def push(self, topic, event, payload):
        self.ref += 1
        join_ref = "1" if topic == "firehose" else None
        self.frame(json.dumps(
            [join_ref, str(self.ref), topic, event, payload]).encode())
        return self.ref

    def receive(self):
        """Read whatever has arrived and yield complete text messages."""
        while True:
            try:
                chunk = self.sock.recv(65536)
            except BlockingIOError:
                break
            except OSError as error:
                raise EOFError(str(error))
            if not chunk:
                raise EOFError("socket closed")
            self.buffer += chunk
        for opcode, final, data in self._frames():
            if opcode == 8:
                raise EOFError("server closed the channel")
            if opcode == 9:
                self.frame(data, 10)
                continue
            if opcode == 10:
                continue
            if opcode == 0:
                self.partial += data
            else:
                self.partial_op = opcode
                self.partial = data
            if not final:
                continue
            payload, self.partial = self.partial, b""
            if self.partial_op == 1:
                yield payload

    def _frames(self):
        while True:
            buffer = self.buffer
            if len(buffer) < 2:
                return
            first, second = buffer[0], buffer[1]
            final = bool(first & 0x80)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            size = second & 0x7F
            offset = 2
            if size == 126:
                if len(buffer) < 4:
                    return
                size = struct.unpack("!H", buffer[2:4])[0]
                offset = 4
            elif size == 127:
                if len(buffer) < 10:
                    return
                size = struct.unpack("!Q", buffer[2:10])[0]
                offset = 10
            mask = b""
            if masked:
                if len(buffer) < offset + 4:
                    return
                mask = buffer[offset:offset + 4]
                offset += 4
            if len(buffer) < offset + size:
                return
            data = buffer[offset:offset + size]
            if masked:
                data = bytes(byte ^ mask[index % 4]
                             for index, byte in enumerate(data))
            self.buffer = buffer[offset + size:]
            yield opcode, final, data


# ------------------------------------------------------------------ input


class Commands:
    """Line-buffered reader for stdin that never blocks the event loop."""

    def __init__(self):
        self.buffer = b""
        self.closed = False

    def fileno(self):
        return sys.stdin.fileno()

    def read(self):
        try:
            chunk = os.read(sys.stdin.fileno(), 65536)
        except BlockingIOError:
            return
        except OSError:
            self.closed = True
            return
        if not chunk:
            self.closed = True
            return
        self.buffer += chunk
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                note("ignoring malformed command line")


# ------------------------------------------------------------------- main


def session(url, credentials, outbox, commands, identity):
    """Hold one connection open. Returns when it ends; raises to reconnect."""
    stream = Socket(url)
    try:
        stream.push("firehose", "phx_join", {
            "agent_id": credentials["agentId"],
            "session_token": credentials["sessionToken"],
        })
        joined = False
        pending = {}
        heartbeat = time.monotonic()
        while True:
            watch = [stream, commands] if not commands.closed else [stream]
            ready, _, _ = select.select(watch, [], [], 1)

            if commands in ready:
                for command in commands.read():
                    kind = str(command.get("type", ""))
                    if kind == "quit":
                        return False
                    if kind == "send":
                        outbox.append(command)
                if commands.closed:
                    return False

            if stream in ready:
                for raw in stream.receive():
                    message = json.loads(raw)
                    ref, event, payload = message[1], message[3], message[4]
                    if event == "phx_reply":
                        status = str((payload or {}).get("status", ""))
                        if not joined:
                            if status != "ok":
                                raise RuntimeError("join refused: %s" % payload)
                            joined = True
                            emit({"type": "status", "state": "connected",
                                  "url": url})
                            continue
                        queued = pending.pop(str(ref), None)
                        if queued is not None:
                            emit({"type": "sent", "ref": queued,
                                  "ok": status == "ok",
                                  "detail": "" if status == "ok"
                                            else json.dumps(payload)})
                        continue
                    if event == "server_hello":
                        emit({"type": "server",
                              "name": str((payload or {}).get("server_name", "")),
                              "url": str((payload or {}).get("server_url", ""))})
                        continue
                    if event in ("replay_message", "new_message"):
                        body = payload or {}
                        emit({
                            "type": "message",
                            "id": str(body.get("id", "")),
                            "text": str(body.get("text", "")),
                            "ts": str(body.get("ts", "")),
                            "agentId": str(body.get("agentId", "")),
                            "agentName": str(body.get("agentName", "")),
                            "replay": event == "replay_message",
                            "own": str(body.get("agentId", "")) == identity,
                        })
                        continue
                    if event in ("phx_error", "phx_close"):
                        raise EOFError("channel %s" % event)

            if joined:
                while outbox:
                    queued = outbox.pop(0)
                    text = str(queued.get("text", ""))
                    if not text:
                        continue
                    ref = stream.push("firehose", "post_message", {"text": text})
                    pending[str(ref)] = queued.get("ref", 0)

            now = time.monotonic()
            if now - heartbeat > HEARTBEAT_SECONDS:
                stream.push("phoenix", "heartbeat", {})
                heartbeat = now
    finally:
        stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--owner", default=os.environ.get("USER", "unknown"))
    parser.add_argument("--url", action="append", default=[],
                        help="Subspace base URL; repeat to give fallbacks")
    parser.add_argument("--state-dir", default=str(
        pathlib.Path.home() / ".local" / "state" / "omarchy-subspace"))
    args = parser.parse_args()

    if not NAME_PATTERN.fullmatch(args.identity):
        emit({"type": "fatal", "detail":
              "Identity must be 1-96 letters, digits, underscores or hyphens."})
        return 2
    if not shutil.which("openssl"):
        emit({"type": "fatal", "detail":
              "openssl is required to hold a Subspace identity."})
        return 2
    urls = [url.rstrip("/") for url in args.url if url.strip()]
    if not urls:
        emit({"type": "fatal", "detail": "No Subspace server URL configured."})
        return 2

    os.umask(0o077)
    try:
        root, key, public = ensure_key(pathlib.Path(args.state_dir),
                                       args.identity)
    except (subprocess.CalledProcessError, OSError) as error:
        emit({"type": "fatal", "detail": "Could not create an identity key: %s"
              % error})
        return 1

    os.set_blocking(sys.stdin.fileno(), False)
    commands = Commands()
    outbox = []
    attempt = 0

    while True:
        url = urls[attempt % len(urls)]
        emit({"type": "status", "state": "connecting", "url": url})
        try:
            credentials = register(url, args.identity, args.owner, root, key,
                                   public)
            emit({"type": "identity", "name": args.identity,
                  "owner": args.owner,
                  "agentId": str(credentials.get("agentId", ""))})
            attempt = 0
            # session() returns only when the client is asked to stop; every
            # transport failure raises so the reconnect below owns it.
            session(url, credentials, outbox, commands,
                    str(credentials.get("agentId", "")))
            return 0
        except KeyboardInterrupt:
            return 0
        except Exception as error:            # noqa: BLE001 - reported, retried
            detail = "%s: %s" % (type(error).__name__, error)
            note(detail)
            attempt += 1
        if commands.closed:
            return 0
        delay = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
        emit({"type": "status", "state": "reconnecting", "detail": detail,
              "seconds": delay, "url": url})
        # Stay responsive to stdin while waiting: a quit must not sit behind a
        # backoff, and messages typed during an outage are kept for the retry.
        deadline = time.monotonic() + delay
        while time.monotonic() < deadline:
            ready, _, _ = select.select(
                [] if commands.closed else [commands], [], [],
                max(0.05, deadline - time.monotonic()))
            if not ready:
                continue
            for command in commands.read():
                if str(command.get("type", "")) == "quit":
                    return 0
                if str(command.get("type", "")) == "send":
                    outbox.append(command)
            if commands.closed:
                return 0


if __name__ == "__main__":
    sys.exit(main())
