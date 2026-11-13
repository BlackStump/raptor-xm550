#!/bin/sh
# Log what rvd reports for day/night, once every 2 s, for N seconds
# (default 120), to the screen and /tmp/expolog.txt. Run while rvd is up.
N=${1:-120}
export LD_LIBRARY_PATH=/tmp/rvd
: > /tmp/expolog.txt
i=0
while [ $i -lt $N ]; do
	l="$(date +%T) $(/tmp/rvd/raptorctl rvd get-exposure 2>&1 | tr -d ' \n')"
	echo "$l"; echo "$l" >> /tmp/expolog.txt
	sleep 2; i=$((i + 2))
done
