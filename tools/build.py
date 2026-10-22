"""Builds the BlockOS release files.

Writes, at the repository root:
  install.lua   single-file installer with every BlockOS file bundled inside
  manifest.cfg  the update manifest read by blockos/lib/updater.lua

Run from anywhere: python tools/build.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXCLUDED_DIRS = {"blockos/data", "blockos/userapps", "blockos/.update"}

# CC: Tweaked's Lua counts every local in scope, including those of enclosing functions,
# against a 200-local limit. Desktop-sized files get close, so builds check for it.
LOCAL_LIMIT = 200
LOCAL_WARNING = 190
TOKEN = re.compile(r"[A-Za-z_]\w*|\.\.\.|\d[\w.]*|\S")


def collect_files():
    files = ["startup.lua"]
    for path in sorted((ROOT / "blockos").rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT).as_posix()
        if any(relative.startswith(excluded + "/") for excluded in EXCLUDED_DIRS):
            continue
        files.append(relative)
    return files


def read_text(relative):
    text = (ROOT / relative).read_text(encoding="utf-8")
    return text.replace("\r\n", "\n")


def long_string(text):
    level = 0
    while "]" + "=" * level + "]" in text:
        level += 1
    equals = "=" * level
    # A newline right after the opening bracket is dropped by Lua, so add one to keep the content exact.
    return "[" + equals + "[\n" + text + "]" + equals + "]"


def lua_quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_tokens(text):
    """Yields (token, line) pairs, skipping comments and string contents."""
    index, line, length = 0, 1, len(text)
    while index < length:
        char = text[index]
        if char.isspace():
            line += char == "\n"
            index += 1
            continue
        bracket = re.match(r"(--)?\[(=*)\[", text[index:index + 64])
        if bracket:
            end = text.index("]" + bracket.group(2) + "]", index) + len(bracket.group(2)) + 2
        elif text.startswith("--", index):
            end = text.find("\n", index)
            end = length if end < 0 else end
        elif char in "\"'":
            end = index + 1
            while text[end] != char:
                end += 2 if text[end] == "\\" else 1
            end += 1
            yield "string", line
        else:
            token = TOKEN.match(text, index).group(0)
            yield token, line
            index += len(token)
            continue
        line += text.count("\n", index, end)
        index = end


def peak_locals(text):
    """Most locals in scope at once, counted across nested functions: (count, line)."""
    tokens = list(lua_tokens(text))
    blocks = [0]
    loops = []
    peak = (0, 0)

    def declare(count, line):
        nonlocal peak
        blocks[-1] += count
        peak = max(peak, (sum(blocks), line))

    index = 0
    while index < len(tokens):
        token, line = tokens[index]
        index += 1
        if token == "local":
            if tokens[index][0] == "function":
                declare(1, line)
                continue
            names = 1
            while tokens[index + 1][0] == ",":
                names += 1
                index += 2
            declare(names, line)
            index += 1
        elif token == "function":
            start = index
            while tokens[index][0] != "(":
                index += 1
            params = 1 if any(name == ":" for name, _ in tokens[start:index]) else 0
            index += 1
            while tokens[index][0] != ")":
                params += bool(re.match(r"[A-Za-z_]", tokens[index][0]))
                index += 1
            index += 1
            blocks.append(0)
            declare(params, line)
        elif token == "for":
            # Loops keep three hidden control variables besides the named ones.
            names = 3
            while tokens[index][0] not in ("=", "in"):
                names += tokens[index][0] != ","
                index += 1
            loops.append(names)
        elif token == "while":
            loops.append(0)
        elif token == "do":
            blocks.append(0)
            if loops:
                declare(loops.pop(), line)
        elif token in ("then", "repeat"):
            blocks.append(0)
        elif token == "elseif":
            blocks.pop()
        elif token == "else":
            blocks[-1] = 0
        elif token in ("end", "until"):
            blocks.pop()
    return peak


def check_locals(files):
    ok = True
    for relative in files:
        if not relative.endswith(".lua"):
            continue
        count, line = peak_locals(read_text(relative))
        if count > LOCAL_LIMIT:
            print(f"error: {relative}:{line} has {count} locals in scope (CC allows {LOCAL_LIMIT})")
            ok = False
        elif count > LOCAL_WARNING:
            print(f"warning: {relative}:{line} has {count} locals in scope (CC allows {LOCAL_LIMIT})")
    return ok


def main():
    version = read_text("blockos/version.txt").strip()
    files = collect_files()
    if not check_locals(files):
        sys.exit(1)

    bundle = "\n".join(
        "Files[" + lua_quote(relative) + "] = " + long_string(read_text(relative))
        for relative in files
    )
    template = read_text("src/installer.lua")
    installer = template.replace('"@VERSION@"', lua_quote(version)).replace("--@FILES@", bundle)
    (ROOT / "install.lua").write_text(installer, encoding="utf-8", newline="\n")

    entries = ",\n".join("\t\t" + lua_quote(relative) for relative in files)
    manifest = "{\n\tVersion = " + lua_quote(version) + ",\n\tFiles = {\n" + entries + "\n\t}\n}\n"
    (ROOT / "manifest.cfg").write_text(manifest, encoding="utf-8", newline="\n")

    size = (ROOT / "install.lua").stat().st_size
    print(f"BlockOS {version}: {len(files)} files, install.lua {size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
