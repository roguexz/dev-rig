"""JSONC helpers shared by ldx scripts (import with PYTHONPATH=bin/lib)."""

import json
import re


def strip_trailing_commas(text):
    """Remove commas dangling before a closing brace/bracket."""
    return re.sub(r",(\s*[}\]])", r"\1", text)


def strip_comments(raw):
    """Remove // and /* */ comments from JSONC text.

    String-aware: a naive regex would eat the "//" in https:// URLs inside
    strings. Newlines inside block comments are preserved so JSON error
    positions still match the original text.

    Returns (stripped_text, had_comments).
    """
    out = []
    had = False
    in_str = esc = False
    i, n = 0, len(raw)
    while i < n:
        c = raw[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and raw[i + 1] == "/":
            had = True
            while i < n and raw[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and raw[i + 1] == "*":
            had = True
            end = raw.find("*/", i + 2)
            stop = n if end == -1 else end + 2
            out.append("".join(ch if ch == "\n" else " " for ch in raw[i:stop]))
            i = stop
            continue
        out.append(c)
        i += 1
    return "".join(out), had


def loads(raw):
    """Parse JSONC text (// and /* */ comments, trailing commas allowed)."""
    stripped, _ = strip_comments(raw)
    return json.loads(strip_trailing_commas(stripped))
