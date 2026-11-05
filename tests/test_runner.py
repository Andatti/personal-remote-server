import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runner', Path(__file__).parents[1] / 'runner.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r.SCRIPTS = Path(self.tmp.name)
        r.LOCK = str(r.SCRIPTS / '.lock')
        r.TIMEOUT = 2
    def tearDown(self): self.tmp.cleanup()
    def script(self, name, content):
        p = r.SCRIPTS / name
        p.write_text('#!/bin/sh\n' + content)
        p.chmod(0o700)
        return p
    def run_script(self, name): return r.dispatch('run ' + base64.urlsafe_b64encode(name.encode()).decode())
    def test_per_host_scripts_directory_and_legacy_default(self):
        root = Path(self.tmp.name)
        with patch.object(r, '__file__', str(root / 'runner.py')):
            self.assertEqual(r.scripts_directory(), Path('/home/maetti/.personalScripts'))
            scripts = root / 'otro usuario' / '.personalScripts'
            (root / 'scripts-dir').write_text(str(scripts) + '\n')
            self.assertEqual(r.scripts_directory(), scripts)

    def test_list_and_output_exit(self):
        self.script('hola mundo.sh', 'echo hola; echo error >&2; exit 7')
        self.assertEqual(r.dispatch('list')['scripts'], ['hola mundo.sh'])
        result = self.run_script('hola mundo.sh')
        self.assertEqual(result['exit_code'], 7)
        self.assertEqual(result['output'], 'hola\nerror\n')
    def test_paths_and_commands_rejected(self):
        for cmd in ['id', '', 'run !!!', 'list; id']:
            with self.assertRaises(Exception): r.dispatch(cmd)
        for path in ['../etc/passwd', '/bin/sh', '.', 'a/b']:
            with self.assertRaises(Exception): self.run_script(path)
    def test_symlinks_and_writable_hidden(self):
        p = self.script('ok', 'true')
        (r.SCRIPTS/'link').symlink_to(p)
        self.script('unsafe', 'true').chmod(0o777)
        self.assertEqual(r.dispatch('list')['scripts'], ['ok'])
        with self.assertRaises(ValueError): self.run_script('link')
    def test_timeout(self):
        r.TIMEOUT = 0.15
        self.script('slow', 'sleep 10')
        self.assertTrue(self.run_script('slow')['timed_out'])
    def test_bounded_output(self):
        self.script('large', 'head -c 400000 /dev/zero')
        result = self.run_script('large')
        self.assertEqual(len(result['output']), r.OUTPUT_LIMIT)
        self.assertTrue(result['truncated'])
    def test_busy(self):
        self.script('ok', 'true')
        with open(r.LOCK,'a') as lock:
            r.fcntl.flock(lock,r.fcntl.LOCK_EX)
            with self.assertRaisesRegex(ValueError, 'Ya hay'): self.run_script('ok')

if __name__ == '__main__': unittest.main()
