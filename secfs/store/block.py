# This file handles all interaction with the SecFS server's blob storage.

# a server connection handle is passed to us at mount time by secfs-fuse
server = None
def register(_server):
    global server
    server = _server

def store(blob):
    """
    Store the given blob at the server, and return the content's hash.
    """
    global server
    return server.store(blob)

def load(chash):
    """
    Load the blob with the given content hash from the server.
    """
    global server
    blob = server.read(chash)

    # the RPC layer will base64 encode binary data
    if "data" in blob:
        import base64
        blob = base64.b64decode(blob["data"])

    return blob
