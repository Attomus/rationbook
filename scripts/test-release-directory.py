#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise release-directory admission without building or signing anything."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('release_directory', Path(__file__).with_name('release-directory.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix='rationbook-release-test-') as temporary:
    root = Path(temporary).resolve()
    module.check(root)
    target = root / 'target'
    target.mkdir(mode=0o700)
    link = root / 'dist'
    link.symlink_to(target)
    unsafe = root / 'shared'
    unsafe.mkdir(mode=0o700)
    unsafe.chmod(0o777)
    acl = root / 'acl'
    acl.mkdir(mode=0o700)
    subprocess.run(['/bin/chmod', '+a', 'everyone allow delete_child', str(acl)], check=True)
    for path in (link, unsafe / 'missing', acl):
        try:
            module.check(path)
        except ValueError:
            pass
        else:
            raise AssertionError(f'Accepted unsafe release path: {path}')
    assert not list(target.iterdir())
print('Release-directory admission checks passed')
