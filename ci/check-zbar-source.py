#!/usr/bin/env python3
"""Fail in minutes, not after the 25-minute media build, if zbar cannot be built.

Cerbero fetches zbar at step 31 of 85. The recipe's old URL began serving a
different file, which only showed once the build got there. This downloads the
recipe's tarball now, checks the pinned SHA-256, checks the top-level folder
Cerbero expects, and applies Cerbero's own zbar patches to it the way Cerbero does
(commit the unpacked tree, then `git am --ignore-whitespace`). A looser `patch`
dry run passed on a tarball that `git am` then refused, so this must use git.

Usage: check-zbar-source.py CERBERO_CHECKOUT [--archive FILE]
--archive uses a local file instead of downloading (for tests).
"""
from pathlib import Path
import hashlib
import re
import subprocess
import sys
import tarfile
import tempfile


def main(argv):
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != '--archive'):
        raise SystemExit(__doc__)
    cerbero = Path(argv[1])
    recipe = (cerbero / 'recipes/zbar.recipe').read_text()
    version = re.search(r"^\s*version = '([^']+)'", recipe, re.M).group(1)
    url = re.search(r"^\s*url = '([^']+)'", recipe, re.M).group(1) % {'version': version}
    checksum = re.search(r"^\s*tarball_checksum = '([0-9a-f]{64})'", recipe, re.M).group(1)
    patches = re.findall(r"f'\{name\}/([^']+\.patch)'", recipe)
    if not patches:
        raise SystemExit('zbar recipe lists no patches; check this script against the recipe')

    with tempfile.TemporaryDirectory(prefix='zbar-source-') as directory:
        work = Path(directory)
        if len(argv) == 4:
            archive = Path(argv[3])
        else:
            archive = work / 'zbar.tar.gz'
            print(f'Downloading {url}')
            subprocess.run(['curl', '-L', '--fail', '--retry', '2', '--connect-timeout', '20',
                            '--silent', '--show-error', '-o', str(archive), url], check=True)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        print(f'SHA-256 {actual} ({archive.stat().st_size} bytes)')
        if actual != checksum:
            raise SystemExit(f'zbar tarball checksum is {actual}, recipe pins {checksum}')

        source = work / 'source'
        source.mkdir()
        with tarfile.open(archive) as tar:
            tops = {name.split('/')[0] for name in tar.getnames() if name not in ('.', './')}
            expected = f'zbar-{version}'
            if tops != {expected}:
                raise SystemExit(f'zbar tarball unpacks to {sorted(tops)}, Cerbero expects {expected}')
            tar.extractall(source, filter='data')
        tree = source / expected
        git = ['git', '-c', 'user.email=check@example.invalid', '-c', 'user.name=check',
               '-c', 'init.defaultBranch=main', '-c', 'core.autocrlf=false']
        for step in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'unpacked source']):
            subprocess.run(git + step, cwd=tree, check=True, capture_output=True)
        for name in patches:
            patch = (cerbero / 'recipes/zbar' / name).resolve()
            result = subprocess.run(git + ['am', '--ignore-whitespace', str(patch)],
                                    cwd=tree, capture_output=True, text=True)
            if result.returncode != 0:
                raise SystemExit(f'Cerbero patch {name} does not apply to this zbar tarball:\n'
                                 + result.stdout + result.stderr)
            print(f'{name} applies')
    print('PASS: zbar tarball matches its checksum, unpacks as expected and takes the Meson patch with git am')


if __name__ == '__main__':
    main(sys.argv)
