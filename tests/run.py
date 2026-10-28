"""Runs the BlockCloud tests on real CC: Tweaked computers.

Each scenario builds simulated computers (a folder per computer, filled from the edition
file lists in tools/build.py), boots them in tests/harness/CCHarness.java with a shared
wireless network, and collects PASS/FAIL lines the Lua test scripts write to results.txt.

  sh tests/harness/fetch.sh        # once: CC: Tweaked 26.2 core + Java 25
  python3 tests/run.py             # every scenario
  python3 tests/run.py vertical    # one scenario
"""

import importlib.util
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HARNESS = ROOT / "tests" / "harness"
OUT = ROOT / "tests" / "out"

spec = importlib.util.spec_from_file_location("build", ROOT / "tools" / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

SERVER_CONFIG = """{
  Configured = true,
  Hostname = "datacenter",
  DisplayName = "Data Center",
  StorageRoot = "/blockcloud/storage",
  DefaultShare = "Shared",
  Encrypt = %s,
  AutoUpdate = false,
  LockMinutes = 0,
}
"""


def java():
    return str(HARNESS / "jdk" / "bin" / "java")


def compile_harness():
    out = HARNESS / "build"
    jars = sorted(str(p) for p in (HARNESS / "lib").glob("*.jar"))
    if not jars:
        sys.exit("Run sh tests/harness/fetch.sh first.")
    classpath = ":".join(jars)
    source = HARNESS / "CCHarness.java"
    target = out / "CCHarness.class"
    if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
        out.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(HARNESS / "jdk" / "bin" / "javac"), "-nowarn", "-cp", classpath, "-d", str(out), str(source)],
                       check=True, capture_output=True)
    return classpath + ":" + str(out)


def copy_edition(edition, root):
    for relative in build.collect_files(edition):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)


def copy_tests(root):
    shutil.copytree(ROOT / "tests" / "lua", root / "tests")


def server(root, encrypt=True, admin=True):
    copy_edition("server", root)
    (root / "blockos" / "version.txt").write_text((ROOT / "blockos/server/version.txt").read_text())
    config = root / "blockos" / "data" / "cloud" / "server.dat"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(SERVER_CONFIG % ("true" if encrypt else "false"))
    copy_tests(root)
    if admin:
        (root / "startup.lua").write_text('shell.run("/tests/server_startup.lua")\n')


def client(root, script, *args):
    copy_edition("desktop", root)
    copy_tests(root)
    (root / "startup.lua").write_text('shell.run("/tests/%s.lua" %s)\n' % (script, "".join(', "%s"' % a for a in args)))


def desktop(root, script):
    """A full BlockOS desktop with a user that logs in automatically and BlockDrive at login."""
    import hashlib
    client(root, script)
    data = root / "blockos" / "data"
    data.mkdir(parents=True, exist_ok=True)
    salt = "00112233445566778899aabbccddeeff"
    digest = hashlib.sha256((salt + ":").encode()).hexdigest()
    (data / "users.dat").write_text('{ { Name = "Steve", Salt = "%s", Hash = "%s", HasPassword = false, Color = 2048 } }\n' % (salt, digest))
    (data / "settings.dat").write_text('{ AutoLogin = true, Animations = false, AutoUpdate = false, StartupApps = { "blockdrive" } }\n')
    for folder in ("Documents", "Downloads", "Desktop"):
        (root / "home" / folder).mkdir(parents=True, exist_ok=True)


