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

rundir=$(mktemp -d secfs-test.XXXXXXXXXX)
mntat="$rundir/mnt"
mkdir "$mntat"
uxsock="$rundir/sock"

# Build and enable
# shellcheck disable=SC1091
. venv/bin/activate
pip3 install --upgrade -e . > pip.log

env PYTHONUNBUFFERED=1 venv/bin/secfs-server "$uxsock" > server.log 2> server.err &
server=$!
sync
while ! grep -P "^uri =" server.log > /dev/null; do
	sleep .2
done
uri=$(grep "uri = PYRO:secfs" server.log | awk '{print $3}')

# colors from http://stackoverflow.com/questions/4332478/read-the-current-text-color-in-a-xterm/4332530#4332530
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
BLUE=$(tput setaf 4)
YELLOW=$(tput setaf 3)
NORMAL=$(tput sgr0)

INFO="[ ${BLUE}INFO${NORMAL} ]"
PASS="[ ${GREEN}PASS${NORMAL} ]"
FAIL="[ ${RED}FAIL${NORMAL} ]"
OHNO="[ ${RED}OHNO${NORMAL} ]"
DOTS="[ ${YELLOW}....${NORMAL} ]"
WARN="[ ${YELLOW}INFO${NORMAL} ]"
printf "${INFO}: connecting to server at %s\n" "$uri"

