#!/bin/sh
mkdir mnt
. venv/bin/activate
pip3 install -e .
env PYTHONUNBUFFERED=1 venv/bin/secfs-server server.sock > server.log &
sudo env PYTHONUNBUFFERED=1 venv/bin/secfs-fuse PYRO:secfs@./u:server.sock mnt/ root.pub user-0-key.pem "user-$(id -u)-key.pem" > client.log &
