"""Offline behaviour tests for optional runtime measurement (stdlib unittest)."""
import importlib.util
import pathlib
import unittest
import json
import socket
import sys
import tempfile
import subprocess
import os
import shutil
import signal
import time
import http.server
import http.client
import threading
import urllib.request
from unittest import mock
from fixtures.runtime_http_server import LoopbackHTTPServer

PATH = pathlib.Path(__file__).resolve().parents[1] / 'skills/super-qa/scripts/runtime_compare.py'
spec = importlib.util.spec_from_file_location('runtime_compare', PATH)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)

class VerdictTests(unittest.TestCase):
    def test_overlap_is_not_a_performance_win(self):
        result = runtime.compare([90, 100, 110, 120, 130], [60, 80, 100, 110, 120])
        self.assertEqual(result['outcome'], 'inconclusive')


class ClassificationTests(unittest.TestCase):
    def test_matching_stable_samples_are_unchanged(self):
        self.assertEqual(runtime.compare([100]*5, [102]*5)['outcome'], 'unchanged')

    def test_separated_results_are_faster_or_slower(self):
        self.assertEqual(runtime.compare([100,101,102,103,104], [40,41,42,43,44])['outcome'], 'faster')
        self.assertEqual(runtime.compare([40,41,42,43,44], [100,101,102,103,104])['outcome'], 'slower')

    def test_insufficient_samples_are_inconclusive(self):
        self.assertEqual(runtime.compare([100]*4, [40]*5)['outcome'], 'inconclusive')

    def test_noise_near_same_median_is_inconclusive(self):
        self.assertEqual(runtime.compare([10,90,100,110,200], [100]*5)['outcome'], 'inconclusive')

    def test_high_variance_is_not_a_win_even_with_separated_ranges(self):
        self.assertEqual(runtime.compare([100,100,100,100,1000], [10,20,30,40,90])['outcome'], 'inconclusive')

    def test_small_disjoint_difference_is_not_a_win(self):
        self.assertEqual(runtime.compare([100]*5, [99]*5)['outcome'], 'unchanged')



