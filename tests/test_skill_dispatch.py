#!/usr/bin/env python3
"""Real setup/launcher boundaries with fake external tools. No host or GitHub writes."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

KIT = Path(os.environ.get('SB_TEST_PACK', Path(__file__).resolve().parents[1]))
NAMES = ['super-board','super-build','super-qa','super-review','super-collect','visual','git-sync','ui-refine-loop',
         'tdd','implement','codebase-design','code-review','diagnosing-bugs','verification-before-completion','testing-strategy']

class Dispatch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root, self.home, self.bin = [self.base / name for name in ['repo','home','bin']]
        for path in [self.root,self.home,self.bin]: path.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        SUPER_BOARD_SKILLS_HOME=str(self.home), SB_GITHUB_RETRY_DELAY='0',
                        SB_GITHUB_HALT_FILE=str(self.base / 'halt.json'), CALL_LOG=str(self.base / 'calls.jsonl'))
        subprocess.run(['git','init','-q',str(self.root)], check=True)
        self.config = self.base / 'config.json'
        self.config.write_text('{"max_workers":1,"verify_commands":["git diff --check"],"usage_fallback":"codex"}')
        self.tool('gh', '''import json,os,sys
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'gh','args':args})+'\\n')
if args[:2]==['issue','view']:
    fields=args[args.index('--json')+1] if '--json' in args else ''
    if fields=='state': print('OPEN')
    elif fields=='labels': print('{"labels":[]}')
    else: print(json.dumps({'number':int(args[2]),'title':'fixture','body':os.environ.get('ISSUE_BODY','')}))
else: sys.exit('unexpected GitHub mutation/read: '+str(args))
''')
        self.tool('codex', '''import json,os,re,sys
from pathlib import Path
args=sys.argv[1:];prompt=sys.stdin.read()
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'codex','prompt':prompt})+'\\n')
output=Path(args[args.index('--output-last-message')+1])
if 'Grade complexity' in prompt:
    if os.environ.get('REMOVE_AFTER_GRADE'):Path(os.environ['REMOVE_AFTER_GRADE']).unlink()
    result={'complexity':'low'}
else:
    card=json.loads(re.search(r'^Card: (.+)$',prompt,re.M).group(1))
    lane=re.search(r'Run super-(build|qa|review)',prompt).group(1)
    result={'status':'advanced','column':{'build':'QA','qa':'Review','review':'Done'}[lane], 'detail':'fixture','prUrl':None,'branch':None,'priorFindings':None}
output.write_text(json.dumps(result))
''')
        self.tool('claude', "import json,os\nwith open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'claude'})+'\\n')\n")
        self.tool('npx', "import json,os\nwith open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'npx'})+'\\n')\n")
        self.state = self.root / '.claude/super-board'
        (self.state / 'inflight').mkdir(parents=True)
        (self.state / 'inflight/99').write_text('PID=99999\nLANE=review\n')
        (self.state / 'approval.json').write_text('{"human":"existing"}')
        (self.root / '.claude/worktrees/preserved').mkdir(parents=True)
        (self.root / '.claude/worktrees/preserved/user.txt').write_text('existing work')

    def tool(self,name,source):
        compile(source, name, 'exec')
        path=self.bin/name;path.write_text('#!/usr/bin/env python3\n'+source);path.chmod(0o755)

    def full(self,host='codex'):
        for name in NAMES:
            for surface in ['.agents/skills'] if host=='codex' else ['.claude/skills']:
                path=self.root/surface/name/'SKILL.md';path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture skill instructions')

    def calls(self):
        path=self.base/'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def invoke(self,script,*args):
        return subprocess.run(['bash',str(KIT/'scripts'/script),*args],cwd=self.root,env=self.env,text=True,capture_output=True)

    def preserved(self):
        self.assertEqual((self.state/'inflight/99').read_text(),'PID=99999\nLANE=review\n')
        self.assertEqual((self.state/'approval.json').read_text(),'{"human":"existing"}')
        self.assertEqual((self.root/'.claude/worktrees/preserved/user.txt').read_text(),'existing work')
        self.assertFalse((self.state/'codex-wave.pid').exists())

    def test_missing_all_remaining_chains_halt_before_router_or_marker(self):
        for status,labels in [('Ready',[]),('Ready',['qa']),('QA',[]),('Review',[])]:
            with self.subTest(status=status,labels=labels):
                result=self.invoke('super-board-codex-wave.sh','--config',str(self.config),'--cards',json.dumps([dict(number=1,status=status,labels=labels)]),'--codex')
                self.assertEqual(result.returncode,10,result.stderr)
                output=json.loads(result.stdout)
                self.assertTrue(output['halted']);self.assertEqual(output['cards'][0]['column'],status)
                self.assertTrue(output['cards'][0]['detail'].startswith('skills-readiness:'))
                self.assertFalse(any(c['tool']=='codex' for c in self.calls()))
                self.assertTrue(all(c['args'][:2]==['issue','view'] for c in self.calls()))
                self.assertEqual(sorted(p.name for p in (self.state/'inflight').iterdir()),['99'])
                self.preserved()

    def test_passing_wave_progresses_all_lanes_and_hydrates_body(self):
        self.full()
        result=self.invoke('super-board-codex-wave.sh','--config',str(self.config),'--cards','[{"number":1,"status":"Ready"}]','--codex=fixture')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['cards'][0]['column'],'Done')
        host=[c for c in self.calls() if c['tool']=='codex']
        self.assertEqual(len(host),3)
        self.assertTrue(all('Resolved skill report:' in c['prompt'] for c in host))
        self.preserved()

    def test_removed_skill_after_wave_check_halts_before_worker(self):
        self.full()
        self.env['REMOVE_AFTER_GRADE']=str(self.root/'.agents/skills/code-review/SKILL.md')
        result=self.invoke('super-board-codex-wave.sh','--config',str(self.config),'--cards','[{"number":1,"status":"Ready","body":""}]','--codex')
        self.assertEqual(result.returncode,10,result.stderr)
        calls=[c for c in self.calls() if c['tool']=='codex']
        self.assertEqual(len(calls),1);self.assertIn('Grade complexity',calls[0]['prompt'])
        self.assertEqual(sorted(p.name for p in (self.state/'inflight').iterdir()),['99'])
        self.preserved()

    def test_codex_fallback_and_override_cannot_use_claude_only_files(self):
        self.full('claude')
        card=dict(number=1,status='Ready',body='Skills: custom')
        result=self.invoke('super-board-codex-lane.sh','--config',str(self.config),'--card',json.dumps(card),'--lane','build')
        self.assertEqual(result.returncode,10,result.stderr)
        self.assertFalse(any(c['tool']=='codex' for c in self.calls()))
        self.full()
        result=self.invoke('super-board-codex-lane.sh','--config',str(self.config),'--card',json.dumps(card),'--lane','build')
        self.assertEqual(result.returncode,10,result.stderr)
        path=self.root/'.agents/skills/custom/SKILL.md';path.parent.mkdir(parents=True);path.write_text('custom')
        result=self.invoke('super-board-codex-lane.sh','--config',str(self.config),'--card',json.dumps(card),'--lane','build')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_legacy_dispatch_missing_skills_stops_before_claim(self):
        body='''export SB_LIB_ONLY=1
source "$1/scripts/super-board-run.sh"
BOT_LOGIN=bot
PROJECT_ITEMS_JSON='{"items":[{"status":"Ready","content":{"number":1},"labels":["docs"]}]}'
INFLIGHT_DIR=.claude/super-board/inflight
WORKER_LOG_DIR="$PWD"
dispatch_lane build 1
'''
        result=subprocess.run(['bash','-c',body,'fixture',str(KIT)],cwd=self.root,env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode,10,result.stderr)
        self.assertTrue(all(c['tool']=='gh' and c['args'][:2]==['issue','view'] for c in self.calls()))
        self.assertFalse((self.root/'worker-build-1.log').exists())
        self.preserved()

    def test_standalone_missing_skills_creates_no_log_or_worktree(self):
        subprocess.run(['git','-C',str(self.root),'-c','user.name=Fixture','-c','user.email=fixture@example.com','commit','--allow-empty','-qm','fixture'],check=True)
        directory=self.root/'.claude/bin';directory.mkdir()
        for name in ['super-board-github-read.py','super-board-skills-ready.py']:
            shutil.copy2(KIT/'scripts'/name,directory/name)
        self.env.update(REPO_DIR=str(self.root),BASE_BRANCH=subprocess.check_output(['git','-C',str(self.root),'branch','--show-current'],text=True).strip())
        result=subprocess.run(['bash',str(KIT/'skills/super-build/scripts/super-build-dispatch.sh'),'1'],cwd=self.root,env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode,10,result.stderr)
        self.assertFalse((self.root/'.planning/super-build-logs').exists())
        self.assertFalse((self.root/'.claude/worktrees/issue-1').exists())
        self.assertTrue(all(c['tool']=='gh' and c['args'][:2]==['issue','view'] for c in self.calls()))
        self.preserved()

    def test_legacy_halt_stops_owned_worker_preserves_unrelated_and_evidence(self):
        self.full('claude')
        def reap_owned():
            path = self.root / 'owned.pid'
            if not path.exists():
                return
            pid = int(path.read_text())
            def exited():
                try:
                    # Reap directly if this platform adopted the worker.
                    child, _ = os.waitpid(pid, os.WNOHANG)
                    return child == pid
                except ChildProcessError:
                    # The runner's worker is normally a grandchild. An orphaned
                    # zombie has exited and cannot write, even before init reaps it.
                    state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'command='],
                                           capture_output=True, text=True, timeout=1).stdout.strip()
                    if not state:
                        return True
                    status, _, command = state.partition(' ')
                    # This unique fixture path identifies the owned worker.
                    # A reused PID belongs to somebody else and is never signalled.
                    return status.startswith('Z') or str(self.bin / 'claude') not in command
            def wait_for_exit():
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if exited():
                        return True
                    time.sleep(.02)
                return exited()
            if exited():
                return
            # The dispatcher may already have sent TERM. Do not re-enter its
            # asynchronous handler; wait for completion before deleting files.
            if not (self.root / 'owned.stopped').exists() and not exited():
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    return
            if not wait_for_exit() and not exited():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    return
                if not wait_for_exit():
                    raise RuntimeError('owned fixture worker did not exit before directory cleanup')
        def require_worker_finished_before_directory_cleanup():
            if (self.root / 'owned.pid').exists():
                self.assertTrue((self.root / 'owned.finished').exists(),
                                'fixture directory cleanup raced the owned worker shutdown')
                status = subprocess.run(['ps', '-p', (self.root / 'owned.pid').read_text(), '-o', 'stat='],
                                        capture_output=True, text=True, timeout=1).stdout.strip()
                self.assertTrue(not status or status.startswith('Z'),
                                'directory cleanup began while the fixture worker was still running')
        self.addCleanup(require_worker_finished_before_directory_cleanup)
        self.addCleanup(reap_owned)
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        def reap_unrelated():
            if unrelated.poll() is None:
                unrelated.terminate()
            unrelated.wait(timeout=3)
        self.addCleanup(reap_unrelated)
        (self.state / 'inflight/99').write_text(f'PID={unrelated.pid}\nLANE=review\n')
        config_dir = self.state / 'configs'; config_dir.mkdir()
        (config_dir / 'fixture.json').write_text(json.dumps(dict(project=dict(owner='fixture',number=1),
            base_branch='main',worker_backend='claude-p',max_workers=3,bot_identity='bot',
            verify_commands=['git diff --check'],tick_seconds=1)))
        self.tool('pgrep', 'import sys; sys.exit(1)')
        self.env['ROOT_FIXTURE'] = str(self.root)
        self.tool('claude', """import json,os,signal,time
