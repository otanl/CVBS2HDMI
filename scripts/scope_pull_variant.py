#!/usr/bin/env python3
"""Change only ADC input pulls in an already routed, timing-checked netlist.

Resolve the eight inputs by port connectivity, NOT generated cell names (which
can be reversed). Preserve placement, routing, clocks and all other IO settings.
Pack into a separate diagnostic bitstream; restore the original after testing.
"""
import argparse
import copy
import json


def with_adc_pulls(design, mode):
    if mode not in ("UP", "DOWN", "NONE"):
        raise ValueError("pull mode must be UP, DOWN or NONE")
    result = copy.deepcopy(design)
    modules = [m for m in result['modules'].values() if 'adc_d' in m.get('ports', {})]
    if len(modules) != 1:
        raise ValueError("expected exactly one top-level adc_d port")
    module = modules[0]
    port = module['ports']['adc_d']
    if port['direction'] != 'input' or len(port['bits']) != 8 or len(set(port['bits'])) != 8:
        raise ValueError("expected eight distinct ADC inputs")
    for bit in port['bits']:
        cells = [c for c in module['cells'].values()
                 if c['type'] == 'IBUF' and c['connections'].get('I') == [bit]]
        if len(cells) != 1:
            raise ValueError("ADC input does not resolve to exactly one IBUF")
        attrs = cells[0]['attributes']
        if '&IO_TYPE=LVCMOS33' not in attrs or 'NEXTPNR_BEL' not in attrs:
            raise ValueError("expected a placed LVCMOS33 input")
        old = [key for key in attrs if key.startswith('&PULL_MODE=')]
        if len(old) != 1:
            raise ValueError("missing or ambiguous pull attribute")
        value = attrs.pop(old[0])
        attrs['&PULL_MODE='+mode] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input')
    parser.add_argument('output')
    parser.add_argument('mode', choices=['UP', 'DOWN', 'NONE'])
    args = parser.parse_args()
    with open(args.input) as source:
        result = with_adc_pulls(json.load(source), args.mode)
    with open(args.output, 'x') as target:
        json.dump(result, target)


if __name__ == '__main__':
    main()