class ExecutionTests(unittest.TestCase):
    def run_fixture(self, adapter_override=None, repetitions=5, overrides=None, server_override=None):
        # Real subprocess/HTTP boundary; canned durations exercise orchestration, not browser speed.
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            ports = []
            for _ in range(2):
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    ports.append(sock.getsockname()[1])
            while ports[1] == ports[0]:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    ports[1] = sock.getsockname()[1]
            server = """import http.server, sys, json
class App(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'duration':int(sys.argv[2]),'name':sys.argv[3]}).encode())
    def log_message(self,*args):pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),App).serve_forever()
"""
            adapter = """import os,json,urllib.request
v=json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(os.environ['SB_RUNTIME_URL']))
print(json.dumps({'correct':True,'duration_ms':v['duration'],'memory_bytes':2048,'environment':{'browser':'fixture-v1'}}))
"""
            shutil.copyfile(pathlib.Path(__file__).parent/'fixtures/runtime_http_server.py',
                            root/'fixture_server.py')
            server_source = 'from fixture_server import LoopbackHTTPServer\n' + (server_override or server)
            (root/'server.py').write_text(server_source.replace('http.server.HTTPServer(',
                                                               'LoopbackHTTPServer('))
            (root/'scenario.py').write_text(adapter_override or adapter)
            config = {'scenario_id':'fetch','data_id':'seed-1','environment_id':'local-fixture',
                      'scenario_command':[sys.executable,'scenario.py'], 'scenario_files':['scenario.py'],
                      'repetitions':repetitions, 'warmups':1}
            for n, port, duration in [('baseline',ports[0],100),('changed',ports[1],30)]:
                config[n]={'revision':n+'-v1','cwd':'.','url':f'http://127.0.0.1:{port}',
                           'start_command':[sys.executable,'server.py',str(port),str(duration),n]}
            config.update(overrides or {})
            path=root/'config.json'
            path.write_text(json.dumps(config))
            report,status=runtime.measure(path,root/'evidence')
            self.diagnostics = json.dumps(report, indent=2)
            self.server_logs = ''
            for log_path in sorted((root/'evidence').glob('*-server.log')):
                contents = log_path.read_text()
                self.server_logs += contents
                self.diagnostics += '\n' + log_path.name + ':\n' + contents
            artifact_root = os.environ.get('SB_RUNTIME_TEST_ARTIFACTS')
            if artifact_root:
                shutil.copytree(root/'evidence', pathlib.Path(artifact_root)/root.name)
            self.assertTrue((root/'evidence/report.json').exists(), self.diagnostics)
            for port in ports:
                with socket.socket() as sock:
                    self.assertNotEqual(sock.connect_ex(('127.0.0.1',port)),0,'server must be stopped')
            return report,status

    def test_alternates_five_pairs_saves_memory_and_stops_apps(self):
        report,status=self.run_fixture()
        self.assertEqual(status,0,self.diagnostics)
        self.assertEqual(report['outcome'],'faster')
        self.assertEqual(report['order'],['changed','baseline','baseline','changed','changed','baseline','baseline','changed','changed','baseline'])
        self.assertEqual(len(report['warmups']),2)
        self.assertEqual(report['memory']['changed']['median'],2048)

    def test_loopback_measurement_ignores_broken_host_proxy(self):
        # Real local HTTP must work even when host/system proxy settings do not bypass it.
        env = {key: 'http://127.0.0.1:1' for key in
               ('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY')}
        env.update(no_proxy='', NO_PROXY='')
        with mock.patch.dict(os.environ, env):
            report,status=self.run_fixture(overrides={'ready_timeout_seconds': 2})
        self.assertEqual(status,0,self.diagnostics)
        self.assertEqual(report['outcome'],'faster',self.diagnostics)
        self.assertEqual(report['correctness_failures'],{'baseline':0,'changed':0},self.diagnostics)
        self.assertEqual(len(report['order']),10,self.diagnostics)

    def redirect_server(self, target):
        # Log Host so the regression can prove no off-loopback request was sent.
        return '''import http.server, sys, json
class App(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print(self.headers['Host'], flush=True)
        if self.path == '/':
            self.send_response(302)
            self.send_header('Location', ''' + repr(target) + ''')
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({'duration':int(sys.argv[2]),'name':sys.argv[3]}).encode())
    def log_message(self,*args):pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),App).serve_forever()
'''

    def test_loopback_redirects_still_allow_measurement(self):
        report,status=self.run_fixture(server_override=self.redirect_server('/target'))
        self.assertEqual(status,0,self.diagnostics)
        self.assertEqual(report['outcome'],'faster',self.diagnostics)

    def test_external_redirect_is_rejected_before_sending_request(self):
        # Route only this fake hostname back to the real local server for a safe red proof.
        real_getaddrinfo = socket.getaddrinfo
        def local_dns(host, *args, **kwargs):
            return real_getaddrinfo('127.0.0.1' if host == 'outside.invalid' else host, *args, **kwargs)
        server = self.redirect_server('http://outside.invalid:1/target').replace(
            "'http://outside.invalid:1/target'", "'http://outside.invalid:' + sys.argv[1] + '/target'")
        with mock.patch('socket.getaddrinfo', side_effect=local_dns):
            report,status=self.run_fixture(server_override=server)
        self.assertEqual(status,2,self.diagnostics)
        self.assertIn('loopback HTTP URL',report['reason'],self.diagnostics)
        self.assertNotIn('outside.invalid',self.server_logs,self.diagnostics)
        self.assertEqual(report['order'],[],self.diagnostics)

    def test_nonlocal_or_credential_app_urls_are_rejected_before_startup(self):
        for url in ('http://localhost:80@outside.invalid:80',
                    'http://user:password@localhost:80',
                    'http://localhost:70000', 'http://localhost',
                    'https://localhost:80', 'http://outside.invalid:80'):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError,'loopback HTTP URL'):
                self.run_fixture(overrides={'baseline': {'revision':'invalid-v1', 'cwd':'.',
                    'url':url, 'start_command':[sys.executable,'-c','raise SystemExit(7)']}})

    def test_loopback_fixtures_do_not_wait_for_reverse_dns(self):
        # Same HTTPServer startup stall seen on macOS CI, through real child HTTP.
        server = ("import socket,time\nsocket.getfqdn=lambda host: time.sleep(10) or 'localhost'\n" +
                  self.redirect_server('/target'))
        report,status=self.run_fixture(server_override=server,overrides={'ready_timeout_seconds':2})
        self.assertEqual(status,0,self.diagnostics)
        self.assertEqual(report['outcome'],'faster',self.diagnostics)
        self.assertEqual(len(report['order']),10,self.diagnostics)

    def test_correctness_failure_cannot_claim_faster(self):
        adapter="""import os,json,urllib.request
v=json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(os.environ['SB_RUNTIME_URL']))
print(json.dumps({'correct':v['name']=='baseline','duration_ms':v['duration'],'environment':{'browser':'fixture-v1'}}))
"""
        report,status=self.run_fixture(adapter)
        self.assertEqual(status,2)
        self.assertEqual(report['outcome'],'inconclusive')
        self.assertEqual(report['correctness_failures']['changed'],6,self.diagnostics)

    def test_mismatched_browser_invalidates_comparison(self):
        adapter="""import os,json,urllib.request
v=json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(os.environ['SB_RUNTIME_URL']))
print(json.dumps({'correct':True,'duration_ms':v['duration'],'environment':{'browser':v['name']}}))
"""
        report,status=self.run_fixture(adapter)
        self.assertEqual(status,2)
        self.assertEqual(report['outcome'],'inconclusive')

    def test_malformed_adapter_output_is_recorded(self):
        report,status=self.run_fixture("print('not json')")
        self.assertEqual(status,2)
        self.assertEqual(report['correctness_failures'],{'baseline':6,'changed':6},self.diagnostics)

    def test_non_object_output_is_recorded(self):
        report,status=self.run_fixture("print('null')")
        self.assertEqual(status,2)
        self.assertEqual(report['outcome'],'inconclusive')

    def test_nonfinite_duration_is_recorded(self):
        report,status=self.run_fixture("print('{\"correct\":true,\"duration_ms\":NaN}')")
        self.assertEqual(status,2)
        self.assertEqual(report['outcome'],'inconclusive')

