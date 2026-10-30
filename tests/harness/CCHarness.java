// Headless CC: Tweaked test harness for BlockCloud.
//
// Boots real CC: Tweaked computers (the core module: Cobalt VM, bios.lua, rom, fs, os, rednet)
// without Minecraft, joined by a simulated wireless modem network. Used by tests/run.py; see
// tests/README.md. Nothing here ships to computers.
//
// Spec file lines (one directive per line, # comments):
//   timeout <seconds>                  stop after this long
//   loss <0..1>                        drop this fraction of modem messages
//   computer <id> <root dir> <label> [basic]
//   wait <id>                          stop once <root>/harness_done exists for every waited computer
//   off <id> <from s> <to s>           power the computer off between these times (Aternos shutdown)
//   event <id> <at s> <name> [args...] queue an event (numbers are converted)
//   screen <id>                        print this computer's screen when the run ends
//   snap <id> <at s>                   print this computer's screen at a given time
//   http-local                         allow HTTP to localhost (for a test update channel)
//   drive <id> <side> <dir> <disk id> <label|->  attach a disk drive holding a floppy stored in dir
//   wired <id> <side> <count> <dir>    a wired modem with <count> disk drives (drive_0, drive_1, ...),
//                                      floppies with IDs 100, 101, ... stored in <dir>/drive_N
//   insert <id> <side|drive_N> <at s>  put the floppy back into a drive that ejected it

import dan200.computercraft.api.lua.IArguments;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.api.peripheral.IComputerAccess;
import dan200.computercraft.api.peripheral.IPeripheral;
import dan200.computercraft.core.ComputerContext;
import dan200.computercraft.core.CoreConfig;
import dan200.computercraft.core.apis.http.options.Action;
import dan200.computercraft.core.apis.http.options.AddressRule;
import dan200.computercraft.core.computer.Computer;
import dan200.computercraft.core.computer.ComputerSide;
import dan200.computercraft.core.filesystem.WritableFileMount;
import dan200.computercraft.core.terminal.Terminal;
import dan200.computercraft.test.core.computer.BasicEnvironment;

import java.io.File;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;

public class CCHarness {
    static final List<Modem> NETWORK = new CopyOnWriteArrayList<>();
    static final Random RANDOM = new Random(42);
    static double loss = 0;
    static long dropped = 0, delivered = 0;

    public static final class Modem implements IPeripheral {
        final Set<Integer> open = Collections.synchronizedSet(new HashSet<>());
        final List<IComputerAccess> computers = new CopyOnWriteArrayList<>();
        boolean powered = true;

        @Override public String getType() { return "modem"; }
        @Override public boolean equals(IPeripheral other) { return other == this; }
        @Override public void attach(IComputerAccess computer) { computers.add(computer); }
        @Override public void detach(IComputerAccess computer) { computers.remove(computer); }

        @LuaFunction public final void open(int channel) { open.add(channel); }
        @LuaFunction public final boolean isOpen(int channel) { return open.contains(channel); }
        @LuaFunction public final void close(int channel) { open.remove(channel); }
        @LuaFunction public final void closeAll() { open.clear(); }
        @LuaFunction public final boolean isWireless() { return true; }

        @LuaFunction
        public final void transmit(IArguments args) throws LuaException {
            int channel = args.getInt(0);
            int replyChannel = args.getInt(1);
            Object payload = args.get(2);
            for (Modem other : NETWORK) {
                if (other == this || !other.powered || !other.open.contains(channel)) continue;
                if (loss > 0 && RANDOM.nextDouble() < loss) { dropped++; continue; }
                delivered++;
                for (IComputerAccess access : other.computers) {
                    access.queueEvent("modem_message", access.getAttachmentName(), channel, replyChannel, payload, 12.0);
                }
            }
        }
    }

    // A disk drive with a floppy (125 KB, like CC's), enough for the disk API and fs mounts.
    public static final class DiskDrive implements IPeripheral {
        final File dir;
        final int diskId;
        String label;
        String remoteName;
        volatile boolean present = true;
        final Map<IComputerAccess, String> mounts = new java.util.concurrent.ConcurrentHashMap<>();
        final List<IComputerAccess> computers = new CopyOnWriteArrayList<>();

        DiskDrive(File dir, int diskId, String label) {
            this.dir = dir;
            this.diskId = diskId;
            this.label = label;
            dir.mkdirs();
        }

