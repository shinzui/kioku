#!/usr/bin/env python3
"""Compare source-bearing non-Kioku identities in two Cabal plans."""
import argparse
import hashlib
import json
from pathlib import Path


def identities(path):
    plan = json.loads(path.read_text())
    by_id = {row['id']: row for row in plan['install-plan']}
    # Exported libraries (including test-support) and executables define the
    # consumer runtime closure. Local application test roots are qualified by
    # the full build/test gate, but are absent from archive library consumers.
    pending = [row['id'] for row in plan['install-plan']
               if row['pkg-name'].startswith('kioku-')
               and row.get('component-name', '').startswith(('lib', 'exe:'))]
    reachable = set()
    while pending:
        unit = pending.pop()
        if unit in reachable:
            continue
        reachable.add(unit)
        pending.extend(by_id[unit].get('depends', []))
    packages = {}
    boot = []
    for row in plan['install-plan']:
        if row['id'] not in reachable or row['pkg-name'].startswith('kioku-'):
            continue
        if row['type'] == 'pre-existing':
            # Only compiler-supplied boot units may lack source identities.
            allowed = {'base', 'ghc', 'ghc-internal', 'ghc-prim', 'ghc-bignum',
                       'ghc-boot', 'ghc-boot-th', 'ghc-heap', 'ghc-toolchain',
                       'ghci', 'rts', 'template-haskell', 'Cabal-syntax', 'Cabal',
                       'array', 'binary', 'bytestring', 'containers', 'deepseq',
                       'directory', 'exceptions', 'filepath', 'haskeline', 'hpc',
                       'file-io', 'ghc-compact', 'ghc-experimental', 'ghc-platform',
                       'haddock-api', 'haddock-library', 'xhtml', 'integer-gmp', 'mtl', 'os-string', 'parsec', 'pretty',
                       'process', 'semaphore-compat', 'stm', 'system-cxx-std-lib',
                       'terminfo', 'text', 'time', 'transformers', 'unix'}
            assert row['pkg-name'] in allowed, 'unexplained installed runtime unit: ' + row['pkg-name']
            boot.append({key: row.get(key) for key in ['pkg-name', 'pkg-version', 'id']})
            continue
        assert row.get('pkg-src-sha256'), 'missing source hash: ' + row['pkg-name']
        assert row.get('pkg-cabal-sha256'), 'missing revised Cabal hash: ' + row['pkg-name']
        key = row['pkg-name'] + ':' + row.get('component-name', 'lib')
        packages[key] = {field: row.get(field) for field in
                         ['pkg-name', 'pkg-version', 'pkg-src', 'pkg-src-sha256',
                          'pkg-cabal-sha256', 'flags']}
    return {'compiler': plan['compiler-id'], 'abi': plan.get('compiler-abi'),
            'os': plan['os'], 'arch': plan['arch'], 'packages': packages,
            'boot': sorted(boot, key=lambda r: r['pkg-name'])}


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('candidate', type=Path)
parser.add_argument('comparison', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
a, b = identities(args.candidate), identities(args.comparison)
if a != b:
    for key in set(a['packages']) | set(b['packages']):
        if a['packages'].get(key) != b['packages'].get(key):
            print('source mismatch:', key)
    raise SystemExit('compiler, platform, boot units or runtime source identities differ')
encoded = json.dumps(a, sort_keys=True, indent=2) + '\n'
if args.output:
    args.output.write_text(encoded)
print('source identity parity:', len(a['packages']), 'components;', hashlib.sha256(encoded.encode()).hexdigest())
