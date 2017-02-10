#!/bin/sh
set -e

rm -rf venv
python3 -m venv --clear venv
. venv/bin/activate
python3 -m pip install wheel
python3 -m pip install --upgrade -e .
deactivate
