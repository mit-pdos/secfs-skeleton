#!/bin/sh
base=$(dirname "$0")
cd "$base" || exit 1

# we're going to need sudo
sudo date > /dev/null

# kill previous clients, servers, and tests
./stop.sh 2>/dev/null
sudo umount secfs-test.*/mnt* 2>/dev/null
rm -rf secfs-test.* 2>/dev/null

# in case students have changed it
umask 0022

# Build and enable
# shellcheck disable=SC1091
. venv/bin/activate
pip3 install --upgrade -e . > pip.log

# shellcheck source=test-lib.sh
. "$base/test-lib.sh"

# start a clean server for testing
info "starting server"
env PYTHONUNBUFFERED=1 venv/bin/secfs-server "$uxsock" > server.log 2> server.err &
server=$!

# wait for server to start and announce its URI
sync
while ! grep -P "^uri =" server.log > /dev/null; do
	sleep .2
done
uri=$(grep "uri = PYRO:secfs" server.log | awk '{print $3}')

# start primary client and connect it to the server
info "connecting to server at %s" "$uri"
sudo rm -f root.pub user-*-key.pem
client


section "Initializtion"
expect "ls -la" ' *\.\/?$' || fail "root directory does not contain ."
expect "ls -la" ' *\.\.\/?$' || fail "root directory does not contain .."
expect "ls -la" ' *\.users$' || fail "root directory does not contain .users"
expect "ls -la" ' *\.groups$' || fail "root directory does not contain .groups"
fstats "." "uid=root" "perm=drwxr-xr-x" || fail "root directory . has incorrect permissions"
fstats ".users" "uid=root" "perm=-rw-r--r--" || fail "/.users has incorrect permissions"
fstats ".groups" "uid=root" "perm=-rw-r--r--" || fail "/.groups has incorrect permissions"
expect "cat .users" '.+' || fail ".users couldn't be read"
expect "cat .groups" '.+' || fail ".groups couldn't be read"


section "Manipulating the root directory"
# root single-user write
expect "echo x | sudo tee root-file" "sudo cat root-file" '^x$' || fail "couldn't read back root created file"
expect "echo x | sudo tee -a root-file" "sudo cat root-file" '^x\nx$' || fail "couldn't read back root appended file"

cant "create user file in root dir" "echo b | tee user-file" "cat user-file"
cant "append to root file as user" "echo b | tee -a root-file" "pcregrep -M '^x\nb$ root-file"
cant "make user directory in root dir" "mkdir user-only" "stat user-only"
fstats "root-file" "uid=root" "perm=-rw-r--r--" || fail "new root file has incorrect permissions"

# root single-user dir
expect "sudo mkdir root-only" '^$' || fail "couldn't make root directory"
expect "sudo ls -la root-only" ' *\.\/?$' || fail "new root directories don't have ."
expect "sudo ls -la root-only" ' *\.\.\/?$' || fail "new root directories don't have .."
expect "sudo ls -la root-only/.." ' *\.users$' || fail "new root directory .. doesn't point to root"
expect "echo a | sudo tee root-only/file" "sudo cat root-only/file" '^a$' || fail "couldn't read back root created file in directory"
expect "echo a | sudo tee -a root-only/file" "sudo cat root-only/file" '^a\na$' || fail "couldn't read back root appended file in directory"
expect "sudo ls -la root-only/." ' *file$' || fail "new root directory . does not point to self"

cant "create file in dir owned by other user" "echo b | tee root-only/user-file" "cat root-only/user-file"
cant "append to file owned by other user" "echo b | tee -a root-only/file" "pcregrep -M '^a\nb$ root-only/file"
cant "make directory in dir owned by other user" "mkdir root-only/user-only" "stat root-only/user-only"
fstats "root-only" "uid=root" "perm=drwxr-xr-x" || fail "new root dir has incorrect permissions"
fstats "root-only/file" "uid=root" "perm=-rw-r--r--" || fail "new nested root file has incorrect permissions"


section "Manipulating shared directories"
# shared directory mkdir
expect "sudo sh -c 'umask 0200; sg users \"mkdir shared\"'" '^$' || fail "couldn't create group-owned directory"
expect "sudo ls -la shared/.." ' *\.users/?$' || fail "new shared directory .. doesn't point to root"
fstats "shared" "uid=root" "gid=users" "perm=dr-xrwxr-x" || fail "new shared dir has incorrect permissions"

# user file in shared dir
user=$(id -un)
expect "echo b | tee shared/user-file" "cat shared/user-file" '^b$' || fail "couldn't create user file in shared directory"
expect "echo b | tee -a shared/user-file" "cat shared/user-file" '^b\nb$' || fail "couldn't appended to user file in shared directory"
fstats "shared/user-file" "uid=$user" "perm=-rw-r--r--" || fail "new user file has incorrect permissions"
cant "append to file owned by other user as root" "echo x | sudo tee -a shared/user-file" "pcregrep -M '^b\nx$ shared/user-file"


