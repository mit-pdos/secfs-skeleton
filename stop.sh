#!/bin/sh

sudo umount mnt
sudo pkill secfs-
rm -rf mnt server.sock
