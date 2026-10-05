"""Stable-ID import and additive native-sync CLI regression, synthetic data only."""
import argparse
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

from ssh_jump_chain_e2e import Fixture, PASSWORD, PASSPHRASE


def snapshot(profile):
    with sqlite3.connect(profile / "sessions.db") as db:
        return {name: db.execute(query).fetchall() for name, query in (
            ("meta", "SELECT key,value FROM meta ORDER BY key"),
            ("sessions", "SELECT ordinal,id,data FROM sessions ORDER BY ordinal,id"),
            ("history", "SELECT seq,command FROM command_history ORDER BY seq"))}


def rows(profile):
    return [json.loads(row[2]) for row in snapshot(profile)["sessions"]]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="xenterm-migration-modes-") as directory:
        root = Path(directory)
        fixture = Fixture(args.exe.resolve(), root)
        source = fixture.config
        try:
            fixture.use_key(1, inline=False, encrypted=True)
            fixture.use_key(2, inline=True, encrypted=True)
            fixture.sessions[2]["jump_session_ids"] = ["outer", "inner"]
            fixture.sessions.append(dict(fixture.sessions[2], id="equal-alias"))
            fixture.save()

            def cli(profile, *args, ok=True):
                result = subprocess.run([str(fixture.exe), "--data-dir", str(profile), "cli", *args],
                    capture_output=True, text=True, timeout=30, env=fixture.env)
                assert (result.returncode == 0) == ok, (result.returncode, result.stdout, result.stderr)
                assert all(secret not in result.stdout + result.stderr for secret in (PASSWORD, PASSPHRASE, "PRIVATE KEY"))
                return json.loads(result.stdout) if ok else result

            export = root / "portable.json"
            cli(source, "export", str(export), "--include-credentials", "--json")
            destination = root / "independent"
            destination.mkdir()
            (destination / "sessions.json").write_text(json.dumps(dict(sessions=[], defaults_rev=999,
                mcp_enabled=True, mcp_use_saved_credentials=True, mcp_allow_commands=True,
                mcp_allow_file_transfers=True)), encoding="utf-8")
            cli(destination, "sessions", "--json")
            before = snapshot(destination)
            assert cli(destination, "import", str(export), "--preserve-ids", "--dry-run", "--json") == dict(added=4, skipped=0, dry_run=True)
            assert snapshot(destination) == before
            assert cli(destination, "import", str(export), "--preserve-ids", "--json") == dict(added=4, skipped=0, dry_run=False)
            assert {item["id"] for item in rows(destination)} == {"outer", "inner", "target", "equal-alias"}
            assert cli(destination, "import", str(export), "--preserve-ids", "--json") == dict(added=0, skipped=4, dry_run=False)
            target = next(item for item in rows(destination) if item["id"] == "target")
            assert target["jump_session_id"] == "inner" and target["jump_session_ids"] == ["outer", "inner"]
            assert (source / "secret.key").read_bytes() != (destination / "secret.key").read_bytes()

            conflict = root / "conflicting.json"
            incoming = json.loads(export.read_text())
            incoming["sessions"][2]["host"] = "different.invalid"
            conflict.write_text(json.dumps(incoming))
            before = snapshot(destination)
            for flags in ([], ["--dry-run"]):
                cli(destination, "import", str(conflict), "--preserve-ids", *flags, "--json", ok=False)
                assert snapshot(destination) == before
            print("PASS: CLI stable-ID preview/apply retains aliases/routes, rekeys credentials, and rejects conflicts atomically")

            current = rows(destination)
            update = dict(next(item for item in current if item["id"] == "target"), note="synthetic updated note", allow_secret_reveal=True)
            added = dict(next(item for item in current if item["id"] == "outer"), id="native-added", name="Native added", allow_secret_reveal=True)
            native = root / "native.json"
            native.write_text(json.dumps(dict(xenterm_export=1, sessions=[update, added], mcp_allow_commands=False)))
            before = snapshot(destination)
            assert cli(destination, "sync-native", str(native), "--dry-run", "--json") == dict(updated=1, added=1, dry_run=True)
            assert snapshot(destination) == before
            # A second-row failure must roll back the first update as well.
            with sqlite3.connect(destination / "sessions.db") as db:
                db.executescript("CREATE TRIGGER fail_new BEFORE INSERT ON sessions WHEN NEW.id='native-added' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")
            cli(destination, "sync-native", str(native), "--json", ok=False)
            assert snapshot(destination) == before
            with sqlite3.connect(destination / "sessions.db") as db:
                db.executescript("DROP TRIGGER fail_new;")
            assert cli(destination, "sync-native", str(native), "--json") == dict(updated=1, added=1, dry_run=False)
            after = snapshot(destination)
            assert dict(after["meta"])["settings"] == dict(before["meta"])["settings"]
            assert after["history"] == before["history"]
            after_rows = {item["id"]: item for item in rows(destination)}
            assert set(after_rows) == {"outer", "inner", "target", "equal-alias", "native-added"}
            assert after_rows["target"]["note"] == "synthetic updated note"
            assert after_rows["target"]["allow_secret_reveal"] is False
            assert after_rows["native-added"]["allow_secret_reveal"] is False
            for row in before["sessions"]:
                if row[1] != "target":
                    assert row in after["sessions"]
            assert cli(destination, "sync-native", str(native), "--json") == dict(updated=0, added=0, dry_run=False)
            assert snapshot(destination) == after
            print("PASS: native preview, changed-ID-only update, no deletion/settings changes, consent reset, rollback and retry")

            # Native ciphertext from another profile must not be copied blindly.
            foreign = root / "foreign.json"
            foreign.write_text(json.dumps(dict(sessions=rows(source))))
            cli(destination, "sync-native", str(foreign), "--json", ok=False)
            assert snapshot(destination) == after
            for version in (2, None, "1"):
                invalid = root / "version.json"
                invalid.write_text(json.dumps(dict(xenterm_export=version, sessions=[])))
                for command in ("import", "sync-native"):
                    cli(destination, command, str(invalid), "--json", ok=False)
                    assert snapshot(destination) == after
            print("PASS: foreign native keys and invalid portable alias versions fail without partial changes")

            fixture.config = destination
            result = fixture.mcp("run_command", session_id="target", command="fixture", timeout_seconds=8)
            assert result.get("isError"), "Migration must not import SSH host trust"
            fixture.trust()
            fixture.command()
            assert cli(destination, "exec", "target", "--json", "--", "fixture")["stdout"] == "multi-hop-command:target\n"
            key_path = Path(after_rows["inner"]["private_key_path"])
            unavailable = key_path.with_name("temporarily-unavailable-key")
            key_path.rename(unavailable)
            try:
                cli(destination, "exec", "target", "--json", "--", "fixture", ok=False)
            finally:
                unavailable.rename(key_path)
            fixture.command()
            print("PASS: stable IDs remain usable by MCP/CLI after native sync; missing external key files are not silently usable")
        finally:
            for node in fixture.nodes:
                node.close()


if __name__ == "__main__":
    main()