section "Manipulating non-owner directories"
# user dir in shared dir
expect "mkdir shared/user-only" '^$' || fail "couldn't make user directory in shared dir"
expect "ls -la shared/user-only" ' *\.\/?$' || fail "new user directories don't have ."
expect "ls -la shared/user-only" ' *\.\.\/?$' || fail "new user directories don't have .."
expect "ls -la shared/user-only/.." ' *user-only/?$' || fail "new user directory .. doesn't point to parent"
expect "echo c | tee shared/user-only/file" "cat shared/user-only/file" '^c$' || fail "couldn't read back user created file"
expect "echo c | tee -a shared/user-only/file" "cat shared/user-only/file" '^c\nc$' || fail "couldn't read back user appended file"
expect "ls -la shared/user-only/." ' *file$' || fail "new user directory . does not point to self"

cant "create file in dir owned by other user as root" "echo b | sudo tee shared/user-only/root-file" "cat shared/user-only/root-file"
cant "append to file owned by other user as root" "echo x | sudo tee -a shared/user-only/file" "pcregrep -M '^c\nx$ shared/user-only/file"
cant "make directory in dir owned by other user as root" "sudo mkdir shared/user-only/root-dir" "stat shared/user-only/root-dir"
fstats "shared/user-only" "uid=$user" "perm=drwxr-xr-x" || fail "new user dir has incorrect permissions"
fstats "shared/user-only/file" "uid=$user" "perm=-rw-r--r--" || fail "new nested user file has incorrect permissions"


section "Restricted read permissions"
# Encrypted files (no read permission)
expect "sudo sh -c 'umask 0004; echo supercalifragilisticexpialidocious > root-secret'" '^$' || fail "couldn't create user-readable file as user"
expect "sudo cat root-secret" '^supercalifragilisticexpialidocious$' || fail "couldn't read user-readable file as user"
server_mem "user-readable file" "supercalifragilisticexpialidocious"
fstats "root-secret" "uid=root" "perm=-rw-------" || fail "encrypted file has incorrect permissions"
cant "read encrypted file belonging to other user" "cat root-secret"
expect "echo y | sudo tee -a root-secret" "sudo cat root-secret" '^supercalifragilisticexpialidocious\ny$' || fail "failed to append to encrypted file"

# Encrypted shared files (no read permission)
expect "sudo sh -c 'umask 0204; echo dociousaliexpilisticfragicalirupes | sg users \"tee group-secret\"'" '^dociousaliexpilisticfragicalirupes$' || fail "couldn't create group-readable file as root"
server_mem "group-readable file" "dociousaliexpilisticfragicalirupes"
fstats "group-secret" "uid=root" "gid=users" "perm=-r--rw----" || fail "group encrypted file has incorrect permissions"
expect "cat group-secret" '^dociousaliexpilisticfragicalirupes$' || fail "couldn't read group-readable file as group member"
expect "sudo cat group-secret" '^dociousaliexpilisticfragicalirupes$' || fail "couldn't read group-readable file as non-owning group member"
expect "echo z | sudo tee -a group-secret" "sudo cat group-secret" '^dociousaliexpilisticfragicalirupes\nz$' || fail "failed to append to group encrypted file"
cant "read encrypted file belonging to group without being member" "sudo -u '#666' cat root-secret"

# Encrypted directories
expect "sudo sh -c 'umask 0004; mkdir root-secrets'" '^$' || fail "couldn't create user-readable directory as user"
expect "echo a | sudo tee root-secrets/hidden-filename" "sudo cat root-secrets/hidden-filename" '^a$' || fail "couldn't read back root created file in encrypted directory"
expect "echo a | sudo tee -a root-secrets/hidden-filename" "sudo cat root-secrets/hidden-filename" '^a\na$' || fail "couldn't read back root appended file in encrypted directory"
server_mem "user-readable directory" "hidden-filename"
cant "read encrypted directory belonging to other user" "ls root-secrets"
cant "create file in encrypted directory belonging to other user" "touch root-secrets/sneaky-file"


section "Read-only client with root key access"
pushc "ro-client-with-root"
client
expect "ls -la" ' *\.\/?$' || fail "root directory does not contain ."
expect "ls -la" ' *\.\.\/?$' || fail "root directory does not contain .."
expect "ls -la" ' *\.users$' || fail "root directory does not contain .users"
expect "ls -la" ' *\.groups$' || fail "root directory does not contain .groups"
fstats "." "uid=root" "perm=drwxr-xr-x" || fail "root directory . has incorrect permissions"
fstats ".users" "uid=root" "perm=-rw-r--r--" || fail "/.users has incorrect permissions"
fstats ".groups" "uid=root" "perm=-rw-r--r--" || fail "/.groups has incorrect permissions"
expect "cat .users" '.+' || fail ".users couldn't be read"
expect "cat .groups" '.+' || fail ".groups couldn't be read"
popc


