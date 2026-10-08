#!/usr/bin/env python3
"""Compose trusted Markdown dossiers into offline HTML using external Pandoc."""
import argparse
import html
from pathlib import Path
import re
import shutil
import subprocess

INCLUDE = re.compile(r'<!--\s*forge-include:\s*([^>]+?)\s*-->')
HEADER = Path(__file__).resolve().parents[1] / 'assets' / 'header.html'

def expand(path, root, stack=()):
    path, root = Path(path).resolve(), Path(root).resolve()
    if not path.is_relative_to(root):
        raise ValueError('Include escapes dossier: ' + str(path))
    if path in stack:
        raise ValueError('Include cycle: ' + str(path))
    def replace(match):
        return expand(path.parent / match.group(1).strip(), root, stack + (path,))
    return INCLUDE.sub(replace, path.read_text(encoding='utf-8'))

def build(folder):
    folder = Path(folder).resolve()
    docs = sorted(p for p in folder.glob('*.md')
                  if re.match(r'0[0-4]_', p.name) and not p.stem.endswith('_reviews'))
    if not docs:
        raise ValueError('No numbered dossier Markdown documents found')
    if not shutil.which('pandoc'):
        raise ValueError('HTML requires Pandoc; Markdown remains usable without it')
    outputs = {p.resolve(): p.with_suffix('.html').name for p in docs}
    nav = '<nav aria-label="Dossier">' + ' '.join(
        '<a href="' + html.escape(outputs[p.resolve()], quote=True) + '">' +
        html.escape(p.stem) + '</a>' for p in docs) + '</nav>'
    rendered = []
    for source in docs:
        body = expand(source, folder)
        reviews = source.with_name(source.stem + '_reviews.md')
        if reviews.exists():
            body += '\n\n# Review history\n\n' + expand(reviews, folder)
        def rewrite(match):
            target, sep, fragment = match.group(1).partition('#')
            if '://' not in target and target and not target.startswith('#'):
                absolute = (source.parent / target).resolve()
                if absolute in outputs:
                    return '](' + outputs[absolute] + (sep + fragment if sep else '') + ')'
            return match.group(0)
        body = re.sub(r'\]\(([^)]+)\)', rewrite, body)
        result = subprocess.run(['pandoc', '--from', 'gfm+fenced_divs', '--to', 'html5',
            '--standalone', '--metadata', 'title=' + source.stem,
            '--include-in-header', str(HEADER)], input=body, text=True,
            capture_output=True, check=True)
        page = result.stdout.replace('<body>', '<body>\n' + nav, 1)
        rendered.append((source.with_suffix('.html'), page))
    # Validate and render every source before updating outputs.
    for target, page in rendered:
        target.write_text(page, encoding='utf-8')
        print(target)
    return [p for p, _ in rendered]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder')
    args = parser.parse_args()
    try:
        build(args.folder)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, str(exc) + '\n')

if __name__ == '__main__':
    main()
