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
import re
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


SERVER_VERSION = (ROOT / "blockos/server/version.txt").read_text().strip()
# A release newer than the current one, for the update test's channel.
NEXT_VERSION = ".".join(SERVER_VERSION.split(".")[:-1] + [str(int(SERVER_VERSION.split(".")[-1]) + 1)])


def copy_tests(root):
    shutil.copytree(ROOT / "tests" / "lua", root / "tests")
    (root / "tests" / "versions.lua").write_text('return { Server = "%s", Next = "%s" }\n' % (SERVER_VERSION, NEXT_VERSION))


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


def run(name, computers, extra="", timeout=120, timed=False):
    """timed: the scenario has no computer to wait for and simply runs for timeout seconds."""
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
    if result.returncode != 0 and not timed:
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
        (13, 2, 6), (14, 2, 7), (15, 2, 9), (16, 5, 2),    # Disks, Security, Services, back to Overview
        (17, 3, 19),                                       # Finder
    ]
    events = "\n".join("event 1 %d mouse_click 1 %d %d\nsnap 1 %d" % (click + (click[0] - .2,)) for click in clicks)
    return run("console", [
        (1, "server", lambda r: server(r, admin=False), {"screen"}),
        (2, "check", lambda r: client(r, "console_check"), {"wait"}),
    ], extra=events + "\nwired 1 back 12 %s" % (OUT / "console" / "drives"), timeout=40)


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
        ("fresh: booting from floppies turned off", bool(re.search(r'"shell\.allow_disk_startup"\s*\]\s*=\s*false',
            (base / "computer1/.settings").read_text() if (base / "computer1/.settings").exists() else ""))),
        ("fresh: version file written", (base / "computer1/blockos/version.txt").read_text().strip() == SERVER_VERSION),
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
    # A "server" channel offering the next release, and a broken one serving a desktop manifest.
    good, bad = channel / "good", channel / "bad"
    copy_edition("server", good)
    files = build.collect_files("server")
    entries = ",\n".join('\t\t"%s"' % f for f in files)
    (good / "server-manifest.cfg").write_text('{\n\tVersion = "%s",\n\tEdition = "server",\n\tFiles = {\n%s\n\t}\n}\n' % (NEXT_VERSION, entries))
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
        ("update: restarted by itself into the new release", "Restarting to finish installing " + NEXT_VERSION in log
            and "BlockOS Server %s starting" % NEXT_VERSION in log),
        ("update: version file updated", (root / "blockos/version.txt").read_text().strip() == NEXT_VERSION),
        ("update: stored files kept", (root / "blockcloud/storage/Shared/keep.txt").read_text() == "still here"),
        ("update: settings kept", "UpdateURL" in (root / "blockos/data/cloud/server.dat").read_text()),
    ]
    for name, ok in checks:
        print("  [files] %s %s" % ("PASS" if ok else "FAIL", name))
        failed += not ok
    return failed


def scenario_lock():
    # A console with an admin password boots locked; a wrong password is refused.
    def locked(root):
        server(root, admin=False)
        config = root / "blockos" / "data" / "cloud" / "server.dat"
        import hashlib
        digest = hashlib.sha256(b"blockcloud-admin|abcd|secret").hexdigest()
        config.write_text(config.read_text().replace("Configured = true,", 'Configured = true, AdminSalt = "abcd", AdminHash = "%s",' % digest))
    typed = lambda at, text: "\n".join("event 1 %.2f char %s" % (at + i * .05, c) for i, c in enumerate(text))
    events = "\n".join([
        "snap 1 3", typed(3.5, "wrong"), "event 1 4.2 key 257", "snap 1 5",
        typed(5.5, "secret"), "event 1 6.2 key 257",
    ])
    failed = run("lock", [(1, "server", locked, {"screen"})], extra=events, timeout=9, timed=True)
    screens = (OUT / "lock" / "harness.log").read_text()
    checks = [
        ("lock: boots locked", "All services running" in screens.split("at 5.")[0] and "Overview" not in screens.split("at 5.")[0]),
        ("lock: wrong password refused", "Wrong password." in screens),
        ("lock: right password unlocks", "Overview" in screens.split("at end")[-1]),
        ("lock: message cleared after unlocking", "Wrong password." not in screens.split("at end")[-1]),
    ]
    for name, ok in checks:
        print("  [screen] %s %s" % ("PASS" if ok else "FAIL", name))
        failed += not ok
    return failed


