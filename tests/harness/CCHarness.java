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

    record Off(double from, double to) {}
    record Event(double at, String name, Object[] args) {}

    static final class Node {
        int id; File root; String label; boolean colour = true;
        Computer computer; Modem modem; Terminal terminal;
        List<Off> off = new ArrayList<>();
        List<Event> events = new ArrayList<>();
        List<Double> snaps = new ArrayList<>();
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
                for (Iterator<Double> it = node.snaps.iterator(); it.hasNext(); ) {
                    double at = it.next();
                    if (now >= at) {
                        printScreen(node, String.format("at %.1fs", now));
                        it.remove();
                    }
                }
                node.computer.tick();
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
