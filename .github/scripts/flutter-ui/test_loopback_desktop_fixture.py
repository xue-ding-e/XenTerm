"""Synthetic-only fixture admission checks; not Flutter application tests."""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest

import paramiko

from loopback_desktop_fixture import MAX_FILE_BYTES, Peer, fixture_path


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xenterm-ui-fixture-test-')
        self.root = Path(self.temp.name).resolve()
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.peer = Peer(self.runtime)
        self.thread = threading.Thread(target=self.peer.run, daemon=True)
        self.thread.start()
        self.client = paramiko.SSHClient()
        port = self.peer.listener.getsockname()[1]
        self.client.get_host_keys().add(f'[127.0.0.1]:{port}', self.peer.key.get_name(), self.peer.key)
        self.client.set_missing_host_key_policy(paramiko.RejectPolicy())
        self.client.connect('127.0.0.1', port=port, username='fixture', password=self.peer.password,
                            look_for_keys=False, allow_agent=False, timeout=5, auth_timeout=5,
                            banner_timeout=5, channel_timeout=5)

    def tearDown(self):
        self.client.close()
        self.peer.stop.set()
        self.thread.join(3)
        self.assertFalse(self.thread.is_alive(), 'fixture did not stop within its budget')
        self.temp.cleanup()

    def test_listener_and_runtime_are_isolated(self):
        self.assertEqual(self.peer.listener.getsockname()[0], '127.0.0.1')
        connection = json.loads((self.runtime / 'connection.json').read_text())
        self.assertEqual(connection['username'], 'fixture')
        self.assertEqual((self.runtime / 'connection.json').stat().st_mode & 0o777, 0o600)
        self.assertNotIn('password', json.loads((self.runtime / 'ready.json').read_text()))

    def test_canonicalize_preserves_dotfiles_and_dot_directories(self):
        (self.peer.root / '.hidden').write_text('synthetic hidden file')
        (self.peer.root / '.config').mkdir()
        (self.peer.root / '.config' / 'file').write_text('synthetic config')
        with self.client.open_sftp() as sftp:
            self.assertEqual(sftp.normalize('.'), '/')
            self.assertEqual(sftp.normalize('/'), '/')
            self.assertEqual(sftp.normalize('/.hidden'), '/.hidden')
            self.assertEqual(sftp.normalize('.config/file'), '/.config/file')

    def test_terminal_bytes_and_concurrent_sftp_use_real_ssh(self):
        channel = self.client.invoke_shell(width=80, height=24)
        channel.settimeout(5)
        self.assertIn(b'Fixture terminal', channel.recv(4096))
        sent = '\x1b[200~fixture \u4e2d\U0001f642\x1b[201~'.encode()
        channel.sendall(sent)
        recorded = b''
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            path = self.runtime / 'received.jsonl'
            if path.exists():
                recorded = b''.join(bytes.fromhex(json.loads(line)['hex'])
                                    for line in path.read_text().splitlines())
                if sent == recorded:
                    break
            time.sleep(0.05)
        self.assertEqual(recorded, sent)
        # A live shell channel must not prevent a second subsystem channel.
        with self.client.open_sftp() as sftp:
            self.assertIn('fixture.txt', sftp.listdir('/'))
        channel.close()

    def test_sftp_mutations_stay_in_fixture_root(self):
        with self.client.open_sftp() as sftp:
            sftp.mkdir('/created')
            with sftp.open('/created/upload.txt', 'w') as output:
                output.write(b'synthetic upload\n')
            with sftp.open('/created/upload.txt', 'r') as source:
                self.assertEqual(source.read(), b'synthetic upload\n')
            with self.assertRaises(OSError):
                sftp.open('/../outside', 'w')
            self.assertFalse((self.runtime / 'outside').exists())
            with sftp.open('/created/upload.txt', 'r+') as output:
                output.seek(MAX_FILE_BYTES)
                with self.assertRaises(OSError):
                    output.write(b'overflow')
            with self.assertRaises(OSError):
                sftp.open('/created/upload.txt', 'a')
            sftp.remove('/created/upload.txt')
            sftp.rmdir('/created')
            self.assertFalse((self.peer.root / 'created').exists())

    def test_path_mapping_rejects_parent_and_symlink_escape(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.peer.root / 'escape').symlink_to(outside, target_is_directory=True)
        for path in ['../outside', '/folder/../../outside', '/escape/file', '/bad\x00path']:
            with self.assertRaises(OSError):
                fixture_path(self.peer.root, path)
        self.assertEqual(fixture_path(self.peer.root, '/folder/file'), self.peer.root / 'folder/file')

    def test_exec_never_runs_a_runner_command(self):
        marker = self.root / 'must-not-exist'
        _, stdout, _ = self.client.exec_command(f'touch {marker}', timeout=5)
        self.assertEqual(stdout.channel.recv_exit_status(), 127)
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
