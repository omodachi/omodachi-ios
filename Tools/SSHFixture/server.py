#!/usr/bin/env python3
"""A loopback-only SSH/PTTY echo fixture. Never executes commands or reads files.

The deterministic fixture-only keys are intentionally public test material.
They must never be authorized on any real host. This server binds 127.0.0.1,
accepts only the synthetic omodachi-test key, and performs no subprocess calls.
"""
import argparse
import asyncio
import signal
import os
import fcntl
import struct
import termios
import tty

import asyncssh
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def test_key(byte: int):
    key = Ed25519PrivateKey.from_private_bytes(bytes([byte]) * 32)
    return asyncssh.import_private_key(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.NoEncryption(),
    ))


HOST_KEY = test_key(0x48)
CLIENT_KEY = test_key(0x4F)


class EchoSession(asyncssh.SSHServerSession):
    def __init__(self):
        self.channel = None
        self.size = (80, 24, 0, 0)
        self.master = self.slave = None

    def connection_made(self, channel):
        self.channel = channel

    def pty_requested(self, term_type, term_size, term_modes):
        self.size = term_size
        self.master, self.slave = os.openpty()
        tty.setraw(self.slave)
        os.set_blocking(self.master, False)
        os.set_blocking(self.slave, False)
        self.set_window_size(*term_size)
        return True

    def shell_requested(self):
        return True

    def session_started(self):
        if self.master is None:
            self.channel.exit(1)
            return
        loop = asyncio.get_running_loop()
        loop.add_reader(self.master, self.read_master)
        loop.add_reader(self.slave, self.echo_slave)
        os.write(self.slave, b"OMODACHI_FIXTURE_READY\r\n")

    def read_master(self):
        try:
            self.channel.write(os.read(self.master, 65536))
        except (BlockingIOError, OSError):
            pass

    def echo_slave(self):
        try:
            data = os.read(self.slave, 65536)
            os.write(self.slave, data)
        except (BlockingIOError, OSError):
            pass

    def set_window_size(self, width, height, pixwidth, pixheight):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, pixwidth, pixheight))
        actual = struct.unpack("HHHH", fcntl.ioctl(self.slave, termios.TIOCGWINSZ, bytes(8)))
        self.size = (actual[1], actual[0], actual[2], actual[3])

    def terminal_size_changed(self, width, height, pixwidth, pixheight):
        if self.slave is None:
            return
        self.set_window_size(width, height, pixwidth, pixheight)
        os.write(self.slave, f"\r\nOMODACHI_SIZE={self.size[0]}x{self.size[1]}\r\n".encode())

    def data_received(self, data, datatype):
        # Raw echo proves the transport preserves UTF-8 and escape bytes.
        # No input is parsed as a command, logged, persisted or executed.
        if self.master is not None:
            os.write(self.master, data)

    def connection_lost(self, exc):
        loop = asyncio.get_running_loop()
        for fd in (self.master, self.slave):
            if fd is not None:
                loop.remove_reader(fd)
                os.close(fd)
        self.master = self.slave = None

    def eof_received(self):
        self.channel.exit(0)
        return False


class EchoServer(asyncssh.SSHServer):
    def begin_auth(self, username):
        return True

    def public_key_auth_supported(self):
        return True

    def validate_public_key(self, username, key):
        return username == "omodachi-test" and key == CLIENT_KEY.convert_to_public()

    def session_requested(self):
        return EchoSession()


async def main(port):
    server = await asyncssh.create_server(
        EchoServer, "127.0.0.1", port,
        server_host_keys=[HOST_KEY], encoding=None,
        line_editor=False,
    )
    print(f"Omodachi synthetic SSH fixture listening on 127.0.0.1:{port}", flush=True)
    done = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, done.set)
    await done.wait()
    server.close()
    await server.wait_closed()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=22222)
    args = parser.parse_args()
    asyncio.run(main(args.port))
