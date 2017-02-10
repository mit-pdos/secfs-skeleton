#!/usr/bin/env python3

from setuptools import setup

setup(
    name='SecFS',
    version='0.1.0',
    description='6.858 final project --- an encrypted and authenticated file system',
    long_description= open('README.md', 'r').read(),
    author='Jon Gjengset',
    author_email='jon@thesquareplanet.com',
    maintainer='MIT PDOS',
    maintainer_email='pdos@csail.mit.edu',
    url='https://github.com/mit-pdos/6.858-secfs',
    packages=['secfs', 'secfs.store'],
    install_requires=['llfuse', 'Pyro4', 'serpent', 'cryptography'],
    scripts=['bin/secfs-server', 'bin/secfs-fuse'],
    license='MIT',
    classifiers=[
        "Development Status :: 2 - Pre-Alpha",
        "Intended Audience :: Science/Research",
        "License :: OSI Approved :: MIT License",
        "Topic :: Education",
        "Topic :: Security",
        "Topic :: System :: Filesystems",
    ]
)