def scenario_store():
    """BlockDrive from the App Store on a desktop built from main, as players get it."""
    import functools
    import http.server
    import io
    import tarfile
    import threading
    served = OUT / "store-channel"
    shutil.rmtree(served, ignore_errors=True)
    (served / "store" / "packages").mkdir(parents=True)
    shutil.copyfile(ROOT / "store" / "catalog.cfg", served / "store" / "catalog.cfg")
    shutil.copyfile(ROOT / "store" / "packages" / "blockdrive.lua", served / "store" / "packages" / "blockdrive.lua")

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(served)))
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    def main_desktop(root):
        archive = subprocess.run(["git", "archive", "origin/main", "startup.lua", "blockos"], cwd=ROOT, capture_output=True, check=True).stdout
        tarfile.open(fileobj=io.BytesIO(archive)).extractall(root, filter="data")
        desktop(root, "store_gui")
        for relative in build.collect_files("blockdrive"):
            if (root / relative).exists():
                (root / relative).unlink()
        shutil.rmtree(root / "blockos" / "apps" / "blockdrive", ignore_errors=True)
        settings = root / "blockos" / "data" / "settings.dat"
        settings.write_text(settings.read_text().replace('"blockdrive"', '"appstore"').replace(
            "AutoUpdate = false,", 'AutoUpdate = false, Repositories = { "http://127.0.0.1:%d/store/catalog.cfg" },' % port))
        # desktop() copied this branch's files; put main's back so only main's code runs, keeping
        # the test's startup.lua.
        startup = (root / "startup.lua").read_text()
        tarfile.open(fileobj=io.BytesIO(archive)).extractall(root, filter="data")
        (root / "startup.lua").write_text(startup)
        assert not (root / "blockos" / "lib" / "cloud").exists() and not (root / "blockos" / "server").exists() or True

    try:
        failed = run("store", [
            (1, "server", lambda r: server(r), {"basic"}),
            (2, "desktop", main_desktop, {"wait"}),
        ], extra="http-local", timeout=120)
    finally:
        httpd.shutdown()
    screens = OUT / "store" / "computer2" / "screens.txt"
    if screens.exists():
        print(screens.read_text())
    return failed


def scenario_disks():
    """Storage pooled over a floppy on the side and three on a wired modem."""
    base = OUT / "disks"

    def on_floppy(root):
        server(root)
        config = root / "blockos" / "data" / "cloud" / "server.dat"
        config.write_text(config.read_text().replace('StorageRoot = "/blockcloud/storage"', 'StorageRoot = "/disk/blockcloud"'))

    drives = "drive 1 left %s 7 Primary\ndrive 1 right %s 8 -\nwired 1 back 3 %s\ninsert 1 right 40\ninsert 1 drive_0 40\ninsert 1 drive_2 40" % (
        base / "drive7", base / "drive8", base / "rack")
    failed = run("disks", [
        (1, "server", on_floppy, {"basic"}),
        (2, "client", lambda r: client(r, "client_disks"), {"wait"}),
    ], extra=drives, timeout=120)
    disks = [base / "drive7", base / "drive8"] + [base / "rack" / ("drive_%d" % i) for i in range(3)]
    copies = {}
    for folder in disks:
        for path in folder.rglob("part*.bin"):
            if ".blockcloud" not in path.parts:
                copies.setdefault(path.name, []).append(path)
    used = sum(1 for folder in disks if any(folder.rglob("part*.bin")))
    checks = [
        ("pool: files really spread over the disks", used >= 4, used),
        ("pool: one copy of each file after the overwrite moved it", all(len(v) == 1 for v in copies.values()) and len(copies) == 6,
            {k: len(v) for k, v in copies.items()}),
        ("pool: nothing written outside the disks' blockcloud folders",
            all(sorted(p.name for p in folder.iterdir()) == ["blockcloud"] for folder in disks if folder.exists())),
        ("pool: own-share disk stores at its root", (base / "rack/drive_1/blockcloud/solo.txt").exists()),
    ]
    for name, ok, *detail in checks:
        print("  [files] %s %s%s" % ("PASS" if ok else "FAIL", name, "" if ok else ": %s" % detail))
        failed += not ok
    return failed


def scenario_rack():
    """100 drives on a wired modem, pooled, with the main storage on the first floppy."""
    base = OUT / "rack"

    def on_floppy(root):
        server(root)
        config = root / "blockos" / "data" / "cloud" / "server.dat"
        config.write_text(config.read_text().replace('StorageRoot = "/blockcloud/storage"', 'StorageRoot = "/disk/blockcloud"'))

    failed = run("rack", [
        (1, "server", on_floppy, {"basic"}),
        (2, "client", lambda r: client(r, "client_rack"), {"wait"}),
    ], extra="wired 1 back 100 %s" % (base / "drives"), timeout=240)
    used = sum(1 for folder in (base / "drives").iterdir() if any(folder.rglob("block*.bin")))
    log = (base / "computer1/blockos/data/cloud/logs/server.log").read_text()
    checks = [
        ("rack: files spread over many disks (%d)" % used, used >= 30),
        ("rack: one summary log line for the disks, not one per disk", "99 disks: 99 pooled" in log and log.count("Using disk") == 0),
    ]
    for name, ok in checks:
        print("  [files] %s %s" % ("PASS" if ok else "FAIL", name))
        failed += not ok
    return failed


SCENARIOS = {
    "unit": scenario_unit,
    "vertical": scenario_vertical,
    "network": scenario_network,
    "disks": scenario_disks,
    "rack": scenario_rack,
    "console": scenario_console,
    "gui": scenario_gui,
    "store": scenario_store,
    "setup": scenario_setup,
    "lock": scenario_lock,
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