def run(name, computers, extra="", timeout=120):
    """computers: list of (id, label, setup function, options)."""
    base = OUT / name
    if base.exists():
        shutil.rmtree(base)
    lines = ["timeout %d" % timeout]
    for ident, label, setup, options in computers:
        root = base / ("computer%d" % ident)
        root.mkdir(parents=True)
        setup(root)
        lines.append("computer %d %s %s%s" % (ident, root, label, " basic" if "basic" in options else ""))
        if "wait" in options:
            lines.append("wait %d" % ident)
        if "screen" in options:
            lines.append("screen %d" % ident)
    lines.append(extra)
    (base / "spec").write_text("\n".join(lines) + "\n")
    print("== %s" % name)
    result = subprocess.run([java(), "-cp", CLASSPATH, "CCHarness", str(base / "spec")], capture_output=True, text=True)
    output = "\n".join(line for line in result.stdout.splitlines() if not line.startswith("Picked up"))
    (base / "harness.log").write_text(output + "\n" + result.stderr)
    failed = 0
    passed = 0
    for ident, label, _, options in computers:
        results = base / ("computer%d" % ident) / "results.txt"
        if results.exists():
            for line in results.read_text().splitlines():
                print("  [%s] %s" % (label, line))
                passed += line.startswith("PASS")
                failed += line.startswith("FAIL")
        elif "wait" in options:
            print("  [%s] no results" % label)
            failed += 1
    for line in output.splitlines():
        if line.startswith("[harness"):
            print("  " + line)
        elif line.startswith("  |"):
            print("  " + line)
    if result.returncode != 0:
        failed += 1
    log = base / "computer1" / "blockos" / "data" / "cloud" / "logs" / "server.log"
    if failed and log.exists():
        print("  server log tail:")
        for line in log.read_text().splitlines()[-15:]:
            print("    " + line)
    print("  %d passed, %d failed" % (passed, failed))
    return failed


def scenario_unit():
    return run("unit", [(1, "unit", lambda r: client(r, "unit"), {"wait"})], timeout=60)


def scenario_vertical():
    return run("vertical", [
        (1, "server", lambda r: server(r), {"basic"}),
        (2, "client", lambda r: client(r, "client_vertical"), {"wait"}),
        (3, "reader", lambda r: client(r, "client_readonly"), {"wait"}),
    ], timeout=240)


def scenario_network():
    # 10% of modem messages are lost, and the server is switched off for a while, as when
    # Aternos stops the Minecraft server or the chunk unloads.
    return run("network", [
        (1, "server", lambda r: server(r, encrypt=False), {"basic"}),
        (2, "client", lambda r: client(r, "client_network"), {"wait"}),
    ], extra="loss 0.1\noff 1 40 55", timeout=240)


def scenario_console():
    # The Server Edition GUI on an advanced computer: boot, console tabs, Finder, approval.
    # Clicks are queued by the harness; console_check.lua inspects the result from inside.
    clicks = [
        (6, 15, 2), (8, 25, 2), (10, 35, 2), (12, 45, 2),  # Clients, Pairing, Logs, Settings tabs
        (13, 2, 6), (14, 2, 8), (15, 2, 9), (16, 5, 2),    # settings sections, back to Overview
        (17, 3, 19),                                       # Finder
    ]
    events = "\n".join("event 1 %d mouse_click 1 %d %d\nsnap 1 %d" % (click + (click[0] - .2,)) for click in clicks)
    return run("console", [
        (1, "server", lambda r: server(r, admin=False), {"screen"}),
        (2, "check", lambda r: client(r, "console_check"), {"wait"}),
    ], extra=events, timeout=40)


def scenario_gui():
    result = run("gui", [
        (1, "server", lambda r: server(r), {"basic"}),
        (2, "desktop", lambda r: desktop(r, "client_gui"), {"wait"}),
    ], timeout=120)
    screens = OUT / "gui" / "computer2" / "screens.txt"
    if screens.exists():
        print(screens.read_text())
    return result


def installer_root(root, args, prepare=None):
    """A computer whose first boot runs server-install.lua with the given arguments."""
    root.mkdir(parents=True, exist_ok=True)
    if prepare:
        prepare(root)
    shutil.copyfile(ROOT / "server-install.lua", root / "server-install.lua")
    (root / "startup.lua").write_text(
        'if (not fs.exists("/installed")) then fs.open("/installed", "w").close() shell.run("/server-install.lua", %s) end\n'
        % ", ".join('"%s"' % a for a in args))


