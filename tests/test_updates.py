import hashlib
import importlib.util
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('updater', SOURCE / 'update.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)
health_probe = u.healthy


class UpdateTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.source = base / 'origin'
        self.source.mkdir()
        state = base / 'state'
        state.mkdir()
        self.live = base / 'live'
        self.live.mkdir()
        self.files = {name: (self.live / name, mode) for name, (_, mode) in u.FILES.items()}
        for name in self.files:
            shutil.copyfile(SOURCE / name, self.source / name)
        # Validate the actual sshd configuration with a disposable host identity.
        key = base / 'host_rsa'
        subprocess.run(['ssh-keygen','-q','-t','rsa','-b','3072','-N','','-f',str(key)],check=True)
        cfg = self.source / 'sshd_config'
        cfg.write_text(cfg.read_text().replace('/etc/personal-remote/ssh_host_rsa_key',str(key)))
        self.command('git','init','-q','-b','main')
        self.first = self.commit('initial')
        self.command('git','clone','-q','--bare',self.source,state/'repo.git')
        self.state = state
        self.calls = []
        real_run = u.run
        def sandbox_run(*args):
            if args[0] == 'systemctl':
                self.calls.append(args)
                return b''
            return real_run(*args)
        for change in [patch.object(u,'STATE',state),patch.object(u,'FILES',self.files),
                       patch.object(u,'run',sandbox_run),patch.object(u,'active',return_value=True),
                       patch.object(u,'healthy')]:
            result = change.start()
            self.addCleanup(change.stop)
        self.phone = self.live / 'authorized_keys'
        self.phone.write_bytes(b'previously authorized phone\n')

    def command(self,*args):
        return subprocess.run(args,cwd=self.source,check=True,capture_output=True,text=True).stdout.strip()

    def commit(self,message):
        self.command('git','add','--','.')
        self.command('git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm',message)
        return self.command('git','rev-parse','HEAD')

    def fetch_and_apply(self):
        u.git('fetch','--quiet','origin','refs/heads/main')
        u.deploy(u.git('rev-parse','FETCH_HEAD').decode().strip())

    def test_ssh_readiness_on_loopback(self):
        key = self.state.parent / 'host_rsa'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = self.live / 'sshd_config'
        config.write_text(f'HostKey {key}\nPort {port}\nListenAddress 127.0.0.1\nPidFile {self.state}/sshd.pid\nUsePAM no\n')
        (self.live / 'ssh_host_rsa_key.pub').write_bytes(Path(str(key)+'.pub').read_bytes())
        daemon = subprocess.Popen(['/usr/bin/sshd', '-D', '-f', config])
        try:
            with patch.object(u, 'CONFIG', self.live), patch.object(u, 'check_runner') as check:
                health_probe()
                check.assert_called_once()
        finally:
            daemon.terminate()
            daemon.wait(timeout=10)

    def test_first_repeat_update_reject_and_rollback(self):
        u.deploy(self.first)
        self.assertEqual((self.state/'installed').read_text().strip(),self.first)
        self.calls.clear()
        u.deploy(self.first)
        self.assertEqual(self.calls,[])
        runner = self.source/'runner.py'
        runner.write_text(runner.read_text()+'\n# version two\n')
        second = self.commit('runner update')
        self.fetch_and_apply()
        self.assertEqual(self.calls,[], 'runner-only update should preserve live SSH sessions')
        self.assertEqual((self.live/'runner.py').read_bytes(),runner.read_bytes())
        stable = hashlib.sha256(runner.read_bytes()).digest()
        self.assertEqual(self.phone.read_bytes(),b'previously authorized phone\n')
        runner.write_text('def broken(:')
        self.commit('invalid candidate')
        with self.assertRaises(SyntaxError): self.fetch_and_apply()
        self.assertEqual(hashlib.sha256((self.live/'runner.py').read_bytes()).digest(),stable)
        runner.write_text('print("new candidate")\n')
        self.commit('candidate fails readiness')
        with patch.object(u,'healthy',side_effect=[RuntimeError('failed readiness'),None]):
            with self.assertRaisesRegex(RuntimeError,'readiness'): self.fetch_and_apply()
        self.assertEqual((self.state/'installed').read_text().strip(),second)
        self.assertEqual(hashlib.sha256((self.live/'runner.py').read_bytes()).digest(),stable)
        self.assertFalse((self.state/'pending').exists())
        with self.assertRaises(subprocess.CalledProcessError): u.deploy(self.first)
        runner.unlink()
        runner.symlink_to('/etc/passwd')
        self.commit('reject link')
        with self.assertRaisesRegex(ValueError,'inválido'): self.fetch_and_apply()

if __name__ == '__main__':
    unittest.main()
