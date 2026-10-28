#!/usr/bin/env python3
"""Fail closed when a probe report differs outside the reviewed 0.21 allowance."""
import argparse
import json
from pathlib import Path
import re


def load(directory, name):
    return json.loads((directory / name).read_text())


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def same(a, b, label):
    require(a == b, label + ' differs; retain both reports and investigate')


def schema_dump(directory):
    text = (directory / 'schema.sql').read_text()
    # pg_dump emits a new psql restriction token per invocation, not schema state.
    text = re.sub(r'^\\(?:un)?restrict .*\n', '', text, flags=re.M)
    text = re.sub(r"^COMMENT ON SCHEMA kiroku IS 'Managed by pg-migrate component kiroku through 001[56]';$",
                  '-- reviewed Kiroku schema comment', text, flags=re.M)
    # Validate these definitions separately before removing exactly these two lines.
    text, count = re.subn(r'^    CONSTRAINT subscriptions_(?:target_kind_check|check) CHECK [^\n]*\n',
                          '', text, flags=re.M)
    require(count == 2, 'expected exactly two inline subscription constraints')
    return text


def registration_clocks(snapshot):
    """Released registration upserts these two append cursor clock fields."""
    key = 'keiro.keiro_projection_group_cursors'
    if key in snapshot:
        for row in snapshot[key]:
            if row['group_id'] in {'kioku-memory', 'kioku-session'}:
                require(row['position_basis'] == 'append' and row['subscription_names'] == [],
                        'unexpected cursor semantics')
                require(isinstance(row.get('updated_at'), str), 'missing registration timestamp')
                row.pop('updated_at')
    return snapshot


def migration(before, after):
    old = load(before, 'protected.json')
    new = load(after, 'protected.json')
    require(len(old['pgmigrate.migrations']) == 62, 'one-migration allowance requires a complete 62-entry source')
    require(len(new['pgmigrate.migrations']) == 63, 'candidate must have 63 ledger entries')
    added = [row for row in new['pgmigrate.migrations']
             if (row['component'], row['migration']) == ('kiroku', '0016')]
    require(len(added) == 1 and added[0]['status'] == 'applied', 'expected only applied kiroku/0016')
    new['pgmigrate.migrations'] = [row for row in new['pgmigrate.migrations'] if row not in added]
    same(registration_clocks(old), registration_clocks(new), 'protected rows and historical ledger')
    first = load(before, 'subscription-schema.json')
    second = load(after, 'subscription-schema.json')
    for current, version in [(first, '0015'), (second, '0016')]:
        require(current['comment'] == 'Managed by pg-migrate component kiroku through ' + version,
                'unexpected schema comment')
        prefix = 'kiroku.subscriptions.'
        expected_kind = "CHECK ((target_kind = ANY (ARRAY['unbound'::text, 'all'::text, 'category'::text" + (
            ", 'category_namespace'::text" if version == '0016' else '') + '])))'
        expected_category = ("CHECK (((target_kind = ANY (ARRAY['category'::text, 'category_namespace'::text])) = (target_category IS NOT NULL)))"
                             if version == '0016' else "CHECK (((target_kind = 'category'::text) = (target_category IS NOT NULL)))")
        require(current['constraints'].pop(prefix + 'subscriptions_target_kind_check') == expected_kind,
                'unexpected target-kind constraint definition')
        require(current['constraints'].pop(prefix + 'subscriptions_check') == expected_category,
                'unexpected target-category constraint definition')
    same(first['constraints'], second['constraints'], 'other subscription constraints')
    same(schema_dump(before), schema_dump(after), 'remaining full schema')
    same(load(before, 'read.json'), load(after, 'read.json'), 'public library reads')
    same(load(before, 'cli.json'), load(after, 'cli.json'), 'CLI output')
    for report in [before, after]:
        phase = load(report, 'cli-metadata-phase.json')
        same(registration_clocks(phase['before']), registration_clocks(phase['after']), 'CLI startup metadata')
    print('63-entry migration accepted: only kiroku/0016 and its two constraints/schema comment changed')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('mode', choices=['migration', 'commands', 'rebuild'])
parser.add_argument('before', type=Path)
parser.add_argument('after', type=Path)
args = parser.parse_args()
if args.mode == 'migration':
    migration(args.before, args.after)
elif args.mode == 'commands':
    same(load(args.before, 'commands.json'), load(args.after, 'commands.json'), 'paired command results')
    same(load(args.before, 'cli.json'), load(args.after, 'cli.json'), 'paired CLI output')
    print('paired commands and CLI output agree under the documented normalization')
else:
    def semantic_rows(directory):
        rows = load(directory, 'after.json')
        for row in rows['kioku.sessions']:
            row.pop('created_at', None)
            row.pop('updated_at', None)
        return rows
    same(semantic_rows(args.before), semantic_rows(args.after), 'repeat rebuild rows including enrichment')
    require(load(args.before, 'rebuild.json')['runs'] != load(args.after, 'rebuild.json')['runs'],
            'rebuild reports must identify distinct runs')
    print('two distinct rebuild runs preserve semantic rows and enrichment')
