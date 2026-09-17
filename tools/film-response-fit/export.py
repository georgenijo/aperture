"""Export a fit.json as the Swift recipe literal and the Swift-parity fixture.

usage: python export.py $FIT_DIR/fit.json [path/to/ApertureTests/Fixtures/film-response-probes.json]
Prints the `FilmResponseStage(...)` literal to paste into FilmRecipeCatalog.
Parameters are rounded to six decimals so the literal, the fixture, and the
probes all describe exactly the same response.
"""
import json, sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from model import *
f = json.load(open(sys.argv[1])); j = f['params']
r6 = lambda a: np.round(np.array(a, dtype=float), 6)
p = Params(); p.matrix = r6(j['matrix']); p.curves = r6(j['curves']); p.sat = r6(j['saturation'])
p.hueChroma = r6(j['hueChroma']); p.hueRotate = r6(j['hueRotate']); p.hueLight = r6(j['hueLight'])
rng = np.random.default_rng(1998)
grid = np.array([[r, g, b] for r in np.linspace(0, 1, 5) for g in np.linspace(0, 1, 5) for b in np.linspace(0, 1, 5)])
rand = np.round(rng.random((400, 3)), 6); greys = np.tile(np.linspace(0, 1, 17)[:, None], (1, 3))
probes = np.concatenate([grid, rand, greys]); outs = apply(p, probes)
resp = dict(matrix=[float(x) for x in p.matrix.ravel()], curves=[[float(x) for x in c] for c in p.curves],
            saturation=[float(x) for x in p.sat], hueChroma=[float(x) for x in p.hueChroma],
            hueRotate=[float(x) for x in p.hueRotate], hueLight=[float(x) for x in p.hueLight])
fixture = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), '..', '..', 'ApertureTests', 'Fixtures', 'film-response-probes.json')
json.dump(dict(response=resp, probes=[dict(input=[float(x) for x in i], output=[float(x) for x in o]) for i, o in zip(probes, outs)]),
          open(fixture, 'w'), indent=1)
def fl(v): return ', '.join(f'{x:.6f}' for x in v)
print('FilmResponseStage(\n          matrix: [' + ',\n            '.join(fl(p.matrix[i]) for i in range(3)) + '],\n          curves: [\n'
      + ''.join(f'            [{fl(c)}],\n' for c in p.curves) + '          ],\n          saturation: [' + fl(p.sat) + '],\n          hueChroma: ['
      + fl(p.hueChroma) + '],\n          hueRotate: [' + fl(p.hueRotate) + '],\n          hueLight: [' + fl(p.hueLight) + '])')
print(f'# fixture written to {fixture} ({len(probes)} probes)', file=sys.stderr)
