#!/bin/sh
# Downloads what the headless CC: Tweaked harness needs into tests/harness/lib and jdk:
# the CC: Tweaked 26.2 core (the same Lua VM, bios and ROM computers use in-game), its
# dependencies, and a Java 25 runtime. Run once; tests/run.py does the rest.
set -e
cd "$(dirname "$0")"
mkdir -p lib
S=https://maven.squiddev.cc
M=https://maven-central.storage-download.googleapis.com/maven2
get() { f=lib/$(basename "$1"); [ -s "$f" ] || curl -sSfL -o "$f" "$1"; }
get $S/cc/tweaked/cc-tweaked-26.2-core/1.120.2/cc-tweaked-26.2-core-1.120.2.jar
get $S/cc/tweaked/cc-tweaked-26.2-core/1.120.2/cc-tweaked-26.2-core-1.120.2-test-fixtures.jar
get $S/cc/tweaked/cc-tweaked-26.2-core-api/1.120.2/cc-tweaked-26.2-core-api-1.120.2.jar
get $S/cc/tweaked/cobalt/0.9.9/cobalt-0.9.9.jar
get $M/it/unimi/dsi/fastutil/8.5.18/fastutil-8.5.18.jar
get $M/com/google/guava/guava/33.6.0-jre/guava-33.6.0-jre.jar
get $M/com/google/guava/failureaccess/1.0.3/failureaccess-1.0.3.jar
get $M/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar
for a in netty-common netty-buffer netty-transport netty-codec netty-codec-base netty-codec-http netty-handler \
	netty-resolver netty-codec-socks netty-handler-proxy netty-codec-compression; do
	get $M/io/netty/$a/4.2.15.Final/$a-4.2.15.Final.jar
done
if [ ! -x jdk/bin/java ]; then
	curl -sSfL -o jdk.tar.gz "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse"
	mkdir -p jdk && tar xzf jdk.tar.gz -C jdk --strip-components=1 && rm jdk.tar.gz
fi
echo "Harness dependencies ready."