        @Override public String getType() { return "drive"; }
        @Override public boolean equals(IPeripheral other) { return other == this; }
        // Like CC's drive, mounting happens on a later tick, once the computer is running.
        @Override public void attach(IComputerAccess computer) {
            computers.add(computer);
        }

        void tick() {
            if (!present) return;
            for (IComputerAccess computer : computers) {
                if (!mounts.containsKey(computer)) mount(computer);
            }
        }
        @Override public void detach(IComputerAccess computer) {
            computers.remove(computer);
            String path = mounts.remove(computer);
            if (path != null) computer.unmount(path);
        }

        void mount(IComputerAccess computer) {
            // Like CC's drive: disk, disk2, disk3, ... whichever is free.
            String path = null;
            for (int n = 1; n < 1000 && path == null; n++) {
                try {
                    String location = n == 1 ? "disk" : "disk" + n;
                    WritableFileMount mount = new WritableFileMount(dir, 125_000);
                    path = remoteName == null ? computer.mountWritable(location, mount) : computer.mountWritable(location, mount, remoteName);
                } catch (RuntimeException e) {
                    return;
                }
            }
            if (path == null) return;
            mounts.put(computer, path);
            computer.queueEvent("disk", remoteName == null ? computer.getAttachmentName() : remoteName);
        }

        void eject() {
            if (!present) return;
            present = false;
            for (IComputerAccess computer : computers) {
                String path = mounts.remove(computer);
                if (path != null) computer.unmount(path);
                computer.queueEvent("disk_eject", remoteName == null ? computer.getAttachmentName() : remoteName);
            }
        }

        void insert() {
            if (present) return;
            present = true;
        }

        @LuaFunction public final boolean isDiskPresent() { return present; }
        @LuaFunction public final Object getDiskLabel() { return present ? label : null; }
        @LuaFunction public final void setDiskLabel(java.util.Optional<String> value) { label = value.orElse(null); }
        @LuaFunction public final boolean hasData(IComputerAccess computer) { return present && mounts.containsKey(computer); }
        @LuaFunction public final Object getMountPath(IComputerAccess computer) { return present ? mounts.get(computer) : null; }
        @LuaFunction public final boolean hasAudio() { return false; }
        @LuaFunction public final Object getAudioTitle() { return false; }
        @LuaFunction public final Object getDiskID() { return present ? diskId : null; }
        @LuaFunction public final void ejectDisk() { eject(); }

        // The same methods, called through a wired modem's callRemote.
        Object[] call(IComputerAccess computer, String method, IArguments args, int offset) throws LuaException {
            return switch (method) {
                case "isDiskPresent" -> new Object[] { present };
                case "getDiskLabel" -> new Object[] { present ? label : null };
                case "setDiskLabel" -> { label = args.optString(offset).orElse(null); yield new Object[0]; }
                case "hasData" -> new Object[] { present && mounts.containsKey(computer) };
                case "getMountPath" -> new Object[] { present ? mounts.get(computer) : null };
                case "hasAudio" -> new Object[] { false };
                case "getAudioTitle" -> new Object[] { false };
                case "getDiskID" -> new Object[] { present ? diskId : null };
                case "ejectDisk" -> { eject(); yield new Object[0]; }
                default -> throw new LuaException("No such method " + method);
            };
        }
    }

    // A wired modem with remote disk drives, as on a Data Center's cable network.
    public static final class WiredModem implements IPeripheral {
        final Map<String, DiskDrive> remotes = new LinkedHashMap<>();
        static final List<String> METHODS = List.of("isDiskPresent", "getDiskLabel", "setDiskLabel", "hasData", "getMountPath",
            "hasAudio", "getAudioTitle", "getDiskID", "ejectDisk");

        @Override public String getType() { return "modem"; }
        @Override public Set<String> getAdditionalTypes() { return Set.of("peripheral_hub"); }
        @Override public boolean equals(IPeripheral other) { return other == this; }
        @Override public void attach(IComputerAccess computer) { for (DiskDrive drive : remotes.values()) drive.attach(computer); }
        @Override public void detach(IComputerAccess computer) { for (DiskDrive drive : remotes.values()) drive.detach(computer); }