def scenario_install():
    def with_desktop(root):
        copy_edition("desktop", root)
        (root / "blockos" / "version.txt").write_text("1.5.1\n")
        (root / "home" / "Documents").mkdir(parents=True)
        (root / "home" / "Documents" / "keep.txt").write_text("my notes")
        (root / "blockos" / "data").mkdir(parents=True)
        (root / "blockos" / "data" / "users.dat").write_text("{}")
        (root / "blockos" / "userapps" / "game").mkdir(parents=True)
        (root / "blockos" / "userapps" / "game" / "main.lua").write_text("print(1)")

    def with_server(root):
        server(root, admin=False)
        (root / "blockcloud" / "storage" / "Shared").mkdir(parents=True)
        (root / "blockcloud" / "storage" / "Shared" / "old.txt").write_text("stored file")
        config = root / "blockos" / "data" / "cloud" / "server.dat"
        config.write_text(config.read_text().replace("Configured = true,", 'Configured = true, NodeID = "feedfacecafe0001",').replace('"datacenter"', '"updated"'))
        (root / "blockos" / "server" / "stale.lua").write_text("-- from an older release")

    failed = run("install", [
        (1, "fresh", lambda r: installer_root(r, ["--yes", "--hostname", "rack1", "--password", "pw"]), {"basic"}),
        (2, "desktop", lambda r: installer_root(r, ["--yes", "--hostname", "converted"], with_desktop), set()),
        (3, "update", lambda r: installer_root(r, ["--yes"], with_server), set()),
        (4, "check", lambda r: client(r, "install_check"), {"wait"}),
    ], timeout=90)

    base = OUT / "install"
    checks = [
        ("fresh: storage root created", (base / "computer1/blockcloud/storage/Shared").is_dir()),
        ("fresh: admin password stored hashed", "AdminHash" in (base / "computer1/blockos/data/cloud/server.dat").read_text()
            and '"pw"' not in (base / "computer1/blockos/data/cloud/server.dat").read_text()),
        ("fresh: no desktop files installed", not (base / "computer1/blockos/sys/desktop.lua").exists()
            and not (base / "computer1/blockos/apps/messages").exists()),
        ("fresh: version file written", (base / "computer1/blockos/version.txt").read_text().strip() == "1.0.0"),
        ("desktop: replaced by Server Edition", (base / "computer2/blockos/server/boot.lua").exists()
            and not (base / "computer2/blockos/sys/desktop.lua").exists()
            and not (base / "computer2/blockos/apps/btunes").exists()),
        ("desktop: Finder kept as the only app", sorted(p.name for p in (base / "computer2/blockos/apps").iterdir()) == ["finder"]),
        ("desktop: user files kept", (base / "computer2/home/Documents/keep.txt").read_text() == "my notes"),
        ("desktop: data and installed apps kept", (base / "computer2/blockos/data/users.dat").exists()
            and (base / "computer2/blockos/userapps/game/main.lua").exists()),
        ("update: settings and identity kept", 'NodeID = "feedfacecafe0001"' in (base / "computer3/blockos/data/cloud/server.dat").read_text()),
        ("update: stored files kept", (base / "computer3/blockcloud/storage/Shared/old.txt").read_text() == "stored file"),
        ("update: stale system files removed", not (base / "computer3/blockos/server/stale.lua").exists()),
    ]
    for name, ok in checks:
        print("  [files] %s %s" % ("PASS" if ok else "FAIL", name))
        failed += not ok
    return failed


def scenario_clientinstall():
    def prepare(root):
        copy_edition("desktop", root)
        for relative in build.collect_files("blockdrive"):
            target = root / relative
            if target.exists():
                target.unlink()
        shutil.rmtree(root / "blockos" / "apps" / "blockdrive", ignore_errors=True)
        (root / "blockos" / "data").mkdir(parents=True)
        (root / "blockos" / "data" / "settings.dat").write_text('{ Dock = { "finder", "notes", "settings" } }')
        shutil.copyfile(ROOT / "blockdrive-install.lua", root / "blockdrive-install.lua")
        (root / "startup.lua").write_text(
            'local Ok = shell.run("/blockdrive-install.lua", "--yes")\n'
            'local H = fs.open("/results.txt", "w") H.writeLine((Ok and "PASS" or "FAIL") .. " client: installer ran") H.close()\n'
            'fs.open("/harness_done", "w").close()\n')

    failed = run("clientinstall", [(1, "desktop", prepare, {"wait"})], timeout=30)
    root = OUT / "clientinstall" / "computer1"
    before = {relative: (ROOT / relative).read_bytes() for relative in build.collect_files("desktop")
              if relative not in build.collect_files("blockdrive") and relative != "startup.lua"}
    unchanged = all((root / relative).read_bytes() == data for relative, data in before.items())
    checks = [
        ("client: app, library and command installed", all((root / relative).exists() for relative in build.collect_files("blockdrive"))),
        ("client: no other desktop file changed", unchanged),
        ("client: pinned to the Dock", '"blockdrive"' in (root / "blockos/data/settings.dat").read_text()),
    ]
    for name, ok in checks:
        print("  [files] %s %s" % ("PASS" if ok else "FAIL", name))
        failed += not ok
    return failed


