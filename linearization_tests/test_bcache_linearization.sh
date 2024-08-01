#!/bin/bash

DELAYMS=1000

FNAME='test.bin'
RNAME='/tmp/test.ram.disk/disk.bin'
RDNAME=$(dirname $RNAME)
FSIZE=$((256*1024*1024))
RSIZE=$((512*1024*1024)) #even 256M is too small for bcache
FIOSIZE=$((FSIZE/4))

echo "** preparing $FNAME with size $FSIZE and delay $DELAYMS"

BSIZE=$((32*1024)) #must be not less than 4K otherwise dd fails to write to device mapper although sector size is 512
FBLOCKS=$((FSIZE/BSIZE))

dd if=/dev/zero of=$FNAME bs=$BSIZE count=$FBLOCKS status=none

LOOPDEV=$(losetup --show --find --direct-io=on $FNAME)

SECTORS=`blockdev --getsz $LOOPDEV` #size in sectors
SECTSZ=`blockdev --getss $LOOPDEV` #size of sector
echo -e "loopdevice:\t$LOOPDEV\nsectors:\t$SECTORS\nsector size:\t$SECTSZ"

echo
echo "** creating delayed disk. Please wait while kernel scans it for filesystems. It should not take more than a minute."
DELAYDEVNAME='delayed_disk'
DELAYDEV=/dev/mapper/$DELAYDEVNAME
# making delayed device
echo "0 $SECTORS delay $LOOPDEV 0 0 $LOOPDEV 0 $DELAYMS $LOOPDEV 0 0" | dmsetup create $DELAYDEVNAME

echo -e "delayed disk created:\t$DELAYDEV" #\nsectors:\t$SECTORS\nsector size:\t$SECTSZ"


echo
echo "** preparing RAM disk $RNAME with size $RSIZE"
mkdir -p $RDNAME
mount -t tmpfs -o size=$((2*RSIZE)) tmpfs $RDNAME
dd if=/dev/zero of=$RNAME bs=$RSIZE count=1 status=none

RLOOPDEV=$(losetup --show --find $RNAME)
RLOOPNAME=$(basename $RLOOPDEV)

RSECTORS=`blockdev --getsz $RLOOPDEV` #size in sectors
RSECTSZ=`blockdev --getss $RLOOPDEV` #size of sector
echo -e "RAMdisk loopdevice:\t$RLOOPDEV\nsectors:\t$RSECTORS\nsector size:\t$RSECTSZ"

echo
echo -e "** MAKING BCACHE ON\n\t$RLOOPDEV on $RNAME ($RSIZE bytes) as cache and\n\t$LOOPDEV on $FNAME ($FSIZE bytes) as backing device"
#make-bcache -C $RLOOPDEV -B $DELAYDEV | sed 's/^/\t/'
make-bcache -C $RLOOPDEV -B $DELAYDEV > /dev/null
BCGUID=$(bcache-super-show $RLOOPDEV | grep cset | awk '{ print $2}')

while [ "x$(ls -l /sys/block/bcache*/bcache/cache | grep $BCGUID)" == "x" ] ; do
	echo "."
	echo $RLOOPDEV > /sys/fs/bcache/register
	echo $DELAYDEV > /sys/fs/bcache/register
	sleep 1
done 2>/dev/null

BCNAME=$(ls -l /sys/block/bcache*/bcache/cache | grep $BCGUID | awk '{ print $9 }' | sed 's/.*\(bcache[0-9]\+\).*/\1/')
BCACHEDEV=/dev/$BCNAME

echo "bcache formed device: $BCACHEDEV"
#fdisk -l $BCACHEDEV

echo "set writeback policy"
echo writeback > /sys/block/$BCNAME/bcache/cache_mode
echo 100 > /sys/block/$BCNAME/bcache/writeback_percent


#################### 
# testing
#################### 

echo
echo "** TESTING **"

fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=fiotest --bs=4k --iodepth=8 --size=$FIOSIZE --readwrite=randwrite --runtime=15 --filename=$BCACHEDEV | grep IOPS | awk '{ print $2}'

echo
echo "** FLUSHING **"

echo $((1024*1024*1024/512)) > /sys/block/$BCNAME/bcache/writeback_rate
echo 0 > /sys/block/$BCNAME/bcache/writeback_delay

echo "set writethrough policy"
echo writethrough > /sys/block/$BCNAME/bcache/cache_mode

echo -n "writeback_rate: "
cat /sys/block/$BCNAME/bcache/writeback_rate_debug | grep rate


CNT=0
time while [ "x$(cat /sys/block/$BCNAME/bcache/state)" == "xdirty" ] ; do
	if [[ "$CNT" == "0" ]] ; then
		echo -n "dirty data: "
		cat /sys/block/$BCNAME/bcache/dirty_data
	fi
	sleep 0.1
	CNT=$((CNT+1))
	if [[ "$CNT" == "100" ]] ; then
		CNT=0
	fi
done

echo "!! PLEASE REVISE GIVEN TIME RESULT !!"


#################### 
# cleanup
#################### 

echo
echo "** CLEANUP **"

# bcache is bshit
# kernel panics if bcache and delayed disk are being stopped too fast :(

sync # save filesystems before kernel panic

sleep $(( 1 + 2*DELAYMS/1000 ))
echo "echo 1 > /sys/block/$BCNAME/bcache/stop"
echo 1 > /sys/block/$BCNAME/bcache/stop

sleep $(( 1 + 2*DELAYMS/1000 ))
echo "echo 1 > /sys/fs/bcache/$BCGUID/stop"
echo 1 > /sys/fs/bcache/$BCGUID/stop

echo waiting for delayed disk remove
sleep $(( 5 + 2*DELAYMS/1000 )) # somehow this is needed otherwise kernel panics while removing delayed disk
RES=1
while [[ "$RES" -ne 0 ]] ; do
	sleep 1
	dmsetup remove $DELAYDEVNAME 2> /dev/null
	RES=$?
done
echo remove loopdevice backing delayed disk
losetup -d $LOOPDEV && rm $FNAME
echo remove RAM disk and its loopdevice
losetup -d $RLOOPDEV && umount $RDNAME && rm -rf $RDNAME