class FailureTests(unittest.TestCase):
    run_fixture = ExecutionTests.run_fixture
    # Isolate execution cases without inheriting all parent tests a second time.
    def test_adapter_timeout_is_recorded_and_apps_stopped(self):
        report,status=self.run_fixture("import time; time.sleep(2)", overrides={'timeout_seconds': .03})
        self.assertEqual(status,2)
        self.assertEqual(report['correctness_failures'],{'baseline':6,'changed':6},self.diagnostics)

    def test_occupied_loopback_url_is_rejected_even_with_host_proxy(self):
        response_status = [200]
        class App(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(response_status[0])
                self.end_headers()
                self.wfile.write(b'owned elsewhere')
            def log_message(self, *args):
                pass
        server = LoopbackHTTPServer(('127.0.0.1', 0), App)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        url = 'http://127.0.0.1:' + str(server.server_port)
        try:
            for status_code in (200,503):
                response_status[0] = status_code
                with self.subTest(status=status_code), mock.patch.dict(os.environ, {
                        'http_proxy':'http://127.0.0.1:1', 'HTTP_PROXY':'http://127.0.0.1:1',
                        'no_proxy':'', 'NO_PROXY':''}):
                    report,status=self.run_fixture(overrides={'baseline': {
                        'revision':'occupied-v1', 'cwd':'.', 'url':url,
                        'start_command':[sys.executable,'-c','raise SystemExit(7)']}})
                self.assertEqual(status,2,self.diagnostics)
                self.assertIn('app URL is already occupied: baseline',report['reason'],self.diagnostics)
                self.assertEqual(report['order'],[],self.diagnostics)
                # Rejecting the URL must not terminate its unrelated owner, even on HTTP errors.
                connection = http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=1)
                try:
                    connection.request('GET','/')
                    self.assertEqual(connection.getresponse().read(),b'owned elsewhere')
                finally:
                    connection.close()
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_startup_failure_keeps_inconclusive_report(self):
        report,status=self.run_fixture(overrides={'baseline': {'revision':'bad-v1','cwd':'.',
            'start_command':[sys.executable,'-c','raise SystemExit(7)'],'url':'http://127.0.0.1:1'}})
        self.assertEqual(status,2)
        self.assertEqual(report['outcome'],'inconclusive')
        self.assertIn('before becoming ready',report['reason'])

    def test_existing_evidence_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)
            # Direct boundary test: validation precedes evidence writes.
            (root/'scenario.py').write_text('pass')
            config={'scenario_id':'x','data_id':'x','environment_id':'x',
              'scenario_command':[sys.executable,'scenario.py'],'scenario_files':['scenario.py']}
            for name,port in [('baseline',40101),('changed',40102)]:
                config[name]={'revision':'x','cwd':'.','start_command':[sys.executable,'scenario.py'],
                              'url':f'http://127.0.0.1:{port}'}
            (root/'config.json').write_text(json.dumps(config))
            (root/'evidence').mkdir()
            with self.assertRaises(FileExistsError):
                runtime.measure(root/'config.json',root/'evidence')

