# This file provides functionality for manipulating directories in SecFS.

import pickle
import secfs.fs
import secfs.crypto
import secfs.tables
import secfs.store.block
from secfs.store.inode import Inode

def find_under(dir_i, name):
    """
    Attempts to find the i of the file or directory with the given name under
    the directory at i.
    """
    dr = Directory(dir_i)
    for f in dr.children:
        if f[0] == name:
            return f[1]
    return None

class Directory:
    """
    A Directory is used to marshal and unmarshal the contents of directory
    inodes. To load a directory, an i must be given.
    """
    def __init__(self, i):
        self.inode = None
        self.children = []

        self.inode = secfs.fs.get_inode(i)
        if self.inode.kind != 0:
            raise TypeError("inode with ihash {} is not a directory".format(ihash))

        cnt = self.inode.read()
        if len(cnt) != 0:
            self.children = pickle.loads(cnt)

    def bytes(self):
        return pickle.dumps(self.children)

def add(dir_i, name, i):
    """
    Updates the directory's inode contents to include an entry for i under the
    given name.
    """
    dr = Directory(dir_i)
    for f in dr.children:
        if f[0] == name:
            raise KeyError("asked to add i {} to dir {} under name {}, but name already exists".format(i, dir_i, name))

    dr.children.append((name, i))
    new_dhash = secfs.store.block.store(dr.bytes())
    dr.inode.blocks = [new_dhash]
    new_ihash = secfs.store.block.store(dr.inode.bytes())
    return new_ihash
