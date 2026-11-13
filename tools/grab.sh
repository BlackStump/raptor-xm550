#!/bin/sh
# Pull ~10 s of each stream out of rvd's rings into /tmp/p2b/, with JPEG
# snapshots from both channels running at 1 fps the whole time (10 each).
# Run while rvd is up; then compare the stream0/stream1 frame counts in
# the log (they should stay equal).
export LD_LIBRARY_PATH=/tmp/rvd
R=/tmp/rvd/ringdump
mkdir -p /tmp/p2b && cd /tmp/p2b && rm -f *.h264 *.jpg *.mjpeg
grep -E "stream[01]: [0-9]+ frames" /tmp/p2b.log | tail -2 > counts-before.txt
$R main -d -n 150 > main.h264 2>/dev/null &
$R sub -d -n 150 > sub.h264 2>/dev/null &
$R jpeg0 -d -n 10 > snaps0.mjpeg 2>/dev/null &
$R jpeg1 -d -n 10 > snaps1.mjpeg 2>/dev/null &
wait
sleep 35
grep -E "stream[01]: [0-9]+ frames" /tmp/p2b.log | tail -2 > counts-after.txt
cat counts-before.txt counts-after.txt
grep -E "chn [0-3]: (first|[0-9.]+ fps|[0-9]+ JPEG)" /tmp/p2b.log | tail -6
ls -l /tmp/p2b
