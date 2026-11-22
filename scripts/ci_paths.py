#!/usr/bin/env python3
"""Conservative CI selection. No API pagination or event paths/300-file limits.

Read git objects only: PRs use merge-base(base, head)..head (all commits), pushes
use before..after. --no-renames exposes both sides of renames and deletions. A
missing/zero endpoint, failed git command, empty diff or unknown path runs all.
The checkout is the ordinary PR merge checkout, never pull_request_target.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SHARED = ('driver', 'flow', 'adapters', 'policy', 'knobs', 'canary')
SUITES = SHARED + ('shipyard', 'council')


def full():
    return dict.fromkeys(SUITES + ('floor', 'check_test'), True)


def classify(paths):
    result = dict.fromkeys(full(), False)
    if not paths:
        return full()
    for path in paths:
        # Explicit prose-only surfaces. Do not use a repo-wide *.md exemption:
        # shipyard tests grep SKILL.md, and operational references are protocols.
        if path in ('README.md', 'AGENTS.md', 'LICENSE'):
            continue
        if path.startswith(('docs/', '.planning/')) and path.endswith('.md'):
            continue
        if path.startswith('plugins/api-design/') and (
            path.endswith('.md') or path in (
                'plugins/api-design/.claude-plugin/plugin.json',
                'plugins/api-design/.codex-plugin/plugin.json')
        ):
            continue
        if path.startswith(('.claude-plugin/', '.agents/plugins/')) and path.endswith('.json'):
            continue
        if path in ('.claude/skills/api-design', '.agents/skills/api-design'):
            continue
        if path.startswith('shared/'):
            # Vendored modules and integration callers cross suite boundaries.
            result.update(dict.fromkeys(SUITES + ('floor',), True))
            continue
        matched = False
        for plugin in ('ship', 'shipyard', 'council'):
            if path.startswith('plugins/' + plugin + '/'):
                matched = True
                if path == 'plugins/' + plugin + '/README.md' or path in (
                    f'plugins/{plugin}/.claude-plugin/plugin.json',
                    f'plugins/{plugin}/.codex-plugin/plugin.json'):
                    break
                # adapters/t-callers executes council and shipyard launchers.
                # ship's protocol is consumed by both operational plugins.
                targets = ('shipyard', 'council', 'adapters') if plugin == 'ship' else (plugin, 'adapters')
                for target in targets:
                    result[target] = True
                result['floor'] = True
                break
        if matched:
            continue
        # scripts (gate, mutation probes, classifier and fixtures), Makefile,
        # workflows and unknown/new executable surfaces fail closed, gate included.
        return full()
    return result


def git(*args):
    return subprocess.check_output(('git', *args), stderr=subprocess.PIPE)


def changed_paths(event_name, event):
    if event_name == 'pull_request':
        base, head = (event['pull_request'][side]['sha'] for side in ('base', 'head'))
    elif event_name == 'push':
        base, head = event['before'], event['after']
    else:
        raise ValueError('unsupported event')
    for ref in (base, head):
        if not re.fullmatch(r'[0-9a-fA-F]{40,64}', ref) or set(ref) == {'0'}:
            raise ValueError('unavailable endpoint')
        git('cat-file', '-e', ref + '^{commit}')
    if event_name == 'pull_request':
        base = git('merge-base', base, head).decode('ascii').strip()
    data = git('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', base, head, '--')
    return [os.fsdecode(path) for path in data.split(b'\0') if path]


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        selection = classify(changed_paths(os.environ['GITHUB_EVENT_NAME'], event))
    except (KeyError, OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
        print('CI selection unavailable; running full coverage: ' + str(error), file=sys.stderr)
        selection = full()
    output = ''.join(f'{key}={str(value).lower()}\n' for key, value in selection.items())
    print(output, end='')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write(output)


if __name__ == '__main__':
    main()
