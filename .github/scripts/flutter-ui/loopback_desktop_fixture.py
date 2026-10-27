"""Ephemeral SSH/SFTP peer for the real Linux desktop acceptance test.

It never runs a shell or a received command. Only a newly-created temporary
filesystem is exposed over SFTP, and the listening socket is loopback-only.
Runtime files contain generated fixture credentials and are NOT CI artifacts.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import signal
import socket
import threading
import time

import paramiko

MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_INPUT_BYTES = 1024 * 1024


def fixture_path(root: Path, remote: str) -> Path:
    """Map a remote POSIX name into the fixture; never follow an escape."""
    if not isinstance(remote, str) or '\x00' in remote:
        raise OSError(errno.EACCES, 'invalid fixture path')
    parts = PurePosixPath(remote).parts
    if '..' in parts:
        raise OSError(errno.EACCES, 'parent traversal is not allowed')
    relative = [part for part in parts if part not in ('/', '.', '')]
    candidate = root.joinpath(*relative).resolve()
    if not candidate.is_relative_to(root):
        raise OSError(errno.EACCES, 'path leaves the fixture')
    return candidate


class BoundedHandle(paramiko.SFTPHandle):
    def write(self, offset, data):
        if offset < 0 or offset + len(data) > MAX_FILE_BYTES:
            return paramiko.SFTP_PERMISSION_DENIED
        return super().write(offset, data)


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *, root):
        super().__init__(server)
        self.root = root

    def _path(self, path):
        return fixture_path(self.root, path)

    def canonicalize(self, path):
        try:
            relative = self._path(path).relative_to(self.root).as_posix()
            return '/' if relative == '.' else '/' + relative
        except OSError:
            return '/'

    @staticmethod
    def _error(error):
        return paramiko.SFTPServer.convert_errno(error.errno or errno.EIO)

    def list_folder(self, path):
        try:
            result = []
            for child in sorted(self._path(path).iterdir()):
                if child.is_symlink():
                    continue
                value = paramiko.SFTPAttributes.from_stat(child.stat())
                value.filename = child.name
                result.append(value)
            return result
        except OSError as error:
            return self._error(error)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self._path(path).stat())
        except OSError as error:
            return self._error(error)

    lstat = stat

    def open(self, path, flags, attr):
        # O_APPEND ignores the SFTP offset, defeating an offset-only size cap.
        if flags & os.O_APPEND:
            return paramiko.SFTP_PERMISSION_DENIED
        try:
            file = self._path(path)
            if file == self.root:
                raise OSError(errno.EACCES, 'cannot open fixture root')
            fd = os.open(file, flags, 0o600)
            writable = flags & (os.O_WRONLY | os.O_RDWR)
            stream = os.fdopen(fd, 'r+b' if flags & os.O_RDWR else 'wb' if writable else 'rb')
            handle = BoundedHandle(flags)
            if not (flags & os.O_WRONLY):
                handle.readfile = stream
            if writable:
                handle.writefile = stream
            return handle
        except OSError as error:
            return self._error(error)

    def mkdir(self, path, attr):
        try:
            self._path(path).mkdir(mode=0o700)
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)

    def remove(self, path):
        try:
            self._path(path).unlink()
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)

    def rmdir(self, path):
        try:
            target = self._path(path)
            if target == self.root:
                raise OSError(errno.EACCES, 'cannot remove fixture root')
            target.rmdir()
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)


class Server(paramiko.ServerInterface):
    def __init__(self, peer):
        self.peer = peer

    def get_allowed_auths(self, username):
        return 'password'

    def check_auth_password(self, username, password):
        return (paramiko.AUTH_SUCCESSFUL if username == 'fixture'
                and secrets.compare_digest(password, self.peer.password)
                else paramiko.AUTH_FAILED)

    def check_channel_request(self, kind, channel_id):
        return (paramiko.OPEN_SUCCEEDED if kind == 'session'
                else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED)

    def check_channel_pty_request(self, channel, term, width, height, pw, ph, modes):
        return 1 <= width <= 10000 and 1 <= height <= 10000

    def check_channel_window_change_request(self, channel, width, height, pw, ph):
        return 1 <= width <= 10000 and 1 <= height <= 10000

    def check_channel_shell_request(self, channel):
        threading.Thread(target=self.peer.terminal, args=(channel,), daemon=True).start()
        return True

    def check_channel_exec_request(self, channel, command):
        # Resource probes may request exec. Never evaluate any command on the
        # runner; the UI should display unavailable, not invented system data.
        def reject():
            time.sleep(0.01)
            try:
                channel.send_exit_status(127)
            finally:
                channel.close()
        threading.Thread(target=reject, daemon=True).start()
        return True


class Peer:
    def __init__(self, runtime: Path):
        self.runtime = runtime
        self.root = runtime / 'remote-files'
        self.root.mkdir(mode=0o700)
        (self.root / 'fixture.txt').write_text('fixture file\n中文\n', encoding='utf-8')
        (self.root / 'folder').mkdir(mode=0o700)
        self.password = secrets.token_urlsafe(32)
        self.key = paramiko.RSAKey.generate(2048)
        self.stop = threading.Event()
        self.transports = []
        self.input_lock = threading.Lock()
        self.received = 0
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(8)
        self.listener.settimeout(1)
        connection = {'host': '127.0.0.1', 'port': self.listener.getsockname()[1],
                      'username': 'fixture', 'password': self.password,
                      'host_key': f'{self.key.get_name()} {self.key.get_base64()}'}
        path = runtime / 'connection.json'
        with path.open('x', encoding='utf-8') as output:
            os.chmod(path, 0o600)
            json.dump(connection, output)
        # The ready signal contains no password/private key.
        (runtime / 'ready.json').write_text(json.dumps({'port': connection['port']}))

    def serve(self, connection):
        transport = paramiko.Transport(connection)
        self.transports.append(transport)
        transport.add_server_key(self.key)
        transport.set_subsystem_handler('sftp', paramiko.SFTPServer, Files, root=self.root)
        try:
            transport.start_server(server=Server(self))
            channels = []
            while transport.is_active() and not self.stop.wait(0.1):
                # Keep accepted channels referenced; shell/SFTP owns their I/O.
                # A long-lived PTY must not block concurrent SFTP/probe channels.
                channel = transport.accept(0.2)
                if channel is not None:
                    channels.append(channel)
                channels = [item for item in channels if not item.closed]
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()

    def terminal(self, channel):
        channel.settimeout(1)
        try:
            channel.sendall('Fixture terminal\r\nASCII 中🙂 e\u0301 selection\r\n\x1b[?2004hfixture> '.encode())
            while not self.stop.is_set():
                try:
                    value = channel.recv(65536)
                except socket.timeout:
                    continue
                if not value:
                    return
                with self.input_lock:
                    self.received += len(value)
                    if self.received > MAX_INPUT_BYTES:
                        return
                    # Only synthetic test input reaches this fixture. This file
                    # remains private runtime state, never an uploaded artifact.
                    with (self.runtime / 'received.jsonl').open('a', encoding='utf-8') as output:
                        os.chmod(output.name, 0o600)
                        output.write(json.dumps({'hex': value.hex(), 'sha256': hashlib.sha256(value).hexdigest()}) + '\n')
                channel.sendall(value)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            channel.close()

    def run(self):
        try:
            while not self.stop.is_set():
                try:
                    connection, address = self.listener.accept()
                except socket.timeout:
                    continue
                if address[0] != '127.0.0.1':
                    connection.close()
                    continue
                threading.Thread(target=self.serve, args=(connection,), daemon=True).start()
        finally:
            self.listener.close()
            for transport in self.transports:
                transport.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True, type=Path)
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    runtime.mkdir(mode=0o700, parents=False, exist_ok=False)
    peer = Peer(runtime)
    signal.signal(signal.SIGTERM, lambda *_: peer.stop.set())
    signal.signal(signal.SIGINT, lambda *_: peer.stop.set())
    peer.run()


if __name__ == '__main__':
    main()
