#!/usr/bin/env python3
"""Capture actual project verification output and exit status without caching."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

def verify(repo, evidence, command):
    repo, evidence = Path(repo).resolve(), Path(evidence).resolve()
    if not repo.is_dir() or not command:
        raise ValueError('Existing repository and verification command required')
    evidence.mkdir(parents=True, exist_ok=True)
    if any((evidence / name).exists() for name in ('output.log', 'result.json')):
        raise ValueError('Evidence already exists; choose a new directory')
    # Evidence destinations must be new; never erase a prior run.
    with (evidence / 'output.log').open('x', encoding='utf-8') as output:
        result = subprocess.run(command, cwd=repo, stdout=output,
                                stderr=subprocess.STDOUT, check=False)
    revision = subprocess.run(['git', '-C', str(repo), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True, check=False)
    record = {'command': command, 'repo': str(repo), 'exit_code': result.returncode,
              'revision': revision.stdout.strip() if revision.returncode == 0 else None,
              'time': datetime.now(timezone.utc).isoformat(),
              'limits': 'Revision does not identify uncommitted or external state. No reuse.'}
    with (evidence / 'result.json').open('x', encoding='utf-8') as dest:
        json.dump(record, dest, indent=2)
    print(json.dumps(record))
    return result.returncode

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--evidence', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    try:
        return verify(args.repo, args.evidence, command)
    except (ValueError, OSError) as exc:
        parser.exit(1, str(exc) + '\n')

if __name__ == '__main__':
    sys.exit(main())
