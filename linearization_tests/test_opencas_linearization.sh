#!/bin/bash

DELAYMS=1000

FNAME='test.bin'
RNAME='/tmp/test.ram.disk/disk.bin'
RDNAME=$(dirname $RNAME)
FSIZE=$((256*1024*1024))
RSIZE=$((512*1024*1024)) #CAS requires 40MB minimum
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

# hack for OpenCAS, it demands by-id disks
DELAYDEVID=/dev/disk/by-id/$DELAYDEVNAME
ln -s $DELAYDEV $DELAYDEVID

echo -e "delayed disk created:\t$DELAYDEV" #\nsectors:\t$SECTORS\nsector size:\t$SECTSZ"


echo
echo "** preparing RAM disk $RNAME with size $RSIZE"
mkdir -p $RDNAME
mount -t tmpfs -o size=$((2*RSIZE)) tmpfs $RDNAME
dd if=/dev/zero of=$RNAME bs=$RSIZE count=1 status=none

RLOOPDEV=$(losetup --show --find $RNAME)
RLOOPNAME=$(basename $RLOOPDEV)
RLOOPID=/dev/disk/by-id/$RLOOPNAME
ln -s $RLOOPDEV $RLOOPID

RSECTORS=`blockdev --getsz $RLOOPDEV` #size in sectors
RSECTSZ=`blockdev --getss $RLOOPDEV` #size of sector
echo -e "RAMdisk loopdevice:\t$RLOOPDEV\nsectors:\t$RSECTORS\nsector size:\t$RSECTSZ"

echo
echo "** making CAS cache on $RNAME with size $RSIZE"
COREID=888
CACHEID=999
casadm --start-cache --cache-device $RLOOPID --cache-mode wb --cache-line-size 4 --cache-id $CACHEID
echo "** attach CAS core $DELAYDEV to $RNAME with size $FSIZE"
casadm --add-core --core-device $DELAYDEVID --cache-id $CACHEID --core-id $COREID

CASDEV=$(casadm -L | grep $COREID | awk '{print $6}')
echo "CAS formed device: $CASDEV"
#casadm -L
#fdisk -l $CASDEV


#################### 
# testing
#################### 

echo
echo "** TESTING **"

#casadm -P -i $CACHEID
fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=fiotest --bs=4k --iodepth=8 --size=$FIOSIZE --readwrite=randwrite --runtime=15 --filename=$CASDEV | grep IOPS | awk '{ print $2}'
#casadm -P -i $CACHEID

echo
echo "** FLUSHING **"

time casadm --flush-cache --cache-id $CACHEID --core-id $COREID
casadm -P -i $CACHEID | grep Dirty | grep blocks

echo "!! PLEASE REVISE GIVEN TIME RESULT !!"


#################### 
# cleanup
#################### 

echo
echo "** CLEANUP **"

RES=1
while [[ "$RES" -ne 0 ]] ; do
	sleep 1
	casadm --remove-core --force --core-id $COREID --cache-id $CACHEID
	RES=$?
done
casadm --stop-cache --no-data-flush --cache-id $CACHEID
rm $RLOOPID

RES=1
while [[ "$RES" -ne 0 ]] ; do
	sleep 1
	dmsetup remove $DELAYDEVNAME
	RES=$?
done
losetup -d $RLOOPDEV && umount $RDNAME && rm -rf $RDNAME
losetup -d $LOOPDEV && rm $FNAME