        @LuaFunction public final boolean isWireless() { return false; }
        @LuaFunction public final void open(int channel) { }
        @LuaFunction public final boolean isOpen(int channel) { return true; }
        @LuaFunction public final void close(int channel) { }
        @LuaFunction public final void closeAll() { }
        @LuaFunction public final void transmit(IArguments args) { }
        @LuaFunction public final String getNameLocal() { return "computer_0"; }
        @LuaFunction public final List<String> getNamesRemote() { return new ArrayList<>(remotes.keySet()); }
        @LuaFunction public final boolean isPresentRemote(String name) { return remotes.containsKey(name); }
        @LuaFunction public final Object getTypeRemote(String name) { return remotes.containsKey(name) ? "drive" : null; }
        @LuaFunction public final Object hasTypeRemote(String name, String type) { return remotes.containsKey(name) ? "drive".equals(type) : null; }
        @LuaFunction public final Object getMethodsRemote(String name) { return remotes.containsKey(name) ? METHODS : null; }
        @LuaFunction public final Object[] callRemote(IComputerAccess computer, IArguments args) throws LuaException {
            DiskDrive drive = remotes.get(args.getString(0));
            if (drive == null) throw new LuaException("No peripheral " + args.getString(0));
            return drive.call(computer, args.getString(1), args, 2);
        }
    }

    record Off(double from, double to) {}
    record Event(double at, String name, Object[] args) {}

    static final class Node {
        int id; File root; String label; boolean colour = true;
        Computer computer; Modem modem; Terminal terminal;
        List<Off> off = new ArrayList<>();
        List<Event> events = new ArrayList<>();
        List<Double> snaps = new ArrayList<>();
        Map<String, DiskDrive> drives = new LinkedHashMap<>();
        Map<String, WiredModem> wired = new LinkedHashMap<>();
        List<Object[]> inserts = new ArrayList<>();
        boolean waited, screen;
    }

    static void printScreen(Node node, String when) {
        System.out.println("[harness] screen of computer " + node.id + " " + when + ":");
        for (int y = 0; y < node.terminal.getHeight(); y++) {
            System.out.println("  |" + node.terminal.getLine(y).toString().replaceAll("[\\x00-\\x1f\\x7f-\\xff]", "*") + "|");
        }
    }

    public static void main(String[] argv) throws Exception {
        double timeout = 60;
        Map<Integer, Node> nodes = new LinkedHashMap<>();
        for (String raw : Files.readAllLines(new File(argv[0]).toPath())) {
            String line = raw.strip();
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] p = line.split("\\s+");
            switch (p[0]) {
                case "timeout" -> timeout = Double.parseDouble(p[1]);
                case "loss" -> loss = Double.parseDouble(p[1]);
                case "http-local" -> CoreConfig.httpRules = List.of(AddressRule.parse("*", OptionalInt.empty(), Action.ALLOW.toPartial()));
                case "computer" -> {
                    Node node = new Node();
                    node.id = Integer.parseInt(p[1]);
                    node.root = new File(p[2]);
                    node.label = p[3];
                    node.colour = !(p.length > 4 && p[4].equals("basic"));
                    nodes.put(node.id, node);
                }
                case "wait" -> nodes.get(Integer.parseInt(p[1])).waited = true;
                case "screen" -> nodes.get(Integer.parseInt(p[1])).screen = true;
                case "drive" -> nodes.get(Integer.parseInt(p[1])).drives.put(p[2],
                    new DiskDrive(new File(p[3]), Integer.parseInt(p[4]), p[5].equals("-") ? null : p[5].replace('_', ' ')));
                case "wired" -> {
                    WiredModem modem = new WiredModem();
                    Node owner = nodes.get(Integer.parseInt(p[1]));
                    for (int i = 0; i < Integer.parseInt(p[3]); i++) {
                        DiskDrive drive = new DiskDrive(new File(p[4], "drive_" + i), 100 + i, null);
                        drive.remoteName = "drive_" + i;
                        modem.remotes.put(drive.remoteName, drive);
                        owner.drives.put(drive.remoteName, drive);
                    }
                    owner.wired.put(p[2], modem);
                }
                case "insert" -> nodes.get(Integer.parseInt(p[1])).inserts.add(new Object[] { p[2], Double.parseDouble(p[3]) });
                case "snap" -> nodes.get(Integer.parseInt(p[1])).snaps.add(Double.parseDouble(p[2]));
                case "off" -> nodes.get(Integer.parseInt(p[1])).off.add(new Off(Double.parseDouble(p[2]), Double.parseDouble(p[3])));
                case "event" -> {
                    Object[] args = new Object[p.length - 4];
                    for (int i = 4; i < p.length; i++) {
                        try { args[i - 4] = Double.parseDouble(p[i]); } catch (NumberFormatException e) { args[i - 4] = p[i]; }
                    }
                    nodes.get(Integer.parseInt(p[1])).events.add(new Event(Double.parseDouble(p[2]), p[3], args));
                }
                default -> throw new IllegalArgumentException("Unknown directive " + p[0]);
            }
        }

