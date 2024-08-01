#!/bin/bash

DELAYMS=200

FNAME='test.bin'
CHECKSECTORS=128
FSIZE=$((2 * CHECKSECTORS * 512))

echo "** preparing $FNAME with size $FSIZE and delay $DELAYMS"

BSIZE=$((4*1024)) #must be 4K otherwise dd fails to write to device mapper although sector size is 512
FBLOCKS=$((FSIZE/BSIZE))

dd if=/dev/zero of=$FNAME bs=$BSIZE count=$FBLOCKS oflag=direct,sync status=progress

LOOPDEV=$(losetup --show --find $FNAME)

SECTORS=`blockdev --getsz $LOOPDEV` #size in sectors
SECTSZ=`blockdev --getss $LOOPDEV` #size of sector
echo -e "loopdevice:\t$LOOPDEV\nsectors:\t$SECTORS\nsector size:\t$SECTSZ"

echo "** creating delayed disk. Please wait while kernel scans it for filesystems. It should not take more than a minute."
DELAYDEVNAME='delayed_disk'
DELAYDEV=/dev/mapper/$DELAYDEVNAME
echo "0 $SECTORS delay $LOOPDEV 0 $DELAYMS" | dmsetup create $DELAYDEVNAME

#SECTORS=`blockdev --getsz $DELAYDEV` #size in sectors
#SECTSZ=`blockdev --getss $DELAYDEV` #size of sector
echo -e "delayed disk created:\t$DELAYDEV" #\nsectors:\t$SECTORS\nsector size:\t$SECTSZ"

#testing
echo
echo "** TESTING **"
echo "1. writing one $SECTSZ bytes block"
dd if=/dev/zero of=$DELAYDEV bs=$SECTSZ count=1 oflag=direct,sync conv=fdatasync
echo
LONGBLOCK=$((SECTSZ*CHECKSECTORS))
echo "2. writing one ${CHECKSECTORS}x${SECTSZ}=${LONGBLOCK} bytes block"
dd if=/dev/zero of=$DELAYDEV bs=$LONGBLOCK count=1 oflag=direct,sync conv=fdatasync
echo
echo "3. writing $CHECKSECTORS blocks $SECTSZ bytes each"
dd if=/dev/zero of=$DELAYDEV bs=$SECTSZ count=$CHECKSECTORS oflag=direct,sync conv=fdatasync
echo "** TESTING DONE**"
echo

#cleanup
echo cleanup
RES=1
while [[ "$RES" -ne 0 ]] ; do
	sleep 1
	dmsetup remove $DELAYDEVNAME
	RES=$?
done
losetup -d $LOOPDEV
rm $FNAME
