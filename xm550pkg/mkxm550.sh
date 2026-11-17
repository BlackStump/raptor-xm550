#!/bin/sh
# xm550pkg/mkxm550.sh -- package Raptor for the Xiongmai IVG-83X50PSA-B (XM550 +
# SmartSens SC5332) into the OpenIPC xm530 lite image.
#
#   sh mkxm550.sh overlay   build the daemons against the firmware tree and
#                           assemble the overlay tree in $OVL (nothing else
#                           touched)
#   sh mkxm550.sh image     overlay + Majestic deselected, the overlay
#                           added to the tree's BR2_ROOTFS_OVERLAY,
#                           the images regenerated, the squashfs checked
#                           file by file against the overlay, and the
#                           images copied to $X/images as raptor-xm550-*
#
# The tree builds with per-package directories: every make rebuilds the
# target from each package's own files, so a file edited or replaced in
# output/target is put back by the package that owns it (load_xiongmai,
# the vendor's libisp_XM530.so, the opensdk libraries). The overlay goes
# through BR2_ROOTFS_OVERLAY instead, which Buildroot applies after the
# packages on every make, so its files are the ones in the image.
#
# The image ships with no stream credentials: the streams are open, the
# picture says "UNSECURED", and the owner sets RTSP and HTTP credentials in
# the web console (or leaves them off). They are not the root login, which
# the console's own Access setting changes.
#
# Daemons: rvd rsd ric rod rmd (video, RTSP, day/night, OSD, motion), rhd + rcd (web
# console on :8080), raptorctl. Paths below match the working tree; change
# them here if yours differ. Run in the Raptor-os container.

set -e
CAMS=/home/crazyasskooter/Cams
X=$CAMS/XM550
R=$X/raptor/raptor
FW=$CAMS/openipc-firmware/firmware-xm550
OUT=$FW/output
XM_SDK=$CAMS/openxiongmai/libraries
PKG=$(cd "$(dirname "$0")" && pwd)
OVL=$X/xm550-overlay
TC=$OUT/host/bin
B=$TC/arm-openipc-linux-musleabi
export XM_SDK
# The sysroot is where this tree's compiler says it is (an xm530 tree keeps
# it under arm-buildroot-linux-musleabi, not the compiler's own prefix)
SYSROOT=$("$B-gcc" -print-sysroot 2>/dev/null || true)

# Buildroot's own make, in its output directory: it keeps .config as it is
# (the firmware tree's top-level make would regenerate it from the board's
# defconfig and bring Majestic back)
br() { make -C "$OUT" "$@"; }

set_config() { # set_config SYMBOL y|n
    if [ "$2" = y ]; then
        sed -i "/^# $1 is not set/d; /^$1=/d" "$OUT/.config"
        echo "$1=y" >> "$OUT/.config"
    else
        sed -i "/^$1=/d; /^# $1 is not set/d" "$OUT/.config"
        echo "# $1 is not set" >> "$OUT/.config"
    fi
}

libs() {
    # rod draws the OSD with libschrift. Upstream OpenIPC has no package
    # for it, so it is built here from the copy in src/libschrift (one C
    # file, ISC licence) into this tree's sysroot, as a static library: rod
    # carries it and the camera needs nothing more.
    if [ ! -e "$SYSROOT/usr/include/schrift.h" ] || [ ! -e "$SYSROOT/usr/lib/libschrift.a" ]; then
        echo ">>> libschrift: building it into the firmware tree's sysroot (static)"
        D=$(mktemp -d)
        $B-gcc -O2 -std=c99 -fPIC -c "$PKG/src/libschrift/schrift.c" -o "$D/schrift.o" &&
            $B-ar rcs "$D/libschrift.a" "$D/schrift.o" &&
            cp "$D/libschrift.a" "$SYSROOT/usr/lib/" &&
            cp "$PKG/src/libschrift/schrift.h" "$SYSROOT/usr/include/" ||
            { echo "libschrift failed"; rm -rf "$D"; exit 1; }
        rm -rf "$D"
    fi
    # rsd links compy, built with this tree's compiler (a compy from another
    # gcc fails rsd's link with an LTO version error)
    C=$X/raptor/compy
    if [ ! -e "$C/build-arm/libcompy.a" ] || [ "$(cat "$C/build-arm/.toolchain" 2>/dev/null)" != "$B-gcc" ]; then
        echo ">>> compy: building with this tree's toolchain"
        rm -rf "$C/build-arm" && mkdir -p "$C/build-arm"
        (cd "$C/build-arm" && PKG_CONFIG=$TC/pkg-config cmake .. \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
            -DCMAKE_C_COMPILER=$B-gcc -DCMAKE_SYSROOT=$SYSROOT \
            -DCOMPY_SHARED=OFF -DCOMPY_TLS_MBEDTLS=ON > /tmp/mkxm550-compy.log 2>&1 &&
            make -j"$(nproc)" >> /tmp/mkxm550-compy.log 2>&1) ||
            { echo "compy failed -- see /tmp/mkxm550-compy.log"; exit 1; }
        echo "$B-gcc" > "$C/build-arm/.toolchain"
    fi
}