section "Read-only client without root key access"
pushc "ro-client-without-root"
client "root.pub" "user-$(id -u)-key.pem"
expect "ls -la" ' *\.\/?$' || fail "root directory does not contain ."
expect "ls -la" ' *\.\.\/?$' || fail "root directory does not contain .."
expect "ls -la" ' *\.users$' || fail "root directory does not contain .users"
expect "ls -la" ' *\.groups$' || fail "root directory does not contain .groups"
fstats "." "uid=root" "perm=drwxr-xr-x" || fail "root directory . has incorrect permissions"
fstats ".users" "uid=root" "perm=-rw-r--r--" || fail "/.users has incorrect permissions"
fstats ".groups" "uid=root" "perm=-rw-r--r--" || fail "/.groups has incorrect permissions"
expect "cat .users" '.+' || fail ".users couldn't be read"
expect "cat .groups" '.+' || fail ".groups couldn't be read"
popc


section "Access to read-restricted files from other clients"
pushc "remote-read-access"
client
# Encrypted files (no read permission)
expect "sudo cat root-secret" '^supercalifragilisticexpialidocious\ny$' || fail "couldn't read user-readable file as user on second client"
fstats "root-secret" "uid=root" "perm=-rw-------" || fail "encrypted file has incorrect permissions on second client"
cant "read encrypted file belonging to other user" "cat root-secret"
# Encrypted shared files (no read permission)
fstats "group-secret" "uid=root" "gid=users" "perm=-r--rw----" || fail "group encrypted file has incorrect permissions on second client"
expect "cat group-secret" '^dociousaliexpilisticfragicalirupes\nz$' || fail "couldn't read group-readable file as group member on second client"
expect "sudo cat group-secret" '^dociousaliexpilisticfragicalirupes\nz$' || fail "couldn't read group-readable file as non-owning group member on second client"
popc


section "Access to read-restricted files with only user key"
pushc "remote-read-access-no-root"
client "root.pub" "user-$(id -u)-key.pem"
# Encrypted shared files (no read permission)
fstats "group-secret" "uid=root" "gid=users" "perm=-r--rw----" || fail "group encrypted file has incorrect permissions on client w/o root key"
expect "cat group-secret" '^dociousaliexpilisticfragicalirupes\nz$' || fail "couldn't read group-readable file as group member on client w/o root key"
popc


section "Writing client"
pushc "writing-client"
client
expect "echo b | tee shared/third-client-file" "cat shared/third-client-file" '^b$' || fail "couldn't create file as user in separate client"
expect "echo b | tee -a shared/third-client-file" "cat shared/third-client-file" '^b\nb$' || fail "couldn't append to file as user in separate client"
popc

expect "cat shared/third-client-file" '^b\nb$' || fail "couldn't read back file created by user in separate client"


section "Manipulating as non-member"
cant "create file in group-writeable directory as non-member" "echo b | sudo -u '#666' tee shared/muhaha"
cant "read back file created in group-writeable directory as non-member" "sudo -u '#666' stat shared/muhaha"


section "Malicious server"
pushc "malicious-server-client"
echo "-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtosq1vJMkPtibVohp9ws
oC0aBio6eDK3v5x+WasdAX4KzfGE5DIJAVgVL6rkJwOen5BuYQvm8JZ1LkFQcYAc
mrN8adCAdkEFuGv61MDqM+ngCEHRgmOY+2g4qpmoNRdO9aPNc9E5YjZXgcphZrK+
mODnZyBrZE22NAE9L6TTvdDDa+4ITpoMTiLH4pFiKa4mMvF2yGVmCKc9mplibFqt
ouqW4Ctzi+6LFTLo0BhrLqlU/EowS+2sQhkHPox8ggyegxGkZ2SvGY7xWPiT9zGw
lX3VOogquVVVztTzPcjnUzCsEgL8wgtsriY5VM/Y45STmkpKkd2rIJgNRwJVsdHm
NwIDAQAB
-----END PUBLIC KEY-----" > bad-root.pub
client "bad-root.pub" "user-0-key.pem" "user-$(id -u)-key.pem"
cant "operate on file system with untrusted root" "stat ."
popc


section "Forking attack!"
pushc "forked-client"
client
info "forking server"
kill -USR2 "$server"
expect "echo b | tee shared/lost-to-fork" "cat shared/lost-to-fork" '^b$' || fail "couldn't create file for forking test"
info "making server go back in time"
kill -USR2 "$server"
cant "trick client into accepting old changes" "grep b shared/lost-to-fork"
popc


