#!/bin/sh
set -e

echo "
###### Ubuntu Main Repos
deb http://us.archive.ubuntu.com/ubuntu/ trusty main universe multiverse

###### Ubuntu Update Repos
deb http://us.archive.ubuntu.com/ubuntu/ trusty-security main universe multiverse
deb http://us.archive.ubuntu.com/ubuntu/ trusty-proposed main universe multiverse
deb http://us.archive.ubuntu.com/ubuntu/ trusty-updates main universe multiverse
" | sudo tee /etc/apt/sources.list

sudo apt-get update
if [ -d /etc/ld.so.cache ]; then
	sudo rmdir /etc/ld.so.cache
fi
sudo apt-get -f install
sudo apt-get install python3.4-venv pkg-config libfuse-dev libffi-dev python3.4-dev libattr1-dev libssl-dev pcregrep gdb bc

cd ~/secfs
if [ $? -ne 0 ]; then
	echo "SecFS directory not found, cannot continue."
	exit 1
fi

rm -rf venv
python3.4 -m venv --clear venv
. venv/bin/activate
python3.4 -m pip install --upgrade -e .
deactivate
