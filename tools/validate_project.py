"""Static regression checks for Progressive Medals (no Openplanet runtime)."""
from __future__ import annotations

import json
import hashlib
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "plugin"
BASELINE = Path(__file__).resolve().with_name("baseline_manifest.json")
FILES = sorted(ROOT.glob("*.as"))


def assert_balanced(source: str, name: str) -> None:
    """Check matching delimiters outside comments and string literals."""
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    i = 0
    while i < len(source):
        c = source[i]
        if c == '"':
            i += 1
            while i < len(source):
                if source[i] == '\\':
                    i += 2
                    continue
                if source[i] == '"':
                    break
                i += 1
        elif source.startswith('//', i):
            i = source.find('\n', i)
            if i < 0:
                break
        elif source.startswith('/*', i):
            end = source.find('*/', i+2)
            if end < 0:
                raise AssertionError(f"{name}: unclosed block comment")
            i = end + 1
        elif c in '([{':
            stack.append(c)
        elif c in ')]}':
            assert stack and stack.pop() == pairs[c], f"{name}: unmatched {c}"
        i += 1
    assert not stack, f"{name}: unclosed delimiters {stack}"


def comments(source: str):
    # All project comments start with // (no block comments are used).
    for line in source.splitlines():
        match = re.match(r'^\s*//\s*(.*)$', line)
        if match:
            yield match.group(1)


def run() -> None:
    assert len(FILES) == 6, f"Expected six AngelScript files, got {len(FILES)}"
    contents = {p.name: p.read_text('utf-8') for p in FILES}
    all_code = '\n'.join(contents.values())
    for name, content in contents.items():
        assert_balanced(content, name)
        assert not any(ord(c) > 127 for comment in comments(content) for c in comment), \
            f"Non-English or non-ASCII comment in {name}"
    assert 'supabase' not in all_code.lower()
    assert 'GetKeys()' not in contents['TotdBadges.as'].split('void RenderTotdBadges')[1]
    assert 'for (int y = 2021; y <= 2100;' not in all_code
    assert all_code.count('nvg::TexturePattern(') == 1
    assert all_code.count('frame.GetFirstChild("quad-medal")') == 1
    assert all_code.count('GetAccountID()') == 1  # Account logic is centralized.
    assert all_code.count('const string[] ICON_PATHS') == 1
    assert 'MenuTarget' not in all_code and 'IsMenuUid' not in all_code
    assert all_code.count('bool AreValidMedalTimes(') == 1
    assert all_code.count('int HighestBadge(') == 1
    assert 'PML_MenuBadgeSize = 61' in all_code
    assert 'PML_TotdBadgeSize = 56' in all_code
    assert 'pos.x += layout.gridSpacing.x * 0.72f' in all_code
    assert 'pos.y += layout.gridSpacing.y * 0.35f' in all_code

    fall = json.loads((ROOT/'catalog/fall-2026-goals.json').read_text('utf-8'))
    snap = json.loads((ROOT/'catalog/sheet-medals-bootstrap.json').read_text('utf-8'))
    assert len(fall['maps']) == 25
    assert all(set(m) == {'uid'} for m in fall['maps'])
    uids = [m['uid'] for m in fall['maps']]
    assert len(set(uids)) == 25
    published = snap['maps']
    published_by_uid = {m['map_uid']:m for m in published}
    assert all(uid in published_by_uid for uid in uids)
    assert len(published) == 37
    assert sum(m['map_type']=='totd' for m in published) == 12
    for row in published:
        p, e, d = (row[k] for k in ('platinum_ms', 'emerald_ms', 'diamond_ms'))
        assert 0 < d <= e <= p <= 86400000
    assert [published_by_uid[uid]['platinum_ms'] for uid in uids[:2]] == [20143, 21564]
    assert [published_by_uid[uid]['diamond_ms'] for uid in uids[:2]] == [20058, 21425]
    date_example = next(m for m in published if m['map_type']=='totd'
                        and m['release_at_utc'].startswith('2026-11-11'))
    assert (date_example['platinum_ms'], date_example['emerald_ms'],
            date_example['diamond_ms']) == (43258, 42440, 41751)
    assert 41751 < 41885 <= 42440

    baseline = json.loads(BASELINE.read_text('utf-8'))
    assert uids == baseline['fall_order'], 'Campaign UID order changed'
    for name, expected_hash in baseline['checked_unchanged'].items():
        if name == 'catalog/fall-2026-goals.json':
            continue  # The goal-times duplication was intentionally removed.
        actual_hash = hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
        assert actual_hash == expected_hash, f'Unexpected change to {name}'

    lines = sum(len(s.splitlines()) for s in contents.values())
    print(f"PASS: {len(FILES)} AngelScript files, {lines} lines (including blanks/comments)")
    print("PASS: 25 ordered Fall UIDs, 12 snapshot TOTDs, historical exceptions")
    print("PASS: shared drawing/account handling, English code comments, no Supabase")
    print("NOTE: Openplanet compilation and in-game behavior are NOT checked here")


if __name__ == '__main__':
    run()
