import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('collector', Path(__file__).resolve().parents[1] / 'collector/daewoon_collector.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
c.log = lambda *a, **k: None

class FleetTests(unittest.TestCase):
    def setUp(self):
        self.a, self.b, self.foreign = '경남71자1100', '경남71자1101', '경남71자5038'
        self.fleet = {self.a, self.b}
        self.rows = [{'vehicle_no': self.a, 'run_order': 1}]
        self.state = {}
    def infer(self, live, fleet=None):
        return c.infer_changes('111', self.rows, [{'vehicle': x, 'node_order': 10} for x in live], self.state, {}, 'test', self.fleet if fleet is None else fleet)
    def test_foreign_never_pairs(self):
        for _ in range(4):
            changes, summary = self.infer([self.foreign])
            self.assertEqual(changes, [])
            self.assertEqual(summary['live'], 0)
    def test_owned_substitution_remains(self):
        self.assertEqual(self.infer([self.b, self.foreign])[0], [])
        changes, summary = self.infer([self.b, self.foreign])
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]['actual_vehicle'], self.b)
        self.assertEqual(summary['live'], 1)
    def test_roster_change_clears_candidates(self):
        self.infer([self.b])
        self.assertEqual(self.infer([self.b], {self.a})[0], [])
        self.assertEqual(self.infer([self.b])[0], [])
    def test_missing_fleet_blocks(self):
        for ctx in ({}, {'fleet': {'vehicles': []}}, {'fleet': {'vehicles': ['1100']}}):
            with self.assertRaises(RuntimeError): c.fleet_vehicles(ctx)
        with self.assertRaises(RuntimeError): self.infer([self.foreign], set())
    def test_legacy_state_cleared(self):
        self.state['bis_routes'] = {'old': {'replacements': {self.a: self.foreign}}}
        self.infer([self.a])
        self.assertNotIn('old', self.state['bis_routes'])
    def test_normalization(self):
        self.assertEqual(self.infer(['경남 71 자 1100', self.foreign])[1]['live'], 1)
        self.assertEqual(c.normalize_vehicle('1100'), self.a)

if __name__ == '__main__': unittest.main()