class ProcessCleanupTests(unittest.TestCase):
    def test_timeout_kills_stubborn_descendant_holding_output_pipe(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)
            child=root/'child.py'
            child.write_text("import signal,time,sys,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text('ready'); print('child ready',flush=True); time.sleep(300)")
            wrapper=root/'wrapper.py'
            wrapper.write_text("import os,pathlib,subprocess,sys,time\n"+
                "p=subprocess.Popen([sys.executable,sys.argv[1],sys.argv[2]+'.ready'])\n"+
                "pathlib.Path(sys.argv[2]).write_text(str(os.getpid())+' '+str(p.pid))\n"+
                "time.sleep(300)\n")
            pidfile=root/'pids'
            driver=root/'driver.py'
            driver.write_text("import importlib.util,os,sys,subprocess\n"+
                "spec=importlib.util.spec_from_file_location('runtime',sys.argv[1]); r=importlib.util.module_from_spec(spec); spec.loader.exec_module(r)\n"+
                "try: r.run_adapter([sys.executable,sys.argv[2],sys.argv[3],sys.argv[4]],os.getcwd(),os.environ,1)\n"+
                "except subprocess.TimeoutExpired: print('timeout returned',flush=True)\n")
            proc=subprocess.Popen([sys.executable,str(driver),str(PATH),str(wrapper),str(child),str(pidfile)],
                                  stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
            started=time.monotonic()
            try:
                try:
                    stdout,stderr=proc.communicate(timeout=6)
                except subprocess.TimeoutExpired:
                    self.fail('runtime timeout hung while draining inherited output pipes')
                self.assertEqual(proc.returncode,0,stderr)
                self.assertIn('timeout returned',stdout)
                self.assertLess(time.monotonic()-started,5)
                self.assertTrue(pidfile.exists(),'descendant must actually have started')
                self.assertTrue(pathlib.Path(str(pidfile)+'.ready').exists(),'descendant must have installed its SIGTERM ignore handler')
                group,child_pid=map(int,pidfile.read_text().split())
                deadline=time.monotonic()+2
                while time.monotonic()<deadline:
                    state=subprocess.run(['ps','-o','stat=','-p',str(child_pid)],capture_output=True,text=True).stdout.strip()
                    if not state or state.startswith('Z'):
                        break
                    time.sleep(.05)
                self.assertTrue(not state or state.startswith('Z'),'descendant remains running after timeout')
            finally:
                if pidfile.exists():
                    group,_=map(int,pidfile.read_text().split())
                    try: os.killpg(group,signal.SIGKILL)
                    except ProcessLookupError: pass
                if proc.poll() is None:
                    os.killpg(proc.pid,signal.SIGKILL)
                proc.communicate(timeout=1)

class GroupSafetyTests(unittest.TestCase):
    def process(self, exited=False):
        p=mock.Mock(pid=999991)
        p.poll.return_value=0 if exited else None
        return p

    def test_empty_residual_group_is_reaped_without_signalling(self):
        p=self.process(exited=True)
        with mock.patch.object(runtime,'group_members',return_value={}), mock.patch.object(runtime.os,'killpg') as kill:
            runtime.stop(p)
            kill.assert_not_called()
        p.wait.assert_called()

    def test_permission_error_after_group_disappears_is_not_failure(self):
        p=self.process()
        with mock.patch.object(runtime,'group_members',side_effect=[{p.pid:os.getuid()},{}]), mock.patch.object(runtime.os,'killpg',side_effect=PermissionError):
            runtime.stop(p)
        p.wait.assert_called()

    def test_permission_error_with_live_group_is_explicit_failure(self):
        p=self.process()
        with mock.patch.object(runtime,'group_members',return_value={p.pid:os.getuid()}), mock.patch.object(runtime.os,'killpg',side_effect=PermissionError):
            with self.assertRaisesRegex(RuntimeError,'permission denied'):
                runtime.stop(p)
        p.wait.assert_called()

    def test_reused_group_leader_is_never_signalled(self):
        p=self.process(exited=True)
        with mock.patch.object(runtime,'group_members',return_value={p.pid:os.getuid()}), mock.patch.object(runtime.os,'killpg') as kill:
            with self.assertRaisesRegex(RuntimeError,'reused'):
                runtime.stop(p)
            kill.assert_not_called()

class BrowserAdapterTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node is required for browser adapter')
    def test_unavailable_playwright_is_structured_failure(self):
        helper=PATH.with_name('runtime_browser.mjs')
        with tempfile.TemporaryDirectory() as tmp:
            env=dict(os.environ, SB_RUNTIME_PROJECT=tmp)
            result=subprocess.run(['node',str(helper),'missing-scenario.mjs'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,2)
            report=json.loads(result.stdout)
            self.assertFalse(report['correct'])
            self.assertIn('Error',report['error'])

if __name__ == '__main__':
    unittest.main()
