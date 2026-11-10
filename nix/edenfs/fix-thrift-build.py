#!/usr/bin/env python3
"""Rewrite a vendored fbthrift/fb303 thrift_build.rs to use absolute paths.

These build scripts are generated for the Meta monorepo layout, e.g.

    .base_path("../../../../..")
    .run(["../../../../annotation/scope.thrift"])

so they find `<repo>/thrift/annotation/scope.thrift` by walking up from the
crate directory.  `importCargoLock` vendors each crate flat, so those walks
leave the repo and fail.  Point both the base path and the input file at a
prepared thrift root instead.  `thrift_compiler` then passes the input to the
compiler relative to the base path, and `-I .` resolves the
`thrift/annotation/...` includes.

Usage: fix-thrift-build.py <thrift_build.rs> <thrift-root>
"""

import re
import sys

path, root = sys.argv[1], sys.argv[2]
src = open(path).read()

src = re.sub(r'\.base_path\("[^"]*"\)', f'.base_path("{root}")', src)


def _map_input(match):
    thrift_file = match.group(1).rsplit("/", 1)[-1]
    if thrift_file == "fb303_core.thrift":
        new_path = f"{root}/{thrift_file}"
    else:
        new_path = f"{root}/thrift/annotation/{thrift_file}"
    return f'.run(["{new_path}"])'


src = re.sub(r'\.run\(\["([^"]+)"\]\)', _map_input, src)
open(path, "w").write(src)
