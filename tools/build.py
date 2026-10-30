"""Builds the BlockOS release files for each edition.

Writes, at the repository root:
  install.lua             desktop installer with every desktop file bundled inside
  manifest.cfg            desktop update manifest read by blockos/lib/updater.lua
  server-install.lua      BlockOS Server Edition installer (BlockCloud + BlockDrive)
  server-manifest.cfg     Server Edition update manifest
  blockdrive-install.lua  BlockDrive client installer for existing desktop computers
  blockdrive-manifest.cfg BlockDrive client update manifest
  store/packages/blockdrive.lua  BlockDrive for the App Store (app + client library in one file)

Run from anywhere: python tools/build.py
  --list <edition>  print an edition's files and exit (used by tests/run.py)
"""

import fnmatch
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXCLUDED_DIRS = {"blockos/data", "blockos/userapps", "blockos/.update"}

# Each edition: which files it ships, where its version comes from, and what it writes.
# Server Edition carries only what a Data Center computer needs: no desktop, dock, Launchpad
# or bundled apps besides Finder.
EDITIONS = {
    "desktop": {
        "include": ["startup.lua", "blockos/*"],
        "exclude": ["blockos/server/*"],
        "version": "blockos/version.txt",
        "template": "src/installer.lua",
        "installer": "install.lua",
        "manifest": "manifest.cfg",
    },
    "server": {
        "include": [
            "startup.lua",
            "blockos/server/*",
            "blockos/lib/cloud/*",
            "blockos/lib/config.lua",
            "blockos/lib/gfx.lua",
            "blockos/lib/theme.lua",
            "blockos/lib/ui.lua",
            "blockos/lib/sha256.lua",
            "blockos/lib/updater.lua",
            "blockos/lib/logo.lua",
            "blockos/lib/apps.lua",
            "blockos/apps/finder/*",
            "blockos/sys/run.lua",
            "blockos/bin/open.lua",
        ],
        "exclude": [
            "blockos/server/version.txt",
            "blockos/lib/cloud/client.lua",
            "blockos/lib/cloud/transfer.lua",
            "blockos/lib/cloud/drive.lua",
            "blockos/lib/cloud/tasks.lua",
        ],
        "version": "blockos/server/version.txt",
        "template": "src/server-installer.lua",
        "installer": "server-install.lua",
        "manifest": "server-manifest.cfg",
    },
    "blockdrive": {
        "include": ["blockos/lib/cloud/*", "blockos/apps/blockdrive/*", "blockos/bin/bdrive.lua"],
        "exclude": [],
        "version": "blockos/apps/blockdrive/version.txt",
        "template": "src/blockdrive-installer.lua",
        "installer": "blockdrive-install.lua",
        "manifest": "blockdrive-manifest.cfg",
    },
}

# CC: Tweaked's Lua counts every local in scope, including those of enclosing functions,
# against a 200-local limit. Desktop-sized files get close, so builds check for it.
LOCAL_LIMIT = 200
LOCAL_WARNING = 190
TOKEN = re.compile(r"[A-Za-z_]\w*|\.\.\.|\d[\w.]*|\S")


def all_files():
    files = ["startup.lua"]
    for path in sorted((ROOT / "blockos").rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT).as_posix()
        if any(relative.startswith(excluded + "/") for excluded in EXCLUDED_DIRS):
            continue
        files.append(relative)
    return files


def collect_files(edition="desktop"):
    spec = EDITIONS[edition]
    return [
        relative for relative in all_files()
        if any(fnmatch.fnmatch(relative, pattern) for pattern in spec["include"])
        and not any(fnmatch.fnmatch(relative, pattern) for pattern in spec["exclude"])
    ]


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


def build(edition):
    spec = EDITIONS[edition]
    version = read_text(spec["version"]).strip()
    files = collect_files(edition)

    bundle = "\n".join(
        "Files[" + lua_quote(relative) + "] = " + long_string(read_text(relative))
        for relative in files
    )
    template = read_text(spec["template"])
    installer = template.replace('"@VERSION@"', lua_quote(version)).replace("--@FILES@", bundle)
    (ROOT / spec["installer"]).write_text(installer, encoding="utf-8", newline="\n")

    entries = ",\n".join("\t\t" + lua_quote(relative) for relative in files)
    manifest = (
        "{\n\tVersion = " + lua_quote(version) + ",\n\tEdition = " + lua_quote(edition)
        + ",\n\tFiles = {\n" + entries + "\n\t}\n}\n"
    )
    (ROOT / spec["manifest"]).write_text(manifest, encoding="utf-8", newline="\n")

    size = (ROOT / spec["installer"]).stat().st_size
    print(f"{edition} {version}: {len(files)} files, {spec['installer']} {size / 1024:.1f} KB")


def build_store_package():
    """The App Store installs one file per app, so BlockDrive's package bundles its library."""
    version = read_text(EDITIONS["blockdrive"]["version"]).strip()
    files = [f for f in collect_files("blockdrive") if f.endswith(".lua")]
    bundle = "\n".join(
        "Files[" + lua_quote(relative) + "] = " + long_string(read_text(relative))
        for relative in files
    )
    template = read_text("src/blockdrive-package.lua")
    package = template.replace('"@VERSION@"', lua_quote(version)).replace("--@FILES@", bundle)
    (ROOT / "store" / "packages" / "blockdrive.lua").write_text(package, encoding="utf-8", newline="\n")
    catalog = read_text("store/catalog.cfg")
    entry = re.search(r'ID = "blockdrive",.*?Version = "([^"]+)"', catalog, re.S)
    if not entry or entry.group(1) != version:
        print(f"warning: store/catalog.cfg should list BlockDrive version {version}")
    print(f"store package blockdrive {version}: store/packages/blockdrive.lua")


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--list":
        print("\n".join(collect_files(sys.argv[2])))
        return
    if not check_locals(all_files()):
        sys.exit(1)
    for edition in EDITIONS:
        build(edition)
    build_store_package()


if __name__ == "__main__":
    main()