def scenario_setup():
    def fresh(root):
        server(root, admin=False)
        (root / "blockos" / "data" / "cloud" / "server.dat").unlink()
    # Welcome, name, storage, password, updates, done: the primary button sits bottom right.
    events = "\n".join("event 1 %d mouse_click 1 44 18\nsnap 1 %.1f" % (t, t - .2) for t in range(3, 9))
    return run("setup", [
        (1, "wizard", fresh, {"screen"}),
        (2, "check", lambda r: client(r, "setup_check"), {"wait"}),
    ], extra=events, timeout=50)


def scenario_update():
    import functools
    import http.server
    import threading
    channel = OUT / "update-channel"
    shutil.rmtree(channel, ignore_errors=True)
    # A "server" channel offering 1.0.1, and a broken one that serves a desktop manifest.
    good, bad = channel / "good", channel / "bad"
    copy_edition("server", good)
    files = build.collect_files("server")
    entries = ",\n".join('\t\t"%s"' % f for f in files)
    (good / "server-manifest.cfg").write_text('{\n\tVersion = "1.0.1",\n\tEdition = "server",\n\tFiles = {\n%s\n\t}\n}\n' % entries)
    bad.mkdir(parents=True)
    (bad / "server-manifest.cfg").write_text('{ Version = "9.9.9", Edition = "desktop", Files = { "startup.lua" } }')
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    handler = functools.partial(Quiet, directory=str(channel))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    def updatable(root, path):
        server(root)
        config = root / "blockos" / "data" / "cloud" / "server.dat"
        config.write_text(config.read_text().replace("AutoUpdate = false,", 'AutoUpdate = true, AutoInstall = true, AutoRestart = true, UpdateURL = "http://127.0.0.1:%d/%s/",' % (port, path)))
        (root / "blockcloud" / "storage" / "Shared").mkdir(parents=True)
        (root / "blockcloud" / "storage" / "Shared" / "keep.txt").write_text("still here")

    try:
        failed = run("update", [
            (1, "server", lambda r: updatable(r, "good"), {"basic"}),
            (2, "client", lambda r: client(r, "client_update"), {"wait"}),
            (3, "wrong", lambda r: updatable(r, "bad"), {"basic"}),
        ], extra="http-local", timeout=120)
    finally:
        httpd.shutdown()
    root = OUT / "update" / "computer1"
    log = (root / "blockos/data/cloud/logs/server.log").read_text()
    checks = [
        ("update: restarted by itself into 1.0.1", "Restarting to finish installing 1.0.1" in log and "BlockOS Server 1.0.1 starting" in log),
        ("update: version file updated", (root / "blockos/version.txt").read_text().strip() == "1.0.1"),
        ("update: stored files kept", (root / "blockcloud/storage/Shared/keep.txt").read_text() == "still here"),
        ("update: settings kept", "UpdateURL" in (root / "blockos/data/cloud/server.dat").read_text()),
    ]
    for name, ok in checks:
        print("  [files] %s %s" % ("PASS" if ok else "FAIL", name))
        failed += not ok
    return failed


SCENARIOS = {
    "unit": scenario_unit,
    "vertical": scenario_vertical,
    "network": scenario_network,
    "console": scenario_console,
    "gui": scenario_gui,
    "setup": scenario_setup,
    "update": scenario_update,
    "install": scenario_install,
    "clientinstall": scenario_clientinstall,
}


if __name__ == "__main__":
    CLASSPATH = compile_harness()
    names = sys.argv[1:] or list(SCENARIOS)
    total = sum(SCENARIOS[name]() for name in names)
    print("FAILED" if total else "ALL PASSED")
    sys.exit(1 if total else 0)
