# This file contains all code handling the resolution and modification of i
# mappings. This includes group handle indirection and VSL validation, so the
# file is somewhat hairy.
# NOTE: an ihandle is the hash of a principal's itable, which holds that
# principal's mapping from inumbers (the second part of an i) to inode hashes.

import pickle
import secfs.store
import secfs.fs

# current_itables represents the current view of the file system's itables
current_itables = {}

# a server connection handle is passed to us at mount time by secfs-fuse
server = None
def register(_server):
    global server
    server = _server

def pre(refresh, user):
    """
    Called before all user file system operations, right after we have obtained
    an exclusive server lock.
    """
    if refresh != None:
        # refresh usermap and groupmap
        refresh()

def post(push_vs):
    if not push_vs:
        # when creating a root, we should not push a VS (yet)
        # you will probably want to leave this here and
        # put your post() code instead of "pass" below.
        return
    pass

class Itable:
    """
    An itable holds a particular principal's mappings from inumber (the second
    element in an i tuple) to an inode hash for users, and to a user's i for
    groups.
    """
    def __init__(self):
        self.mapping = {}

    def load(ihandle):
        b = secfs.store.block.load(ihandle)
        if b == None:
            return None

        t = Itable()
        t.mapping = pickle.loads(b)
        return t

    def bytes(self):
        return pickle.dumps(self.mapping)

def resolve(i, resolve_groups = True):
    """
    Resolve the given i into an inode hash. If resolve_groups is not set, group
    is will only be resolved to their user i, but not further.

    In particular, for some i = (principal, inumber), we first find the itable
    for the principal, and then find the inumber-th element of that table. If
    the principal was a user, we return the value of that element. If not, we
    have a group i, which we resolve again to get the ihash set by the last
    user to write the group i.
    """
    principal = i[0]

    if i[1] is None:
        # someone is trying to look up an i that has not yet been allocated
        return None

    global current_itables
    if principal not in current_itables:
        # User does not yet have an itable
        return None 

    t = current_itables[principal]

    inumber = i[1]
    if inumber not in t.mapping:
        raise LookupError("principal {} does not have i {}".format(principal, i))

    # santity checks
    if principal[1] and not isinstance(t.mapping[inumber], tuple):
        raise TypeError("looking up group i, but did not get indirection ihash")
    if not principal[1] and isinstance(t.mapping[inumber], tuple):
        raise TypeError("looking up user i, but got indirection ihash")

    if isinstance(t.mapping[inumber], tuple) and resolve_groups:
        # we're looking up a group i
        # follow the indirection
        return resolve(t.mapping[inumber])

    return t.mapping[inumber]

def modmap(mod_as, i, ihash):
    """
    Changes or allocates i so it points to ihash.

    If i[1] is None, a new inumber will be allocated for the principal i[0].
    This function is complicated by the fact that i might be a group i, in
    which case we need to:

      1. Allocate an i as mod_as
      2. Allocate/change the group i to point to the new i above

    modmap returns the given i, with i[1] filled in if it was passed as None.
    """
    assert not mod_as[1] # only real users can mod

    if mod_as != i[0]:
        print("trying to mod object for", i[0], "through", mod_as)
        assert i[0][1] # if not for self, then must be for group

        real_i = resolve(i, False)
        if isinstance(real_i, tuple) and real_i[0] == mod_as:
            # We updated the file most recently, so we can just update our i.
            # No need to change the group i at all.
            # This is an optimization.
            i = real_i
        elif isinstance(real_i, tuple) or real_i == None:
            if isinstance(ihash, tuple):
                # Caller has done the work for us, so we just need to link up
                # the group entry.
                print("mapping", i, "to", ihash, "which again points to", resolve(ihash))
            else:
                # Allocate a new entry for mod_as, and continue as though ihash
                # was that new i.
                # XXX: kind of unnecessary to send two VS for this
                _ihash = ihash
                ihash = modmap(mod_as, (mod_as, None), ihash)
                print("mapping", i, "to", ihash, "which again points to", _ihash)
        else:
            # This is not a group i!
            # User is trying to overwrite something they don't own!
            raise PermissionError("illegal modmap; tried to mod i {0} as {1}".format(i, mod_as))

    # find (or create) the principal's itable
    t = None
    global current_itables
    if i[0] not in current_itables:
        if i[1] != None:
            # this was unexpected;
            # user did not have an itable, but an inumber was given
            raise ReferenceError("itable not available")
        t = Itable()
        print("no current list for principal", i[0], "; creating empty table", t.mapping)
    else:
        t = current_itables[i[0]]

    # look up (or allocate) the inumber for the i we want to modify
    inumber = i[1]
    if inumber == None:
        inumber = 0
        while inumber in t.mapping:
            inumber += 1
    else:
        if inumber not in t.mapping:
            raise IndexError("invalid inumber")
    i = (i[0], inumber)

    # modify the entry, and store back the updated itable
    if i[0][1]:
        print("mapping", inumber, "for group", i[0], "into", t.mapping)
    t.mapping[inumber] = ihash # for groups, ihash is an i
    current_itables[i[0]] = t
    return (i[0], inumber)