from pathlib import Path
root=Path(os.environ['ROOT_FIXTURE'])
(root/'owned.pid').write_text(str(os.getpid()))
(root/'.claude/skills/diagnosing-bugs/SKILL.md').unlink()
(root/'owned.started').write_text('started')
def stop(*args):
    (root/'owned.stopped').write_text('stopped')
    time.sleep(.2)  # Controlled asynchronous shutdown, after the halt proof.
    (root/'owned.finished').write_text('finished')
    raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
while True: time.sleep(.05)
""")
        self.tool('gh', """import json,os,sys,time
from pathlib import Path
args=sys.argv[1:];root=Path(os.environ['ROOT_FIXTURE'])
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'gh','args':args})+'\\n')
if args[:2]==['api','rate_limit']:print('{"resources":{"graphql":{"remaining":5000,"reset":0},"core":{"remaining":5000,"reset":0}}}')
elif args[:2]==['api','graphql'] and '--paginate' in args:
    nodes=[dict(id='item'+str(number),fieldValueByName=dict(name=status),
                content=dict(__typename='Issue',number=number,title='fixture',url='https://github.com/fixture/app/issues/'+str(number),
                             repository=dict(nameWithOwner='fixture/app'),labels=dict(nodes=[]))) for number,status in [(1,'Review'),(2,'QA')]]
    print(json.dumps([{'data':{'repositoryOwner':{'projectV2':{'items':{'totalCount':2,'nodes':nodes,'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}}]))
elif args[:2]==['project','item-list']:
    print(json.dumps({'items':[{'id':'one','status':'Review','content':{'type':'Issue','number':1,'assignees':[]}},
                              {'id':'two','status':'QA','content':{'type':'Issue','number':2,'assignees':[]}}]}))
elif args[:2]==['issue','view']:
    if args[2]=='2':
        deadline=time.monotonic()+3
        while not (root/'owned.started').exists() and time.monotonic()<deadline:time.sleep(.01)
    fields=args[args.index('--json')+1]
    if fields=='state':print('OPEN')
    elif fields=='labels':print('{"labels":[]}')
    else:print(json.dumps({'number':int(args[2]),'title':'fixture','body':''}))
elif args[:2]==['issue','edit'] and '--add-assignee' in args:pass
else:sys.exit('unexpected gh call: '+str(args))
""")
        result = subprocess.run(['bash',str(KIT/'scripts/super-board-run.sh'),'fixture'],cwd=self.root,
                                env=self.env,text=True,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,10,result.stderr + result.stdout)
        deadline = __import__('time').monotonic()+3
        while not (self.root/'owned.stopped').exists() and __import__('time').monotonic()<deadline:
            __import__('time').sleep(.02)
        self.assertTrue((self.root/'owned.stopped').exists())
        self.assertIsNone(unrelated.poll())
        self.assertTrue((self.state/'inflight/1').is_file())
        self.assertEqual((self.state/'approval.json').read_text(),'{"human":"existing"}')
        self.assertEqual((self.state/'inflight/99').read_text(),f'PID={unrelated.pid}\nLANE=review\n')
        self.assertFalse(any(c['args'][:3]==['issue','edit','2'] for c in self.calls()))

    def test_setup_fix_reports_missing_even_after_successful_installer(self):
        (self.root/'skills-lock.json').write_text('{"mattpocock/skills":true}')
        for command,extra in [('check',[]),('fix',['--no-helpers']),('fix',[])]:
            result=subprocess.run([sys.executable,str(KIT/'scripts/super-board-setup.py'),command,'--root',str(self.root),'--pack',str(KIT),'--home',str(self.home),*extra],env=self.env,text=True,capture_output=True)
            self.assertEqual(result.returncode,1,result.stderr)
            output=json.loads(result.stdout)
            self.assertFalse(output['helper_skills']);self.assertFalse(output['green'])
            self.assertTrue(any(e['status']=='missing' for e in output['helper_readiness']['entries']))
            self.assertNotIn("Matt Pocock's coding skills added",output.get('fixed',[]))
        self.assertEqual(len([c for c in self.calls() if c['tool']=='npx']),1)

if __name__=='__main__':unittest.main()
