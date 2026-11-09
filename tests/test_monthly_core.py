import unittest,tempfile,sys,json
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'collector'))
from monthly_core import Queue,months,safe_name,validate
from openpyxl import Workbook
class CoreTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.q=Queue(self.root/'q.sqlite');self.roster=[dict(id='a',name='홍길동B',employment='퇴사',effective_date='2026-07-01')]
 def tearDown(self):self.q.db.close();self.temp.cleanup()
 def book(self,name='홍길동B',month='2026년 01월'):
  p=self.root/'report.xlsx';w=Workbook();w.active.append([name+'님의 안전운전수준',month]);w.save(p);return p
 def test_period(self):
  self.assertEqual(months('2025-12','2026-02'),['2025-12','2026-01','2026-02'])
  for a,b in [('2026-13','2026-13'),('2026-02','2026-01'),('2099-01','2099-02')]:
   with self.assertRaises(ValueError):months(a,b)
 def test_plan_resume(self):
  self.q.plan(self.roster,'2026-01','2026-02');self.assertEqual(len(self.q.rows()),4)
  self.q.mark(1,'보류','퇴사 확인');self.q.plan(self.roster,'2026-01','2026-02');self.assertEqual(self.q.get(1)['status'],'보류')
  self.assertEqual(self.q.get(1)['employment'],'퇴사')
 def test_names(self):
  for name in ['../a','a\\b','NUL','a:','']:
   with self.assertRaises(ValueError):safe_name(name)
 def test_identity(self):
  path=self.book();validate(path,'홍길동B','2026-01')
  with self.assertRaises(ValueError):validate(path,'홍길동','2026-01')
  with self.assertRaises(ValueError):validate(path,'홍길동B','2026-02')
 def test_atomic_duplicate(self):
  self.q.plan(self.roster,'2026-01','2026-01');p=self.book();task=[r for r in self.q.rows() if r['kind']=='excel'][0]
  saved=self.q.store(task['id'],p,self.root);self.assertTrue(saved.exists());self.assertEqual(self.q.get(task['id'])['status'],'완료')
  self.q.store(task['id'],p,self.root)
  w=Workbook();w.active.append(['홍길동B님의','2026년 01월','changed']);w.save(p)
  with self.assertRaises(ValueError):self.q.store(task['id'],p,self.root)
 def test_disk_failure(self):
  self.q.plan(self.roster,'2026-01','2026-01');p=self.book();task=[r for r in self.q.rows() if r['kind']=='excel'][0]
  with patch('monthly_core.shutil.copyfile',side_effect=OSError('disk full')):
   with self.assertRaises(OSError):self.q.store(task['id'],p,self.root)
  self.assertNotEqual(self.q.get(task['id'])['status'],'완료');self.assertFalse(list(self.root.rglob('.pending-*')))
 def test_roster_duplicates(self):
  with self.assertRaises(ValueError):self.q.plan(self.roster*2,'2026-01','2026-01')
  self.assertEqual(len(self.q.rows()),0)
if __name__=='__main__':unittest.main()