overlay() {
    [ -x "$B-gcc" ] || { echo "no toolchain at $B-gcc -- build the firmware tree first"; exit 1; }
    [ -d "$SYSROOT/usr/lib" ] || { echo "no sysroot at '$SYSROOT' (from $B-gcc -print-sysroot)"; exit 1; }
    echo ">>> toolchain $B-gcc, sysroot $SYSROOT"
    libs

    echo ">>> building rvd rsd ric rod rhd rcd rmd raptorctl (and the openxiongmai libraries)"
    (cd "$R" && ./build.sh xm550 "$OUT" rvd rsd ric rod rhd rcd rmd raptorctl > /tmp/mkxm550-build.log 2>&1) ||
        { echo "build failed -- see /tmp/mkxm550-build.log"; tail -20 /tmp/mkxm550-build.log; exit 1; }

    echo ">>> assembling $OVL"
    rm -rf "$OVL"
    mkdir -p "$OVL/usr/bin" "$OVL/usr/lib/sensors" "$OVL/etc/init.d" "$OVL/usr/share/raptor"
    cp "$R/rvd/rvd" "$R/rsd/rsd" "$R/ric/ric" "$R/rod/rod" "$R/rhd/rhd" "$R/rcd/rcd" "$R/rmd/rmd" \
       "$R/raptorctl/raptorctl" "$OVL/usr/bin/"
    # rhd serves the console as /usr/share/raptor/index.html at "/"
    cp "$R/rhd/console.html" "$OVL/usr/share/raptor/index.html"
    cp "$R/rhd/portal.html" "$OVL/usr/share/raptor/"
    cp -L "$X/raptor/raptor-common/librss_common.so" "$X/raptor/raptor-ipc/librss_ipc.so" "$OVL/usr/lib/"
    # openxiongmai: libxmhost (the MPI, what majestic gave the ISP
    # libraries), the open ISP library over the vendor's uClibc blob, the
    # ISP application layer, and the SC5332's sensor library, linked as
    # libsns.so (firmware #2663: nightlies link X123)
    cp "$R/build-xiongmai/libxmhost.so" "$R/build-xiongmai/libisp_XM530.so" \
       "$R/build-xiongmai/libispapp_XM530.so" "$OVL/usr/lib/"
    cp "$R/build-xiongmai/libsns.so" "$OVL/usr/lib/sensors/libsns_X50_XM530.so"
    a=$(find "$SYSROOT" -name 'libatomic.so.1' | head -1)
    [ -n "$a" ] && cp -L "$a" "$OVL/usr/lib/"
    # ydiff: wlight's frame comparison, when rvd's motion detection is off
    $B-gcc -O2 -Wall -o "$OVL/usr/bin/ydiff" "$PKG/src/ydiff.c"
    $B-strip "$OVL"/usr/bin/* "$OVL"/usr/lib/*.so* "$OVL"/usr/lib/sensors/*
    # after the strip, which would follow it to the build machine's /usr/lib
    ln -sf /usr/lib/sensors/libsns_X50_XM530.so "$OVL/usr/lib/libsns.so"
    chmod 644 "$OVL"/usr/share/raptor/*

    cp -a "$PKG/overlay/." "$OVL/"
    # load_xiongmai: the tree's own, with three VI buffers a way, so a
    # snapshot never costs the stream a frame (with osmem=72M, S95xm550)
    LX=$FW/general/package/xiongmai-osdrv-xm530/files/script/load_xiongmai
    [ -f "$LX" ] || { echo "no $LX"; exit 1; }
    grep -q '^VI_BUFF=' "$LX" || { echo "$LX has no VI_BUFF= line"; exit 1; }
    sed 's/^VI_BUFF=.*/VI_BUFF=3,3/' "$LX" > "$OVL/usr/bin/load_xiongmai"
    # Raptor's own init script, after S95xm550: rvd first (rod after it, so
    # the OSD is placed), and its stop waits up to 10 s for rvd
    # rvd needs about 8 s on the XM550 to make its first ring (the ISP start,
    # then ~3 s while VI takes channel 0's size, then the encoders); the
    # stock script waits 5 s and then starts nothing else. 20 s here: the
    # wait ends as soon as the ring is there.
    sed 's/while \[ \$i -lt 50 \] \&\& \[ ! -e \${SHMDIR}\/rss_ring_main \]/while [ $i -lt 200 ] \&\& [ ! -e ${SHMDIR}\/rss_ring_main ]/; s/no ring after 5s/no ring after 20s/' \
        "$R/config/S31raptor" > "$OVL/etc/init.d/S96raptor"
    grep -q 'lt 200' "$OVL/etc/init.d/S96raptor" || { echo "S96raptor: could not lengthen the ring wait"; exit 1; }
    chmod +x "$OVL"/etc/init.d/* "$OVL"/usr/bin/* "$OVL"/usr/sbin/*

    # rcd writes the stream credentials here once they are set
    chmod 600 "$OVL/etc/raptor.conf"

    echo ">>> overlay contents"
    (cd "$OVL" && find . \( -type f -o -type l \) | sort | while read -r f; do
        if [ -L "$f" ]; then printf "  %8s  %s -> %s\n" link "$f" "$(readlink "$f")"
        else printf "  %8s  %s\n" "$(wc -c < "$f")" "$f"; fi
    done)
    du -sk "$OVL" | awk '{print "  total " $1 " KiB"}'
}

# Motion events: the package builds onvif_notify_server and the events
# templates but installs neither. Built now and added to the overlay: the
# server, the events service's templates and the notification template,
# with the event's data item named IsMotion (what the stock PB4 sends
# under RuleEngine/CellMotionDetector/Motion) instead of the templates'
# State.
onvif_events() {
    echo ">>> onvif-simple-server: built for its motion-event parts"
    br onvif-simple-server > /tmp/mkxm550-onvif.log 2>&1 ||
        { echo "onvif-simple-server failed -- see /tmp/mkxm550-onvif.log"; tail -20 /tmp/mkxm550-onvif.log; exit 1; }
    OSS=$(ls -d "$OUT"/build/onvif-simple-server-*/ 2>/dev/null | head -1)
    [ -x "$OSS/onvif_notify_server" ] || { echo "  no onvif_notify_server in '$OSS'"; exit 1; }
    mkdir -p "$OVL/usr/sbin" "$OVL/var/www/onvif/events_service_files" "$OVL/etc/onvif_notify_server"
    cp "$OSS/onvif_notify_server" "$OVL/usr/sbin/"
    $B-strip "$OVL/usr/sbin/onvif_notify_server"
    for f in "$OSS"/events_service_files/*; do
        sed 's/Name="State"/Name="IsMotion"/' "$f" > "$OVL/var/www/onvif/events_service_files/${f##*/}"
    done
    sed 's/Name="State"/Name="IsMotion"/' "$OSS/notify_files/Notify.xml" > "$OVL/etc/onvif_notify_server/Notify.xml"
    grep -q 'Name="IsMotion"' "$OVL/var/www/onvif/events_service_files/PullMessages_2.xml" ||
        { echo "  events templates: no State item to rename"; exit 1; }
    chmod 644 "$OVL"/var/www/onvif/events_service_files/* "$OVL/etc/onvif_notify_server/Notify.xml"
    echo "  onvif_notify_server, $(ls "$OVL/var/www/onvif/events_service_files" | wc -l) events templates, Notify.xml"
}

image() {
    overlay
    T=$OUT/target

    echo ">>> Majestic: deselected in .config and removed from the target"
    set_config BR2_PACKAGE_MAJESTIC n
    br olddefconfig > /dev/null
    rm -f "$T/usr/bin/majestic" "$T/etc/majestic.yaml" "$T"/etc/init.d/S??majestic
    rm -rf "$T/usr/share/majestic"
    left=$(find "$T/etc" "$T/usr" -iname '*majestic*' 2>/dev/null)
    [ -n "$left" ] && { echo "  still present:"; echo "$left" | sed 's/^/    /'; }

    # ONVIF: OpenIPC's onvif-simple-server package (the server, WS-Discovery
    # and its XML templates); the overlay replaces its init script and
    # points its CGIs at onvif-cgi, which builds the conf from raptor.conf.
    # Off until [onvif] enabled = true.
    echo ">>> onvif-simple-server: selected in .config"
    set_config BR2_PACKAGE_MBEDTLS y
    set_config BR2_PACKAGE_ONVIF_SIMPLE_SERVER y
    br olddefconfig > /dev/null
    grep -q '^BR2_PACKAGE_ONVIF_SIMPLE_SERVER=y' "$OUT/.config" ||
        { echo "  could not select BR2_PACKAGE_ONVIF_SIMPLE_SERVER"; exit 1; }
    onvif_events


    echo ">>> the overlay: added to BR2_ROOTFS_OVERLAY (applied after the packages)"
    cur=$(sed -n 's/^BR2_ROOTFS_OVERLAY="\(.*\)"$/\1/p' "$OUT/.config")
    case " $cur " in
    *" $OVL "*) ;;
    *) sed -i "/^BR2_ROOTFS_OVERLAY=/d" "$OUT/.config"
       echo "BR2_ROOTFS_OVERLAY=\"$cur $OVL\"" >> "$OUT/.config"
       br olddefconfig > /dev/null ;;
    esac
    grep '^BR2_ROOTFS_OVERLAY=' "$OUT/.config" | sed 's/^/  /'

    echo ">>> regenerating images"
    br > /tmp/mkxm550-image.log 2>&1 ||
        { echo "image build failed -- see /tmp/mkxm550-image.log"; tail -20 /tmp/mkxm550-image.log; exit 1; }
    tail -4 /tmp/mkxm550-image.log | sed 's/^/  /'

    echo ">>> checking the squashfs against the overlay"
    SQ=$OUT/images/rootfs.squashfs
    LST=/tmp/mkxm550-squashfs.txt
    "$TC/unsquashfs" -lls "$SQ" > "$LST"
    bad=0
    # majestic itself, not OpenIPC web UI pages named after it
    if grep -E 'majestic' "$LST" | grep -vq 'squashfs-root/var/www/'; then
        echo "  FAIL: majestic is in the image:"
        grep -E 'majestic' "$LST" | grep -v 'squashfs-root/var/www/' | sed 's/^/    /'
        bad=1
    fi
    # every file of the overlay is in the image, byte for byte
    D=$(mktemp -d)
    "$TC/unsquashfs" -d "$D/r" "$SQ" > /dev/null 2>&1
    # OpenIPC's post-build strips comments from every shell script it
    # ships (general/scripts/strip-shell-comments.awk, run last), so a
    # script is compared as it ships: the overlay's copy through that awk
    STRIPPER=$FW/general/scripts/strip-shell-comments.awk
    n=0
    for f in $(cd "$OVL" && find . -type f | sed 's|^\./||'); do
        n=$((n + 1))
        if [ -f "$STRIPPER" ] && head -1 "$OVL/$f" | grep -q '^#!.*sh'; then
            awk -f "$STRIPPER" "$OVL/$f" | cmp -s - "$D/r/$f" ||
                { echo "  FAIL: /$f in the image is not the overlay's (comments stripped)"; bad=1; }
        else
            cmp -s "$OVL/$f" "$D/r/$f" || { echo "  FAIL: /$f in the image is not the overlay's"; bad=1; }
        fi
    done
    [ "$(readlink "$D/r/usr/lib/libsns.so")" = /usr/lib/sensors/libsns_X50_XM530.so ] ||
        { echo "  FAIL: libsns.so -> $(readlink "$D/r/usr/lib/libsns.so")"; bad=1; }
    grep -q '^VI_BUFF=3,3' "$D/r/usr/bin/load_xiongmai" || { echo "  FAIL: VI_BUFF"; bad=1; }
    for f in usr/sbin/onvif_simple_server usr/sbin/wsd_simple_server usr/sbin/onvif_notify_server \
             usr/bin/rmd var/www/onvif/device_service_files/GetDeviceInformation.xml \
             var/www/onvif/events_service_files/PullMessages_2.xml etc/onvif_notify_server/Notify.xml; do
        [ -e "$D/r/$f" ] || { echo "  FAIL: /$f missing (onvif-simple-server)"; bad=1; }
    done
    for s in device media events ptz; do
        [ "$(readlink "$D/r/var/www/onvif/${s}_service")" = /usr/sbin/onvif-cgi ] ||
            { echo "  FAIL: /var/www/onvif/${s}_service -> $(readlink "$D/r/var/www/onvif/${s}_service")"; bad=1; }
    done
    # busybox httpd runs CGI under /onvif/ only with OpenIPC's patch
    grep -q 'onvif/' "$D/r/bin/busybox" || { echo "  FAIL: busybox httpd has no /onvif/ CGI support"; bad=1; }
    rm -rf "$D"
    if [ $bad = 0 ]; then
        echo "  ok: all $n overlay files as built, libsns -> X50, VI_BUFF=3,3, ONVIF in, no majestic"
        mkdir -p "$X/images"
        cp "$OUT/images/uImage" "$X/images/raptor-xm550-uImage"
        cp "$OUT/images/rootfs.squashfs" "$X/images/raptor-xm550-rootfs.squashfs"
        (cd "$X/images" && md5sum raptor-xm550-uImage raptor-xm550-rootfs.squashfs > raptor-xm550.md5 &&
            ls -l raptor-xm550-* | sed 's/^/  /' && sed 's/^/  /' raptor-xm550.md5)
        echo "  sizes: uImage $(($(wc -c < "$OUT/images/uImage") / 1024))/2048 KiB, rootfs $(($(wc -c < "$SQ") / 1024))/5120 KiB"
    else
        echo "  not copied to $X/images: fix the FAILs first"
    fi
    [ $bad = 0 ]
}

case "$1" in
overlay) overlay ;;
image) image ;;
*) echo "usage: $0 overlay|image"; exit 1 ;;
esac
