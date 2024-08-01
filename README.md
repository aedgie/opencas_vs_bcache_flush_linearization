# opencas_vs_bcache_flush_linearization
Compare open-cas and bcache which loads hdd less when flushing dirty blocks to that hdd.

Hi all,

I just want to share results of my comparing bcache vs OpenCAS in flushing optimization, specifically merging neighbor dirty sectors and write them once in flush.

**TLDR**: OpenCAS is better.

We all know that most part of HDD latency is just waiting until required part of disk surface moves under heads. That's why random IOPS of ordinary HDD is about 60 (disk has to wait on average half of one revolution, which takes 7200rpm/60seconds/2 = 60 readwrites per second). Yes, internal cache and modern firmware allow to increase this number up to 100 and higher, but IOPS value order remains.
So I became curious: can SSD caching convert set of just written random sectors to something similar to sequential flow when dumping them to HDD? And if yes, how close to sequential write it would be. Because better merge decreases HDD load, keeps more space for read operations and therefore overall performance. Even if my new system survives high IO load spike I want it to stay alive further when cache flushes dirty blocks to free space for new data.

My idea was to create very slow block device using "delay" target of device mapper (dm-delay), then use it as backing device like HDD and use RAM disk like SSD cache.
dm-delay allows to insert delay for every operation. Also it allows to set delays for reads or writes separately.
So I made delayed disk with write delay of 1 second (1000 ms) and no read delay.

> $ echo "0 $(blockdev --getsz /dev/loop1) delay /dev/loop1 0 0 /dev/loop1 0 1000" | dmsetup create delayed_disk

Then I confirmed that writing to delayed disk either 4K or 128K block tooks roughly same time: 1 second. I.e. delay does not depend on request size.
Then built RAMdisk with size larger than delayed_disk.
Then built bcache and after test finished destroyed it and built OpenCAS. Both in writeback mode.

bcache:
> $ make-bcache -C /dev/loop1 -B /dev/mapper/delayed_disk
> $ echo writeback > /sys/block/bcache0/bcache/cache_mode
> $ echo 100 > /sys/block/bcache0/bcache/writeback_percent

OpenCAS:
> $ casadm --start-cache --cache-device /dev/loop2 --cache-mode wb --cache-line-size 4 --cache-id 999
> $ casadm --add-core --core-device /dev/disk/by-id/delayed_disk --cache-id 999 --core-id 888


Test was simple, I used **fio** with parameters: only writing randomly (readwrite=randwrite), data size equal to size of delayed_disk:

> fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=fiotest --bs=4k --iodepth=8 --size= --readwrite=randwrite --runtime=15 --filename=[/dev/bcahe0 | /dev/cas999-888]

After test I started flush
For bcache:

> $ echo $(( 1024 * 1024 * 1024 / 512 )) > /sys/block/bcache0/bcache/writeback_rate
> $ echo 0 > /sys/block/bcache0/bcache/writeback_delay
> $ echo writethrough > /sys/block/bcache0/bcache/cache_mode
> $ time while [ "x$(cat /sys/block/bcache0/bcache/state)" == "xdirty" ] ; do sleep 0.1; done

for OpenCAS:

> time casadm --flush-cache --cache-id 999 --core-id 888

And eventually 
### Results
for  delayed_disk with size = 32MB, write data size = 32MB (**full disk**), RAM disk size = 512MB and write delay = 1000ms:
```
Flush time (32MB, 100% fill):
  bcache  ~ 170 seconds
  OpenCAS ~ 15 seconds
```
for  delayed_disk with size = 256MB, write data size = 64MB (**25% of disk**), RAM disk size = 512MB and write delay = 1000ms:
```
Flush time (256MB, 25% fill):
  bcache  ~ 300 seconds
  OpenCAS ~ 35 seconds
```

Obviously OpenCAS is a winner. OpenCAS merges and flushes neighbour dirty sectors 10 times faster than bcache. In other words OpenCAS produces IOPS to HDD up to 10 times less than bcache in this artificial but illustrative experiment. 

Hope results can help someone to choose.

### PS
Btw IOPS while fio'ing before flush also differ a much:
```
IOPS (32MB, 100% fill):
  bcache  ~ 10k
  OpenCAS ~ 100k
IOPS (256MB, 25% fill):
  bcache  ~ 18k
  OpenCAS ~ 80k
```

### PPS
If someone wants to repeat tests attachment contains scripts I used in tests.
There are three main parameters . All are in bytes:

> FSIZE - size of delayed disk used as backing device
> RSIZE - size of RAM disk used as caching device
> FIOSIZE - volume of data written to bcache/cas device by fio test

and one parameter for write delay of delayed_disk (milliseconds):

> DELAYMS



[linearization_tests.tar.gz](https://github.com/user-attachments/files/16457589/linearization_tests.tar.gz)
