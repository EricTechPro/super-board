#!/usr/bin/env python3
"""Offline contract for super-board-forge.py: remote parsing, precedence, CLI exits."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/super-board-forge.py'

import importlib.util
_spec = importlib.util.spec_from_file_location('super_board_forge', HELPER)
forge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(forge)


class ParseRemoteTests(unittest.TestCase):
    def test_https_github(self):
        self.assertEqual(forge.parse_remote('https://github.com/acme/app.git'),
                         {'host': 'https://github.com', 'owner': 'acme', 'repo': 'app'})

    def test_https_no_suffix(self):
        self.assertEqual(forge.parse_remote('https://github.com/acme/app'),
                         {'host': 'https://github.com', 'owner': 'acme', 'repo': 'app'})

    def test_http_gitea_with_port_keeps_scheme_and_port(self):
        self.assertEqual(forge.parse_remote('http://localhost:3000/acme/app.git'),
                         {'host': 'http://localhost:3000', 'owner': 'acme', 'repo': 'app'})

    def test_scp_form(self):
        self.assertEqual(forge.parse_remote('git@gitea.example.com:acme/app.git'),
                         {'host': 'https://gitea.example.com', 'owner': 'acme', 'repo': 'app'})

    def test_ssh_url_with_port(self):
        self.assertEqual(forge.parse_remote('ssh://git@gitea.example.com:2222/acme/app.git'),
                         {'host': 'https://gitea.example.com:2222', 'owner': 'acme', 'repo': 'app'})

    def test_unparseable(self):
        for url in ('', None, 'not-a-url', 'https://github.com/onlyowner', '/local/path',
                    'https://github.com/a b/c d'):
            with self.subTest(url=url):
                self.assertIsNone(forge.parse_remote(url))


class ResolveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)  # not a git repo: remote fallback stays empty
        self.env_saved = {k: os.environ.get(k) for k in ('SB_FORGE', 'SB_FORGE_HOST', 'SB_FORGE_LOGIN')}
        for k in self.env_saved:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self.env_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.temp.cleanup()

    def write_config(self, cfg):
        path = self.root / 'cfg.json'
        path.write_text(json.dumps(cfg))
        return str(path)

    def test_absent_config_defaults_to_github(self):
        res = forge.resolve(root=str(self.root))
        self.assertEqual(res['forge'], 'github')
        self.assertEqual(res['host'], 'https://github.com')

    def test_config_keys_win_over_remote_but_env_wins_over_all(self):
        cfg = self.write_config({'forge': 'gitea', 'forge_host': 'https://gitea.example.com',
                                 'forge_login': 'bot', 'project': {'owner': 'acme'},
                                 'repo': {'remote': 'https://gitea.example.com/acme/app.git'}})
        res = forge.resolve(cfg, root=str(self.root))
        self.assertEqual((res['forge'], res['host'], res['login'], res['owner'], res['repo']),
                         ('gitea', 'https://gitea.example.com', 'bot', 'acme', 'app'))
        os.environ['SB_FORGE_HOST'] = 'http://localhost:3000'
        res = forge.resolve(cfg, root=str(self.root))
        self.assertEqual(res['host'], 'http://localhost:3000')

    def test_gitea_host_falls_back_to_a_non_github_remote(self):
        cfg = self.write_config({'forge': 'gitea',
                                 'repo': {'remote': 'http://localhost:3000/acme/app.git'}})
        res = forge.resolve(cfg, root=str(self.root))
        self.assertEqual(res['host'], 'http://localhost:3000')
        self.assertEqual(res['owner'], 'acme')
        forge.check(res)  # must not raise

    def test_gitea_without_host_fails_check(self):
        cfg = self.write_config({'forge': 'gitea'})
        res = forge.resolve(cfg, root=str(self.root))
        with self.assertRaises(LookupError):
            forge.check(res)

    def test_unknown_forge_raises(self):
        os.environ['SB_FORGE'] = 'gitlab'
        with self.assertRaises(ValueError):
            forge.resolve(root=str(self.root))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ('SB_FORGE', 'SB_FORGE_HOST', 'SB_FORGE_LOGIN')}

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *args, env=None):
        return subprocess.run([sys.executable, str(HELPER), *args], cwd=self.root,
                              env=env or self.env, text=True, capture_output=True)

    def write_config(self, cfg):
        path = self.root / 'cfg.json'
        path.write_text(json.dumps(cfg))
        return str(path)

    def test_get_shell_is_eval_safe(self):
        cfg = self.write_config({'forge': 'gitea', 'forge_host': "https://gitea.example.com",
                                 'repo': {'remote': 'https://gitea.example.com/acme/app.git'}})
        r = self.run_cli('get', '--config', cfg, '--shell')
        self.assertEqual(r.returncode, 0, r.stderr)
        # shlex.quote leaves bare words unquoted; the empty login shows quoting works.
        self.assertIn('SB_FORGE_KIND=gitea', r.stdout)
        self.assertIn("SB_FORGE_LOGIN=''", r.stdout)
        self.assertIn('SB_FORGE_REPO=app', r.stdout)

    def test_single_value_subcommands(self):
        cfg = self.write_config({'forge': 'gitea', 'forge_host': 'https://gitea.example.com',
                                 'project': {'owner': 'acme'},
                                 'repo': {'remote': 'https://gitea.example.com/acme/app.git'}})
        for cmd, want in (('forge', 'gitea'), ('host', 'https://gitea.example.com'),
                          ('owner', 'acme'), ('repo', 'app')):
            r = self.run_cli(cmd, '--config', cfg)
            self.assertEqual(r.stdout.strip(), want, f'{cmd}: {r.stderr}')

    def test_unknown_forge_exits_64(self):
        cfg = self.write_config({'forge': 'bitbucket'})
        self.assertEqual(self.run_cli('get', '--config', cfg).returncode, 64)

    def test_gitea_without_host_exits_66(self):
        cfg = self.write_config({'forge': 'gitea'})
        self.assertEqual(self.run_cli('get', '--config', cfg).returncode, 66)

    def test_get_json_shape(self):
        r = self.run_cli('get', '--json')
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertEqual(data['forge'], 'github')
        self.assertIn('config', data)


if __name__ == '__main__':
    unittest.main()
