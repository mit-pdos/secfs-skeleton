import secfs.fs

def can_read(uid, i):
    """
    Returns True if the given user can read the given i.
    """
    return True

def can_write(uid, i):
    """
    Returns True if the given user can modify the given i.
    """
    # If i is owned by a user, and that user isn't you, you can't write
    if not i[0][1] and i[0][0] != uid:
        return False

    # If a group owns i, and you aren't in the group, you can't write
    if i[0][1] and (i[0][0] not in secfs.fs.groupmap or uid not in secfs.fs.groupmap[i[0][0]]):
        return False

    return True

def can_execute(uid, i):
    """
    Returns True if the given user can execute the given i.
    """
    if not secfs.access.can_read(uid, i):
        return False

    # check x bits
    node = secfs.fs.get_inode(i)
    return node.ex
