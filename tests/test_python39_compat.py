"""Every module the service imports must be importable under Python 3.9.

Devices in the field run Debian 11, which ships Python 3.9. A PEP 604
annotation like `int | None` is NOT a syntax error there — it parses fine, then
raises `TypeError: unsupported operand type(s) for |` when the annotation is
EVALUATED, which happens as the module is imported. So the module does not
degrade, it stops the service from starting at all.

That took a laundromat offline after an upgrade: the files downloaded
correctly, and the service then crash-looped 63 times on import.

Testing on a Bookworm device (Python 3.11) cannot catch this, which is exactly
why it reached production. Neither can `ast.parse(feature_version=(3, 9))` —
the syntax is legal, only the runtime evaluation fails. So this walks the AST
looking for the pattern directly.

A module with `from __future__ import annotations` is exempt: annotations are
then strings and never evaluated.

setup_pagalava_iot_debian11.sh exists, so Debian 11 is a supported target.
"""
import ast
import pathlib

import pytest

REPO = pathlib.Path(__file__).resolve().parent.parent


def _device_modules():
    # Top-level modules only: these are what land on a device and get imported
    # by the service. tests/ and build tooling run on a dev machine.
    return sorted(REPO.glob("*.py"))


def _has_future_annotations(tree):
    for node in tree.body:
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            if any(a.name == "annotations" for a in node.names):
                return True
    return False


def _pep604_annotations(tree):
    """Annotations using `X | Y`, which 3.9 evaluates and rejects."""
    found = []

    def is_union(node):
        return isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr)

    for node in ast.walk(tree):
        anns = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            anns = [a.annotation for a in node.args.args + node.args.kwonlyargs if a.annotation]
            if node.returns:
                anns.append(node.returns)
        elif isinstance(node, ast.AnnAssign) and node.annotation:
            anns = [node.annotation]
        for ann in anns:
            for sub in ast.walk(ann):
                if is_union(sub):
                    found.append(getattr(sub, "lineno", "?"))
    return found


@pytest.mark.parametrize("path", _device_modules(), ids=lambda p: p.name)
def test_importable_under_python39(path):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    if _has_future_annotations(tree):
        return
    bad = _pep604_annotations(tree)
    assert not bad, (
        f"{path.name} uses `X | Y` annotations at line(s) {bad}. On Debian 11 "
        f"(Python 3.9) this raises TypeError while importing, and the service "
        f"will not start. Use Optional[...] / Union[...], or add "
        f"`from __future__ import annotations`."
    )


def test_the_check_actually_catches_it():
    """Guard the guard: a check that cannot fail is worse than no check."""
    tree = ast.parse("def f(x: int | None = None) -> str | None: ...")
    assert _pep604_annotations(tree), "the detector would not have caught the real bug"


def test_future_import_is_accepted():
    tree = ast.parse("from __future__ import annotations\ndef f(x: int | None = None): ...")
    assert _has_future_annotations(tree)