        BasicEnvironment global = new BasicEnvironment();
        ComputerContext context = ComputerContext.builder(global).computerThreads(2).build();
        for (Node node : nodes.values()) {
            node.root.mkdirs();
            WritableFileMount mount = new WritableFileMount(node.root, 2_000_000);
            node.terminal = new Terminal(51, 19, node.colour);
            node.computer = new Computer(context, new BasicEnvironment(mount), node.terminal, node.id);
            node.computer.setLabel(node.label);
            node.modem = new Modem();
            NETWORK.add(node.modem);
            node.computer.getEnvironment().setPeripheral(ComputerSide.TOP, node.modem);
            for (Map.Entry<String, DiskDrive> drive : node.drives.entrySet()) {
                if (drive.getValue().remoteName != null) continue;
                node.computer.getEnvironment().setPeripheral(ComputerSide.valueOf(drive.getKey().toUpperCase()), drive.getValue());
            }
            for (Map.Entry<String, WiredModem> modem : node.wired.entrySet()) {
                node.computer.getEnvironment().setPeripheral(ComputerSide.valueOf(modem.getKey().toUpperCase()), modem.getValue());
            }
            node.computer.turnOn();
        }

        long start = System.nanoTime();
        boolean finished = false;
        while (true) {
            double now = (System.nanoTime() - start) / 1e9;
            if (now > timeout) break;
            boolean allDone = true;
            boolean anyWaited = false;
            for (Node node : nodes.values()) {
                boolean shouldBeOff = false;
                for (Off off : node.off) if (now >= off.from && now < off.to) shouldBeOff = true;
                if (shouldBeOff && node.modem.powered) {
                    System.out.printf("[harness %.1fs] computer %d powered off%n", now, node.id);
                    node.modem.powered = false;
                    node.computer.shutdown();
                } else if (!shouldBeOff && !node.modem.powered) {
                    System.out.printf("[harness %.1fs] computer %d powered on%n", now, node.id);
                    node.modem.powered = true;
                    node.modem.open.clear();
                    node.computer.turnOn();
                }
                for (Iterator<Event> it = node.events.iterator(); it.hasNext(); ) {
                    Event event = it.next();
                    if (now >= event.at) {
                        node.computer.queueEvent(event.name, event.args);
                        it.remove();
                    }
                }
                for (Iterator<Object[]> it = node.inserts.iterator(); it.hasNext(); ) {
                    Object[] insert = it.next();
                    if (now >= (Double) insert[1]) {
                        System.out.printf("[harness %.1fs] disk inserted into computer %d %s%n", now, node.id, insert[0]);
                        node.drives.get((String) insert[0]).insert();
                        it.remove();
                    }
                }
                for (Iterator<Double> it = node.snaps.iterator(); it.hasNext(); ) {
                    double at = it.next();
                    if (now >= at) {
                        printScreen(node, String.format("at %.1fs", now));
                        it.remove();
                    }
                }
                node.computer.tick();
                if (node.computer.isOn()) for (DiskDrive drive : node.drives.values()) drive.tick();
                if (node.waited) {
                    anyWaited = true;
                    if (!new File(node.root, "harness_done").exists()) allDone = false;
                }
            }
            if (anyWaited && allDone) { finished = true; break; }
            Thread.sleep(50);
        }

        double elapsed = (System.nanoTime() - start) / 1e9;
        System.out.printf("[harness] %s after %.1fs, %d messages delivered, %d dropped%n",
            finished ? "finished" : "TIMED OUT", elapsed, delivered, dropped);
        for (Node node : nodes.values()) {
            if (node.screen) printScreen(node, "at end");
        }
        for (Node node : nodes.values()) node.computer.shutdown();
        for (int i = 0; i < 5; i++) for (Node node : nodes.values()) node.computer.tick();
        context.close(5, TimeUnit.SECONDS);
        System.exit(finished ? 0 : 2);
    }
}
