#!/usr/bin/env python3
"""Structural sanity check for the plugin's QML files.

Deliberately tiny and dependency-free — this runs in CI on every push and must
never fail for a reason the author cannot reproduce locally. It is not a
replacement for qmllint (which needs the Omarchy shell's singletons on the
import path), just a guard against the class of breakage that a QML editor or a
careless merge actually causes:

  * unbalanced {}, () or [] outside strings and comments — the failure mode that
    produces a blank panel with a single line of noise in the shell log
  * tab characters (Qt's QML parser rejects them in several positions and they
    fight the two-space style used throughout these files)
  * trailing whitespace
  * a missing final newline
  * two methods of the same name declared in the same scope — QML rejects the
    file outright ("Duplicate method name"), so the object silently fails to
    instantiate and the widget disappears from the bar

Every *.qml in the plugin root is checked by default, so a newly added file is
covered without having to remember to register it here.

Usage:  python3 tools/qml_lint.py [file.qml ...]
Exits non-zero and prints one line per finding.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
DEFAULT_FILES = sorted(glob.glob(os.path.join(PLUGIN, "*.qml")))

PAIRS = {"}": "{", ")": "(", "]": "["}
OPENERS = set(PAIRS.values())

# A method declaration at the start of a line. Named function *expressions*
# inside a body are not matched by this, since they are indented further.
METHOD_RE = re.compile(r"^(\s*)function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def check(path):
    problems = []
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    if not src.endswith("\n"):
        problems.append("missing final newline")
    for num, line in enumerate(src.split("\n"), 1):
        if "\t" in line:
            problems.append("line %d: tab character" % num)
        if line != line.rstrip():
            problems.append("line %d: trailing whitespace" % num)

    # Two methods of the same name in the same scope. QML rejects the whole file
    # with "Duplicate method name", so the object fails to instantiate and its
    # widget silently vanishes from the bar. Scope is approximated by
    # indentation: a nested component's methods are indented further and may
    # legitimately reuse a name from the enclosing object.
    seen_methods = {}
    in_block = False
    for num, line in enumerate(src.split("\n"), 1):
        stripped = line.strip()
        if in_block:
            if "*/" not in stripped:
                continue
            in_block = False
            stripped = stripped.split("*/", 1)[1]
        if stripped.startswith("/*"):
            in_block = "*/" not in stripped[2:]
            continue
        if stripped.startswith("//"):
            continue
        match = METHOD_RE.match(line)
        if not match:
            continue
        key = (len(match.group(1)), match.group(2))
        if key in seen_methods:
            problems.append("line %d: duplicate method '%s' (first declared at line %d)"
                            % (num, match.group(2), seen_methods[key]))
        else:
            seen_methods[key] = num

    # Delimiter balance, skipping string literals, both comment styles, and JS
    # regex literals (which legitimately contain unbalanced brackets, e.g.
    # /\[([^\]]+)\]\s*$/). Regex-vs-division uses the standard heuristic: a `/`
    # is a regex start when the previous significant character cannot end an
    # expression.
    stack = []
    i, line, n = 0, 1, len(src)
    prev = ""  # previous significant character, "" at start of file
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r":
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            end = src.find("*/", i + 2)
            if end == -1:
                problems.append("unterminated block comment at line %d" % line)
                break
            line += src.count("\n", i, end)
            i = end + 2
            continue
        if c in ('"', "'"):
            quote = c
            i += 1
            while i < n and src[i] != quote:
                if src[i] == "\\":
                    i += 1
                if i < n and src[i] == "\n":
                    line += 1
                i += 1
            i += 1
            prev = quote
            continue
        if c == "/" and (prev == "" or prev in "([{;,=:?!&|+*%^~<>\n"):
            # Regex literal: consume to the closing unescaped slash, allowing
            # a trailing flag character.
            i += 1
            in_class = False
            while i < n and src[i] != "\n":
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "[":
                    in_class = True
                elif src[i] == "]":
                    in_class = False
                elif src[i] == "/" and not in_class:
                    break
                i += 1
            while i < n and src[i].isalpha():
                i += 1
            prev = "/"
            continue
        if c in OPENERS:
            stack.append((c, line))
        elif c in PAIRS:
            if not stack:
                problems.append("line %d: unmatched '%s'" % (line, c))
            elif stack[-1][0] != PAIRS[c]:
                opener, opened_at = stack[-1]
                problems.append("line %d: '%s' closes '%s' opened at line %d"
                                % (line, c, opener, opened_at))
                stack.pop()
            else:
                stack.pop()
        prev = c
        i += 1
    for opener, opened_at in stack:
        problems.append("line %d: unclosed '%s'" % (opened_at, opener))
    return problems


def main():
    files = sys.argv[1:] or DEFAULT_FILES
    failed = False
    for path in files:
        if not os.path.exists(path):
            print("qml_lint: missing file %s" % path)
            failed = True
            continue
        problems = check(path)
        rel = os.path.relpath(path, PLUGIN)
        for p in problems:
            print("%s: %s" % (rel, p))
            failed = True
        if not problems:
            print("%s: OK" % rel)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()