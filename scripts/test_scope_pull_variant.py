import copy
import unittest

from scope_pull_variant import with_adc_pulls


class PullVariantTest(unittest.TestCase):
    def fixture(self):
        cells = {f'reversed_name_{7-i}': dict(type='IBUF', connections={'I': [10+i]},
                  attributes={'&IO_TYPE=LVCMOS33': '1', '&PULL_MODE=NONE': '1',
                              'NEXTPNR_BEL': f'pin{i}'}) for i in range(8)}
        cells['other_input'] = dict(type='IBUF', connections={'I': [99]},
                                   attributes={'&PULL_MODE=NONE': '1'})
        return dict(modules={'top': dict(ports={'adc_d': dict(direction='input', bits=list(range(10,18)))},
                                         cells=cells, netnames={'route': 'unchanged'})})

    def test_only_resolved_adc_pulls_change(self):
        original = self.fixture()
        before = copy.deepcopy(original)
        changed = with_adc_pulls(original, 'UP')
        self.assertEqual(original, before)
        self.assertEqual(changed['modules']['top']['cells']['other_input'],
                         original['modules']['top']['cells']['other_input'])
        self.assertEqual(with_adc_pulls(changed, 'NONE'), original)
        self.assertEqual(sum('&PULL_MODE=UP' in c['attributes']
                             for c in changed['modules']['top']['cells'].values()), 8)

    def test_rejects_invalid_target(self):
        design = self.fixture()
        design['modules']['top']['ports']['adc_d']['direction'] = 'output'
        with self.assertRaises(ValueError):
            with_adc_pulls(design, 'UP')


if __name__ == '__main__':
    unittest.main()
