#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Refuse signing/output directories writable through another local principal."""
import ctypes
import errno
import os
from pathlib import Path
import stat
import sys


def check(path):
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
    libc.acl_get_file.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    libc.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    libc.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    libc.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libc.acl_free.argtypes = [ctypes.c_void_p]
    for current in (path, *path.parents):
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        sticky = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not sticky):
            raise ValueError(f'Unsafe release directory: {current}')
        acl = libc.acl_get_file(os.fsencode(current), 0x100)
        if not acl:
            if ctypes.get_errno() == errno.ENOENT:
                current.lstat()
                continue
            raise ValueError(f'Cannot inspect release directory ACL: {current}')
        try:
            entry = ctypes.c_void_p()
            selector = 0
            while libc.acl_get_entry(acl, selector, ctypes.byref(entry)) == 0:
                selector = -1
                tag = ctypes.c_int()
                perms = ctypes.c_void_p()
                if libc.acl_get_tag_type(entry, ctypes.byref(tag)) or libc.acl_get_permset(entry, ctypes.byref(perms)):
                    raise ValueError(f'Cannot inspect release directory ACL: {current}')
                if tag.value == 1:
                    for bit in (2, 4, 5, 6, 8, 10, 12, 13):
                        if libc.acl_get_perm_np(perms, 1 << bit) != 0:
                            raise ValueError(f'Mutable release directory ACL: {current}')
        finally:
            libc.acl_free(acl)


if __name__ == '__main__':
    try:
        # Resolve only platform aliases. Do not erase an untrusted output symlink.
        path = Path(os.path.abspath(sys.argv[1]))
        if str(path).startswith('/var/'):
            path = Path('/private') / path.relative_to('/')
        check(path)
    except (OSError, ValueError) as error:
        sys.exit(str(error))
