#!/bin/sh
set -e

cd ~/secfs
if [ $? -ne 0 ]; then
	echo "SecFS directory not found, cannot continue."
	exit 1
fi

rm -rf venv
python3 -m venv --clear venv
. venv/bin/activate
python3 -m pip install --upgrade -e .
deactivate
