#!/usr/bin/env python3
"""Build the probe with exact units from an already built, isolated Cabal plan."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('build_dir', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--store-dir', type=Path)
args = parser.parse_args()
plan_path = args.build_dir.resolve() / 'cache/plan.json'
plan = json.loads(plan_path.read_text())
needed = {'kioku-api', 'kioku-core', 'keiro', 'keiro-core', 'kiroku-store',
          'shibuya-core', 'shibuya-kiroku-adapter', 'effectful', 'aeson',
          'bytestring', 'containers', 'text', 'time', 'uuid', 'vector',
          'process', 'directory', 'filepath'}
units = [row for row in plan['install-plan']
         if row['pkg-name'] in needed and row.get('component-name', 'lib') == 'lib']
assert {row['pkg-name'] for row in units} == needed, 'missing probe library unit'
for row in units:
    if row['pkg-name'].startswith('kioku-'):
        assert Path(row['pkg-src']['path']).resolve().is_relative_to(Path.cwd()), \
            'local library escaped the selected working tree'
source = Path(__file__).with_name('kioku-upgrade-probe.hs').resolve()
output = args.output.resolve()
assert not output.exists(), 'refusing to replace a retained probe'
output.parent.mkdir(parents=True, exist_ok=True)
command = ['cabal']
if args.store_dir:
    command += ['--store-dir=' + str(args.store_dir.resolve())]
command += ['exec', '--builddir=' + str(args.build_dir.resolve()), '--',
            'ghc', '-XGHC2024', '-threaded', '-outputdir', str(output) + '.objects']
for unit in units:
    command += ['-package-id', unit['id']]
command += [str(source), '-o', str(output)]
subprocess.run(command, check=True)
identity = {'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'binarySha256': hashlib.sha256(output.read_bytes()).hexdigest(),
            'planSha256': hashlib.sha256(plan_path.read_bytes()).hexdigest(),
            'compiler': plan['compiler-id'], 'units': units, 'command': command}
Path(str(output) + '.identity.json').write_text(json.dumps(identity, indent=2) + '\n')
print(output)
