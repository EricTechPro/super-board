#!/usr/bin/env python3
"""Real installed wave/lane/handoff/card helpers with isolated GitHub and model stubs."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]
GH = r'''import json,os,sys
from pathlib import Path
p=Path(os.environ['FIXTURE_STATE']);s=json.loads(p.read_text());a=sys.argv[1:]
def save():p.write_text(json.dumps(s))
if a[:2]==['api','graphql']:
 q=next((a[i+1] for i,v in enumerate(a[:-1]) if v=='-f' and a[i+1].startswith('query=')), '')
 if 'updateProjectV2ItemFieldValue' in q:
  s['board']=next(x[2:] for x in a if x.startswith('o='));save();print('{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"ITEM"}}}}')
 elif 'repositoryOwner' in q:
  print(json.dumps({'data':{'repositoryOwner':{'projectV2':{'id':'PROJECT','field':{'id':'FIELD','options':[{'id':n,'name':n} for n in ['Ready','QA','Review','Blocked','Done']]}}}}}))
 else:print(json.dumps({'data':{'repository':{'issueOrPullRequest':{'projectItems':{'nodes':[{'id':'ITEM','project':{'number':1,'owner':{'login':'fixture'}},'fieldValueByName':{'name':s['board']}}]}}}}}))
elif a[:2]==['api','-X']:
 value=json.load(sys.stdin);endpoint=a[3]
 if a[2]=='PATCH':s['comments'][0]['body']=value['body']
 else:s['comments'].append({'id':100,'body':value['body'],'user':{'login':'fixture'},'created_at':'2026-10-20T00:00:00Z','updated_at':'2026-10-20T00:00:00Z'})
 save();print('{}')
elif a and a[0]=='api' and '--slurp' in a:print(json.dumps([s['comments']]))
elif a[:2]==['issue','view']:
 fields=a[a.index('--json')+1];print(json.dumps({'labels':[{'name':x} for x in s['labels']]} if fields=='labels' else {'number':1,'title':'fixture','body':''}))
elif a[:2]==['issue','edit']:
 s['label_edits'].append(a);save()
 for i,x in enumerate(a[:-1]):
  if x=='--add-label' and a[i+1] not in s['labels']:s['labels'].append(a[i+1]);save()
  if x=='--remove-label':
   if a[i+1] not in s['repo_labels']:sys.exit("'"+a[i+1]+"' not found")
   if a[i+1] in s['labels']:s['labels'].remove(a[i+1])
 save()
 if os.environ.get('FIXTURE_LABEL_EDIT_UNKNOWN'):sys.exit('connection lost after label mutation')
elif a[:2]==['issue','comment']:s['blocks'].append(a[a.index('--body')+1]);save()
elif a[:2]==['label','create']:
 if a[2] not in s['repo_labels']:s['repo_labels'].append(a[2]);save()
else:sys.exit('unexpected gh '+str(a))
'''
HOST = r'''import json,os,re,sys
from pathlib import Path
args=sys.argv[1:];prompt=sys.stdin.read();diag='fresh independent read-only diagnostician' in prompt
comments=json.loads(Path(os.environ['FIXTURE_STATE']).read_text())['comments']
reserved=json.loads(re.search(r'^repair-state: (.+)$',comments[0]['body'],re.M)[1]) if comments else {}
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write(json.dumps({'host':Path(sys.argv[0]).name,'diagnosis':diag,'phase':reserved.get('phase'),'repairs':reserved.get('repairs'),'labels':json.loads(Path(os.environ['FIXTURE_STATE']).read_text())['labels']})+'\n')
card=json.loads(re.search(r'^Card: (.+)$',prompt,re.M)[1]);mode=os.environ.get('FIXTURE_DIAG','same')
if diag:
 result=dict(status='advanced',column=card['status'],detail=json.dumps(dict(cause='new cause' if mode=='new' else 'failure',test='test -f proof',expected='fails')),prUrl=None,branch=None,priorFindings=None)
 if mode=='malformed':result['detail']='not JSON'
else:result=dict(status=os.environ.get('FIXTURE_RESULT','failed'),column=card['status'],detail='failure',prUrl=None,branch=None,priorFindings=None)
if '--output-last-message' in args:Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(result))
else:print(json.dumps(result))
if diag and mode=='provider':sys.exit(1)
'''


class RepairWave(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name); self.root = self.base / 'repo'; self.root.mkdir()
        self.home = self.base / 'home'; self.home.mkdir(); self.bin = self.base / 'bin'; self.bin.mkdir()
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        subprocess.run(['bash',str(KIT/'install.sh'),'--hosts','codex,pi',str(self.root)],check=True,stdout=subprocess.DEVNULL)
        subprocess.run([sys.executable,str(KIT/'tests/fixtures/install_worker_skills.py'),str(self.root)],check=True)
        self.state = self.base/'state.json'; self.calls = self.base/'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], HOME=str(self.home),
                        SUPER_BOARD_SKILLS_HOME=str(self.home), FIXTURE_STATE=str(self.state), FIXTURE_CALLS=str(self.calls),
                        SB_GITHUB_RETRY_DELAY='0', SB_GITHUB_HALT_FILE=str(self.base/'github-halt.json'))
        for name,code in [('gh',GH),('codex',HOST),('pi',HOST)]:
            target=self.bin/name;target.write_text('#!/usr/bin/env python3\n'+code);target.chmod(0o755)
        self.config=self.base/'config.json'
        self.config.write_text(json.dumps(dict(max_workers=1,verify_commands=['git diff --check'],rebuild_cap=2,
                                              project=dict(owner='fixture',number=1),repo=dict(remote='fixture/repo'),
                                              pi=dict(provider='fixture',model='fixture'))))
        self.reset()

    def reset(self):
        self.state.write_text(json.dumps(dict(comments=[],labels=['docs'],repo_labels=['docs'],label_edits=[],blocks=[],board='Ready')))
        self.calls.write_text('')
        lock=self.root/'.claude/super-board/inflight/1';lock.unlink(missing_ok=True)

    def data(self):return json.loads(self.state.read_text())
    def repair(self):
        record=next(c for c in self.data()['comments'] if '<!-- super-board:repair -->' in c['body'])
        return json.loads(re.search(r'^repair-state: (.+)$',record['body'],re.M)[1])
    def call_log(self):return [json.loads(x) for x in self.calls.read_text().splitlines()]
    def wave(self,host,**env):
        card=dict(number=1,status='Ready',labels=self.data()['labels'],body='')
        process=subprocess.run(['bash',str(self.root/'.claude/bin/super-board-codex-wave.sh'),'--config',str(self.config),
                                '--cards',json.dumps([card]),'--pi' if host=='pi' else '--codex=fixture'],
                               cwd=self.root,env=dict(self.env,**env),capture_output=True,text=True,timeout=30)
        self.assertIn(process.returncode,[0,79],process.stderr+'\n'+process.stdout)
        return process,json.loads(process.stdout)
    def two_repairs(self,host):
        for expected in [0,1,2]:
            self.wave(host)
            self.assertEqual(self.repair()['repairs'],expected)
            self.assertEqual(self.repair()['phase'],'idle')
            self.assertEqual([x for x in self.data()['labels'] if x.startswith('loop:repair-')],[])
            self.assertIn(f'loop:rebuild-{expected}',self.data()['labels'])
        self.assertEqual(len(self.call_log()),3)
        self.assertEqual([x['phase'] for x in self.call_log()],[None,'reserved','reserved'])

    def assert_blocked(self,result):
        self.assertEqual(result['cards'][0]['column'],'Blocked')
        data=self.data();self.assertEqual(data['board'],'Blocked');self.assertEqual(self.repair()['phase'],'exhausted')
        self.assertEqual(len(data['comments']),1)
        self.assertIn('Owner: fixture',data['blocks'][-1]);self.assertIn('To unblock:',data['blocks'][-1])
        self.assertEqual([x for x in data['labels'] if x.startswith('loop:repair-')],['loop:repair-exhausted'])
        for call in self.call_log():
            phase=call['phase']
            self.assertEqual([x for x in call['labels'] if x.startswith('loop:repair-')],
                             ['loop:repair-'+phase] if phase in ('diagnosis','final') else [])

    def test_both_hosts_initial_failure_without_phase_labels_persists_zero_before_next_dispatch(self):
        for host in ['codex','pi']:
            with self.subTest(host=host):
                self.reset()
                process,result=self.wave(host)
                self.assertEqual(process.returncode,0,process.stderr)
                self.assertFalse(result['halted'])
                self.assertEqual(result['cards'][0]['finalStatus'],'failed')
                self.assertEqual(self.repair()['repairs'],0)
                self.assertEqual(self.repair()['phase'],'idle')
                self.assertEqual(len(self.data()['comments']),1)
                self.assertEqual(self.data()['labels'],['docs','loop:rebuild-0'])
                self.assertEqual(self.data()['repo_labels'],['docs','loop:rebuild-0'])
                self.wave(host)
                self.assertEqual([x['repairs'] for x in self.call_log()],[None,1])
                self.assertEqual([x['phase'] for x in self.call_log()],[None,'reserved'])
                self.assertEqual(len(self.data()['comments']),1)

    def test_both_hosts_unknown_label_mutation_halts_without_replay(self):
        for host in ['codex','pi']:
            with self.subTest(host=host):
                self.reset()
                process,result=self.wave(host,FIXTURE_LABEL_EDIT_UNKNOWN='1')
                self.assertIn('connection lost after label mutation',process.stderr)
                self.assertEqual(process.returncode,79)
                self.assertTrue(result['halted'])
                self.assertEqual(result['cards'][0]['finalStatus'],'halted')
                self.assertEqual(self.repair()['repairs'],0)
                self.assertEqual(len(self.data()['comments']),1)
                self.assertEqual(len(self.data()['label_edits']),1)
                lock=self.root/'.claude/super-board/inflight/1';claim=lock.read_text()
                self.wave(host)
                self.assertEqual(len(self.call_log()),1)
                self.assertEqual(len(self.data()['label_edits']),1)
                self.assertEqual(lock.read_text(),claim)

    def test_successful_completions_retain_counts_and_clear_phase_labels(self):
        def event(name,**options):
            command=[sys.executable,str(self.root/'.claude/bin/super-board-repair.py'),name,
                     '--issue','1','--owner','owner']
            for key,value in options.items():command.extend(['--'+key.replace('_','-'),value])
            result=subprocess.run(command,cwd=self.root,env=self.env,capture_output=True,text=True,check=True)
            return json.loads(result.stdout)
        event('failed',cause='failure',pending_lane='build')
        for count in (1,2):
            reserved=event('reserve');self.assertEqual(reserved['repairs'],count)
            completed=event('succeeded')
            self.assertEqual((completed['phase'],completed['repairs']),('idle',count))
            self.assertNotIn('owner',completed)
            self.assertEqual([x for x in self.data()['labels'] if x.startswith('loop:repair-')],[])
        self.assertEqual(event('reserve')['phase'],'diagnosis')
        event('diagnosed',cause='new cause',test='test -f proof expects failure')
        self.assertEqual(event('reserve')['phase'],'final')
        self.assertEqual([x for x in self.data()['labels'] if x.startswith('loop:repair-')],['loop:repair-final'])
        completed=event('succeeded')
        self.assertEqual((completed['phase'],completed['repairs']),('idle',2))
        self.assertTrue(completed['diagnosis_used']);self.assertTrue(completed['final_used'])
        self.assertEqual([x for x in self.data()['labels'] if x.startswith('loop:repair-')],[])
        self.assertIn('docs',self.data()['labels']);self.assertEqual(len(self.data()['comments']),1)

    def test_both_hosts_diagnosis_without_new_cause_blocks_without_final(self):
        for host in ['codex','pi']:
            with self.subTest(host=host):
                self.reset();self.two_repairs(host)
                _,result=self.wave(host)
                self.assert_blocked(result)
                self.assertTrue(self.repair()['diagnosis_used']);self.assertFalse(self.repair().get('final_used',False))
                self.assertEqual([x['diagnosis'] for x in self.call_log()],[False,False,False,True])

    def test_both_hosts_fresh_cause_allows_exactly_one_final_failed_repair(self):
        for host in ['codex','pi']:
            with self.subTest(host=host):
                self.reset();self.two_repairs(host)
                _,result=self.wave(host,FIXTURE_DIAG='new')
                self.assert_blocked(result)
                self.assertTrue(self.repair()['final_used']);self.assertEqual(self.repair()['repairs'],2)
                self.assertEqual([x['diagnosis'] for x in self.call_log()],[False,False,False,True,False])
                self.assertEqual([x['phase'] for x in self.call_log()],[None,'reserved','reserved','diagnosis','final'])
                self.wave(host,FIXTURE_DIAG='new')
                self.assertEqual(len(self.call_log()),5, 'restart cannot repeat an exhausted final repair')

    def test_both_hosts_invalid_or_provider_failed_diagnosis_blocks(self):
        for host in ['codex','pi']:
            for mode in ['malformed','provider']:
                with self.subTest(host=host,mode=mode):
                    self.reset();self.two_repairs(host)
                    _,result=self.wave(host,FIXTURE_DIAG=mode)
                    self.assert_blocked(result);self.assertFalse(self.repair().get('final_used',False))
                    self.assertEqual(len(self.call_log()),4)

    def test_both_hosts_halted_reservation_survives_restart_and_reconciliation_consumes_it(self):
        for host in ['codex','pi']:
            with self.subTest(host=host):
                self.reset();self.wave(host)
                process,result=self.wave(host,FIXTURE_RESULT='halted')
                self.assertEqual(process.returncode,79);reserved=self.repair()
                self.assertEqual((reserved['phase'],reserved['repairs']),('reserved',1))
                lock=self.root/'.claude/super-board/inflight/1';claim=lock.read_text()
                self.wave(host);self.assertEqual(len(self.call_log()),2);self.assertEqual(lock.read_text(),claim)
                # Fixture operator has reconciled the stopped process and preserved worktree.
                reconciled=subprocess.run([sys.executable,str(self.root/'.claude/bin/super-board-repair.py'),'interrupted',
                                           '--issue','1','--owner',reserved['owner']],cwd=self.root,env=self.env,
                                          capture_output=True,text=True,check=True)
                self.assertEqual(json.loads(reconciled.stdout)['repairs'],1)
                lock.unlink();self.wave(host)
                self.assertEqual(self.repair()['repairs'],2);self.assertEqual(len(self.call_log()),3)

if __name__=='__main__':unittest.main()