section "Malicious client"
echo "-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAtYNapo/Ft6vYM/xz3bJFLB7PNarnpaDn6BWtSu/LXqzhIFqY
z+tUZTBbW4v0jvE9bnU4mMiKwSaD9HjQHMzhaaDmVsmOrY0S2kkl7GWTphurZ1q9
2y89pnzn7by1QiUoyfNAzasKS8BkqfYG3pZ6kb8STua87jPZaJuxIMJrD/CTZxT+
LqpuYzfIpNEYEwlDAFWgkakR5mffS13Nj3QA5IgHiTIrLkyvUIeBNUWGyz9jbq2p
u4Xo13Mp5S1qj1xzZyC2lB0gnl3XQFF/GLvSksGk9GCfaaGqBcuc8QGi8YPz13Tq
9SGjM9mrugKK3LIeA8+YrkXRl7/8B1VGEakU8QIDAQABAoIBAGeBrCPnQJxohjW+
9GOr0P5D4217M/WjOBuEoPlmnNY0R3ynrRSD4fCCDta5jJAmyR1AAzI8ycMzL3Qt
oJ+Lxc7yTeeXsKEPHX0U0Wdo1TWX+bpKaJGg8ssJ10geoE5D2mqvKHkf3BMudzjk
by5nKSYLi2kq8vny3ztj7TH9LAg99ioYOx8k7w+E7nD3fVJjMmfRTEb3RibNoQzm
C6JXJtY9snpTvQdANXp8eW7I7qtQKQTYVIb1QeoJyeD7GUcaGqJxTm87ZhBZD0aw
UFwi9fpEp7lAXNQ2WB01LS/NMCeFeK/61MgzkA4d+QuqvSyyFjrVnTEXSB/PzNKL
JUNNAHECgYEA2/SWTp3AtxO308IbXokxQjUl7lfiHlaqgA/jaKxBc08joQEFoA1y
PD2YIrOhXv2rXcXXI+ktMc8OV5ynUScfEfVfdPXgcthbmaawMCnZD3leAn7GUtpg
nSzg34Kd5vwHVT4N2MTriZNRYE/C3PC7m2EJlEWLvT8L7SgkEWEQtn8CgYEA00IP
9AseEA6Bsl9QDesOXBILlQPpVLxZR7Sl3+JiP6ze2Nhp+qdvQUT0VEOJRBQPPQ5K
qap+k3jfqDR80pAHcfaCXes4ERLRR3BCNXKocKTBhXv8g7ZVGtoWGRsFnWchtEpN
MzZRt735RXU82fUsqRJuLAnkPXP3kVznjjCC3I8CgYADe9Y9nIYG4EsTEYn5b1bW
Y50cL0wnitvcd2P0rnXC68f2rtt184CRr7APLKUrqfzi2VVU/kZ2+X6SqKqFwIbf
c/F1GsfZSc/5mQhFWwRTGGsCwxtFCKxrEODm6Vyy4d8D3J2/hy7r2Od7DQhbE30F
Mv5B2PAjqTH5KZ+Ynt7y5QKBgE+qV+3Fy35umgYz3zKAc5fQzkFRikoEBP7/ZpX4
/ufYPukzIzP8s/2/DQxBs5/SmLSDkTBONRFTwbPipzeYTNZzCVJ1g10c5YK1GKKj
LFXeK4Q071KUDZ/kofSxtfpXi+Q7KMWpNEPABiJlRZ9Dz6WqZ5V/3Ww3MSLGECQU
sySNAoGBAIFS43GjMqBnRNTQiv3n7OVqhF6QyqSzUi5Ualvc+Q1O/gbZhY3+83VA
PuP3wNqBviL2JwkC4aC6xLqaj1eiB8oV7XjeINBvMffyMOGYUmFa9Zj++CdFsE3s
JQIsH8KvcFwPgc8vBbhaLPwfNdGnKS2hx/WNYrYVlCKiMvRPcZoH
-----END RSA PRIVATE KEY-----" > bad-user.pem
mv -f "user-$(id -u)-key.pem" "good-user.pem"
mv -f "bad-user.pem" "user-$(id -u)-key.pem"
pushc "malicious-client"
client "root.pub" "user-$(id -u)-key.pem"
(try "echo be-afraid | tee -a shared/user-file")
popc
mv -f "good-user.pem" "user-$(id -u)-key.pem"
cant "successfully read file modified by malicious user" "grep be-afraid shared/user-file"

cleanup

info "all tests done (passed %d/%d -- %.1f%%); cleaning up\n" "$passed" "$tests" "$(echo "100*$passed/$tests" | bc -l)"