fuse=0
nxt_fname="primary-client"
client() {
	rm -f "$nxt_fname.log" 2>/dev/null
	if [ $# -eq 0 ]; then
		sudo PYTHONUNBUFFERED=1 venv/bin/secfs-fuse "$uri" "$mntat" "root.pub" "user-0-key.pem" "user-$(id -u)-key.pem" "user-666-key.pem" > "$nxt_fname.log" 2> "$nxt_fname.err" &
		fuse=$!
	else
		sudo PYTHONUNBUFFERED=1 venv/bin/secfs-fuse "$uri" "$mntat" "$@" > "$nxt_fname.log" 2> "$nxt_fname.err" &
		fuse=$!
	fi
	printf "${INFO}: client started; waiting for init\n" "$uri"

	sync
	while ! grep -P "^ready$" "$nxt_fname.log" > /dev/null; do
		sleep .2
	done

	printf "${INFO}: client ready; continuing with tests\n" "$uri"
}
client_cleanup() {
	sudo umount "$mntat" 2>/dev/null
	sleep 1 # give it time to unmount cleanly
	sudo kill -9 $fuse 2>/dev/null
	wait $fuse 2>/dev/null
	if [ $? -ne 0 ]; then
		printf "${INFO}: $nxt_fname died\n" "$uri"
	else
		printf "${INFO}: $nxt_fname exited cleanly\n" "$uri"
	fi
	sudo umount "$mntat" 2>/dev/null

	# make server release global lock just in case
	# this may be needed even if the client excited with exit=0!
	printf "${INFO}: making server release lock\n" "$uri"
	kill -USR1 "$server"
}
_mntat=""
_fuse=""
pushc() {
	_mntat="$mntat"
	_fuse=$fuse
	mntat="$rundir/mnt-$1"
	if [ ! -d "$mntat" ]; then
		mkdir "$mntat"
	fi
	nxt_fname="$1"
}
popc() {
	client_cleanup

	# Restore old client parameters
	nxt_fname="primary-client"
	mntat="$_mntat"
	fuse=$_fuse
	_mntat=''
	_fuse=''
}

cleanup() {
	if [ -n "$1" ]; then
		printf "${OHNO}: Server or client died!\n" >/dev/stderr
	fi

	if [ -n "$_fuse" ]; then
		# clean nested instance
		popc
	fi
	client_cleanup
	kill $server 2>/dev/null
	wait $server 2>/dev/null

	rm -rf "$rundir"

	if [ -n "$1" ]; then
		printf "${WARN}: partial test completion (passed %d/%d -- %.1f%%); cleaning up\n" "$passed" "$tests" "$(echo 100*$passed/$tests | bc -l)"
	fi
}

tests=0
passed=0

section() {
	printf "\n${INFO}: Entering section %s\n" "$1"
}

try() {
	if ! sudo kill -0 $fuse 2> /dev/null; then
		if [ -z "$_fuse" ]; then
			# Primary client died. Game over.
			return 255
		else
			# Non-primary client died, but there may be other tests we can do
			return 254
		fi

	fi

	shcmd="$1"
	cd "$mntat" 2>/dev/null
	ex=$?
	if [ $ex -ne 0 ]; then
		echo "could not enter mountpoint; got no such file or directory"
		return $ex
	fi

	# work around llfuse context bug
	echo "$shcmd" | grep 'sudo ' > /dev/null
	if [ $? -eq 0 ]; then
		sudo mknod x p 2>/dev/null
	else
		mknod x p 2>/dev/null
	fi
	sh -c "$shcmd" 2>&1
	ex=$?

	if ! sudo kill -0 $server 2> /dev/null; then
		return 255
	fi
	if ! sudo kill -0 $fuse 2> /dev/null; then
		if [ -z "$_fuse" ]; then
			# Primary client died. Game over.
			return 255
		fi
	fi

	return $ex
}

fstats() {
	tests="$(echo $tests+1 | bc -l)"

	file="$1"; shift

	o=$(printf "${DOTS}: testing permissions on file %s\r" "$file")
	lastlen=${#o}
	printf "%s" "$o"
	stats=$(try "stat -c '%A %U %G' '$file'")
	e=$?
	if [ $e -ne 0 ]; then
		if [ $e -eq 255 ]; then
			printf "\n"
			cleanup 1
			exit 1
		fi
		printf "\n%s\n" "$stats"
		return 1
	fi

	output=""
	while [ $# -ne 0 ]; do
		f=$(echo "$1" | awk -F= '{print $1}')
		v=$(echo "$1" | awk -F= '{print $2}')
		shift

		printf "%${lastlen}s\r" " " # clear previous message
		o=$(printf "${DOTS}: test %s of %s = %s\r" "$f" "$file" "$v")
		lastlen=${#o}
		printf "%s" "$o"

		real_v=""
		case $f in
			perm) real_v="$(echo "$stats" | awk '{print $1}')" ;;
			uid) real_v="$(echo "$stats" | awk '{print $2}')" ;;
			gid) real_v="$(echo "$stats" | awk '{print $3}')" ;;
		esac

		if [ "$real_v" != "$v" ]; then
			printf "\n%s != %s (was %s)\n" "$f" "$v" "$real_v"
			return 1
		fi
	done
	printf "%${lastlen}s\r" " " # clear previous message
	printf "${PASS}: correct permissions on %s\n" "$file"
	passed="$(echo $passed+1 | bc -l)"
	return 0
}

cant() {
	tests="$(echo $tests+1 | bc -l)"

	name="$1"
	shift

	output=""
	lastlen=0
	while [ $# -ne 0 ]; do
		shcmd="$1"
		shift

		printf "%${lastlen}s\r" " " # clear previous message
		o=$(printf "${DOTS}: ensure failure of %s\r" "$shcmd")
		lastlen=${#o}
		printf "%s" "$o"

		output=$(try "$shcmd")
		e=$?
		if [ $e -eq 0 ] || [ $e -eq 255 ]; then
			printf "%${lastlen}s\r" " " # clear previous message
			printf "%s\n${FAIL}: could %s\n" "$output" "$name"
			if [ $e -eq 255 ]; then
				cleanup 1
				exit 1
			fi
			return 1
		fi
	done

	printf "%${lastlen}s\r" " " # clear previous message
	printf "${PASS}: can't %s\n" "$name"
	passed="$(echo $passed+1 | bc -l)"
	return 0
}

expect() {
	tests="$(echo $tests+1 | bc -l)"

	output=""
	lastlen=0
	cmds=""
	while [ $# -ne 1 ]; do
		shcmd="$1"
		shift

		if [ -z "$cmds" ]; then
			cmds="$shcmd"
		else
			cmds="${cmds}; ${shcmd}"
		fi

		printf "%${lastlen}s\r" " " # clear previous message
		o=$(printf "${DOTS}: test %s\r" "$shcmd")
		lastlen=${#o}
		printf "%s" "$o"

		output=$(try "$shcmd")
		e=$?
		if [ $e -ne 0 ]; then
			if [ $e -eq 255 ]; then
				printf "\n"
				cleanup 1
				exit 1
			fi
			printf "\n%s\n" "$output"
			return 1
		fi
	done

	patt="$1"
	if [ "$patt" = '^$' ]; then
		echo "$output" | pcregrep -Mv "." > /dev/null
		ex=$?
	else
		echo "$output" | pcregrep -M "$patt" > /dev/null
		ex=$?
	fi
	if [ $ex -eq 0 ]; then
		printf "%${lastlen}s\r" " " # clear previous message
		printf "${PASS}: (%s) | grep '%s'\n" "$cmds" "$patt"
		passed="$(echo $passed+1 | bc -l)"
		return 0
	else
		printf "\n%s\n" "$output"
		return 1
	fi
}

server_mem() {
	tests="$(echo $tests+1 | bc -l)"

	type="$1"
	string="$2"
	o=$(printf "${DOTS}: ensure $type file data not in server memory\r")
	lastlen=${#o}
	printf "%s" "$o"
	sudo gcore $server 2>/dev/null >/dev/null
	grep -lia "$string" "core.$server" >/dev/null
	ex=$?
	rm -f "core.$server"
	if [ $ex -eq 0 ]; then
		printf "%${lastlen}s\r${FAIL}: found $type file data in server memory\n" " "
	else
		printf "%${lastlen}s\r${PASS}: $type file data not in server memory\n" " "
		passed="$(echo $passed+1 | bc -l)"
	fi
}

# start client with fresh keys
sudo rm -f root.pub user-*-key.pem
client


section "Initializtion"
expect "ls -la" ' *\.\/?$' || printf "${FAIL}: root directory does not contain .\n"
expect "ls -la" ' *\.\.\/?$' || printf "${FAIL}: root directory does not contain ..\n"
expect "ls -la" ' *\.users$' || printf "${FAIL}: root directory does not contain .users\n"
expect "ls -la" ' *\.groups$' || printf "${FAIL}: root directory does not contain .groups\n"
fstats "." "uid=root" "perm=drwxr-xr-x" || printf "${FAIL}: root directory . has incorrect permissions\n"
fstats ".users" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: /.users has incorrect permissions\n"
fstats ".groups" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: /.groups has incorrect permissions\n"
expect "cat .users" '.+' || printf "${FAIL}: .users couldn't be read\n"
expect "cat .groups" '.+' || printf "${FAIL}: .groups couldn't be read\n"


section "Manipulating the root directory"
# root single-user write
expect "echo x | sudo tee root-file" "sudo cat root-file" '^x$' || printf "${FAIL}: couldn't read back root created file\n"
expect "echo x | sudo tee -a root-file" "sudo cat root-file" '^x\nx$' || printf "${FAIL}: couldn't read back root appended file\n"

cant "create user file in root dir" "echo b | tee user-file" "cat user-file"
cant "append to root file as user" "echo b | tee -a root-file" "pcregrep -M '^x\nb$ root-file"
cant "make user directory in root dir" "mkdir user-only" "stat user-only"
fstats "root-file" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: new root file has incorrect permissions\n"

# root single-user dir
expect "sudo mkdir root-only" '^$' || printf "${FAIL}: couldn't make root directory\n"
expect "sudo ls -la root-only" ' *\.\/?$' || printf "${FAIL}: new root directories don't have .\n"
expect "sudo ls -la root-only" ' *\.\.\/?$' || printf "${FAIL}: new root directories don't have ..\n"
expect "sudo ls -la root-only/.." ' *\.users$' || printf "${FAIL}: new root directory .. doesn't point to root\n"
expect "echo a | sudo tee root-only/file" "sudo cat root-only/file" '^a$' || printf "${FAIL}: couldn't read back root created file in directory\n"
expect "echo a | sudo tee -a root-only/file" "sudo cat root-only/file" '^a\na$' || printf "${FAIL}: couldn't read back root appended file in directory\n"
expect "sudo ls -la root-only/." ' *file$' || printf "${FAIL}: new root directory . does not point to self\n"

cant "create file in dir owned by other user" "echo b | tee root-only/user-file" "cat root-only/user-file"
cant "append to file owned by other user" "echo b | tee -a root-only/file" "pcregrep -M '^a\nb$ root-only/file"
cant "make directory in dir owned by other user" "mkdir root-only/user-only" "stat root-only/user-only"
fstats "root-only" "uid=root" "perm=drwxr-xr-x" || printf "${FAIL}: new root dir has incorrect permissions\n"
fstats "root-only/file" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: new nested root file has incorrect permissions\n"


section "Manipulating shared directories"
# shared directory mkdir
expect "sudo sh -c 'umask 0200; sg users \"mkdir shared\"'" '^$' || printf "${FAIL}: couldn't create group-owned directory\n"
expect "sudo ls -la shared/.." ' *\.users/?$' || printf "${FAIL}: new shared directory .. doesn't point to root\n"
fstats "shared" "uid=root" "gid=users" "perm=dr-xrwxr-x" || printf "${FAIL}: new shared dir has incorrect permissions\n"

# user file in shared dir
user=$(id -un)
expect "echo b | tee shared/user-file" "cat shared/user-file" '^b$' || printf "${FAIL}: couldn't create user file in shared directory\n"
expect "echo b | tee -a shared/user-file" "cat shared/user-file" '^b\nb$' || printf "${FAIL}: couldn't appended to user file in shared directory\n"
fstats "shared/user-file" "uid=$user" "perm=-rw-r--r--" || printf "${FAIL}: new user file has incorrect permissions\n"
cant "append to file owned by other user as root" "echo x | sudo tee -a shared/user-file" "pcregrep -M '^b\nx$ shared/user-file"


section "Manipulating non-owner directories"
# user dir in shared dir
expect "mkdir shared/user-only" '^$' || printf "${FAIL}: couldn't make user directory in shared dir\n"
expect "ls -la shared/user-only" ' *\.\/?$' || printf "${FAIL}: new user directories don't have .\n"
expect "ls -la shared/user-only" ' *\.\.\/?$' || printf "${FAIL}: new user directories don't have ..\n"
expect "ls -la shared/user-only/.." ' *user-only/?$' || printf "${FAIL}: new user directory .. doesn't point to parent\n"
expect "echo c | tee shared/user-only/file" "cat shared/user-only/file" '^c$' || printf "${FAIL}: couldn't read back user created file\n"
expect "echo c | tee -a shared/user-only/file" "cat shared/user-only/file" '^c\nc$' || printf "${FAIL}: couldn't read back user appended file\n"
expect "ls -la shared/user-only/." ' *file$' || printf "${FAIL}: new user directory . does not point to self\n"

cant "create file in dir owned by other user as root" "echo b | sudo tee shared/user-only/root-file" "cat shared/user-only/root-file"
cant "append to file owned by other user as root" "echo x | sudo tee -a shared/user-only/file" "pcregrep -M '^c\nx$ shared/user-only/file"
cant "make directory in dir owned by other user as root" "sudo mkdir shared/user-only/root-dir" "stat shared/user-only/root-dir"
fstats "shared/user-only" "uid=$user" "perm=drwxr-xr-x" || printf "${FAIL}: new user dir has incorrect permissions\n"
fstats "shared/user-only/file" "uid=$user" "perm=-rw-r--r--" || printf "${FAIL}: new nested user file has incorrect permissions\n"


section "Restricted read permissions"
# Encrypted files (no read permission)
expect "sudo sh -c 'umask 0004; echo supercalifragilisticexpialidocious > root-secret'" '^$' || printf "${FAIL}: couldn't create user-readable file as user\n"
expect "sudo cat root-secret" '^supercalifragilisticexpialidocious$' || printf "${FAIL}: couldn't read user-readable file as user\n"
server_mem "user-readable" "supercalifragilisticexpialidocious"
fstats "root-secret" "uid=root" "perm=-rw-------" || printf "${FAIL}: encrypted file has incorrect permissions\n"
cant "read encrypted file belonging to other user" "cat root-secret"
expect "echo y | sudo tee -a root-secret" "sudo cat root-secret" '^supercalifragilisticexpialidocious\ny$' || printf "${FAIL}: failed to append to encrypted file\n"

# Encrypted shared files (no read permission)
expect "sudo sh -c 'umask 0204; echo dociousaliexpilisticfragicalirupes | sg users \"tee group-secret\"'" '^dociousaliexpilisticfragicalirupes$' || printf "${FAIL}: couldn't create group-readable file as root\n"
server_mem "group-readable" "dociousaliexpilisticfragicalirupes"
fstats "group-secret" "uid=root" "gid=users" "perm=-r--rw----" || printf "${FAIL}: group encrypted file has incorrect permissions\n"
expect "cat group-secret" '^dociousaliexpilisticfragicalirupes$' || printf "${FAIL}: couldn't read group-readable file as group member\n"
expect "sudo cat group-secret" '^dociousaliexpilisticfragicalirupes$' || printf "${FAIL}: couldn't read group-readable file as non-owning group member\n"
expect "echo z | sudo tee -a group-secret" "sudo cat group-secret" '^dociousaliexpilisticfragicalirupes\nz$' || printf "${FAIL}: failed to append to group encrypted file\n"


section "Read-only client with root key access"
pushc "ro-client-with-root"
client
expect "ls -la" ' *\.\/?$' || printf "${FAIL}: root directory does not contain .\n"
expect "ls -la" ' *\.\.\/?$' || printf "${FAIL}: root directory does not contain ..\n"
expect "ls -la" ' *\.users$' || printf "${FAIL}: root directory does not contain .users\n"
expect "ls -la" ' *\.groups$' || printf "${FAIL}: root directory does not contain .groups\n"
fstats "." "uid=root" "perm=drwxr-xr-x" || printf "${FAIL}: root directory . has incorrect permissions\n"
fstats ".users" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: /.users has incorrect permissions\n"
fstats ".groups" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: /.groups has incorrect permissions\n"
expect "cat .users" '.+' || printf "${FAIL}: .users couldn't be read\n"
expect "cat .groups" '.+' || printf "${FAIL}: .groups couldn't be read\n"
popc


section "Read-only client without root key access"
pushc "ro-client-without-root"
client "root.pub" "user-$(id -u)-key.pem"
expect "ls -la" ' *\.\/?$' || printf "${FAIL}: root directory does not contain .\n"
expect "ls -la" ' *\.\.\/?$' || printf "${FAIL}: root directory does not contain ..\n"
expect "ls -la" ' *\.users$' || printf "${FAIL}: root directory does not contain .users\n"
expect "ls -la" ' *\.groups$' || printf "${FAIL}: root directory does not contain .groups\n"
fstats "." "uid=root" "perm=drwxr-xr-x" || printf "${FAIL}: root directory . has incorrect permissions\n"
fstats ".users" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: /.users has incorrect permissions\n"
fstats ".groups" "uid=root" "perm=-rw-r--r--" || printf "${FAIL}: /.groups has incorrect permissions\n"
expect "cat .users" '.+' || printf "${FAIL}: .users couldn't be read\n"
expect "cat .groups" '.+' || printf "${FAIL}: .groups couldn't be read\n"
popc


section "Writing client"
pushc "writing-client"
client
expect "echo b | tee shared/third-client-file" "cat shared/third-client-file" '^b$' || printf "${FAIL}: couldn't create file as user in separate client\n"
expect "echo b | tee -a shared/third-client-file" "cat shared/third-client-file" '^b\nb$' || printf "${FAIL}: couldn't append to file as user in separate client\n"
popc

expect "cat shared/third-client-file" '^b\nb$' || printf "${FAIL}: couldn't read back file created by user in separate client\n"


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
printf "${INFO}: forking server\n" "$uri"
kill -USR2 "$server"
expect "echo b | tee shared/lost-to-fork" "cat shared/lost-to-fork" '^b$' || printf "${FAIL}: couldn't create file for forking test\n"
printf "${INFO}: making server go back in time\n" "$uri"
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

printf "${INFO}: all tests done (passed %d/%d -- %.1f%%); cleaning up\n" "$passed" "$tests" "$(echo 100*$passed/$tests | bc -l)"
