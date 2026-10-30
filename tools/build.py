"""Builds the BlockOS release files.

Writes, at the repository root:
  install.lua   single-file installer with every BlockOS file bundled inside
  manifest.cfg  the update manifest read by blockos/lib/updater.lua

Run from anywhere: python tools/build.py
"""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXCLUDED_DIRS = {"blockos/data", "blockos/userapps", "blockos/.update"}


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


def main():
    version = read_text("blockos/version.txt").strip()
    files = collect_files()

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
