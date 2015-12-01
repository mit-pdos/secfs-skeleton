#!/bin/sh

rundir=$(mktemp -d secfs-test.XXXXXXXXXX)
mntat="$rundir/mnt"
mkdir "$mntat"
server=0 # PID of server, set by includer
uri="" # set by includer

# shellcheck disable=SC2034
uxsock="$rundir/sock" # read by includer

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

fuse=0
nxt_fname="primary-client"
client() {
	rm -f "$nxt_fname.log" 2>/dev/null
	if [ $# -eq 0 ]; then
		# shellcheck disable=SC2024
		sudo PYTHONUNBUFFERED=1 venv/bin/secfs-fuse "$uri" "$mntat" "root.pub" "user-0-key.pem" "user-$(id -u)-key.pem" "user-666-key.pem" > "$nxt_fname.log" 2> "$nxt_fname.err" &
		fuse=$!
	else
		# shellcheck disable=SC2024
		sudo PYTHONUNBUFFERED=1 venv/bin/secfs-fuse "$uri" "$mntat" "$@" > "$nxt_fname.log" 2> "$nxt_fname.err" &
		fuse=$!
	fi
	info "client started; waiting for init"

	sync
	while ! grep -P "^ready$" "$nxt_fname.log" > /dev/null; do
		sleep .2
	done

	info "client ready; continuing with tests"
}
client_cleanup() {
	sudo umount "$mntat" 2>/dev/null
	sleep 1 # give it time to unmount cleanly
	sudo kill -9 $fuse 2>/dev/null
	wait $fuse 2>/dev/null
	if [ $? -ne 0 ]; then
		info "$nxt_fname died"
	else
		info "$nxt_fname exited cleanly"
	fi
	sudo umount "$mntat" 2>/dev/null

	# make server release global lock just in case
	# this may be needed even if the client excited with exit=0!
	info "making server release lock"
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
		ohno "Server or client died!"
	fi

	if [ -n "$_fuse" ]; then
		# clean nested instance
		popc
	fi
	client_cleanup
	kill "$server" 2>/dev/null
	wait "$server" 2>/dev/null

	rm -rf "$rundir"

	if [ -n "$1" ]; then
		warn "partial test completion (passed %d/%d -- %.1f%%); cleaning up\n" "$passed" "$tests" "$(echo "100*$passed/$tests" | bc -l)"
	fi
}

tests=0
passed=0

msg() {
	local type="$1"
	shift
	local fmt="$1"
	shift
	local msg
	# shellcheck disable=SC2059
	msg="$(printf "$fmt" "$@")"
	printf "%s: %s\n" "$type" "$msg"
}
info() {
	msg "$INFO" "$@"
}
warn() {
	msg "$WARN" "$@"
}
fail() {
	msg "$FAIL" "$@"
}
ohno() {
	msg "$OHNO" "$@" > /dev/stderr
}
section() {
	echo ""
	info "Entering section %s." "$1"
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

	local shcmd="$1"
	# shellcheck disable=SC2164
	cd "$mntat" 2>/dev/null
	local ex=$?
	if [ $ex -ne 0 ]; then
		echo "could not enter mountpoint; got no such file or directory"
		return $ex
	fi

	# work around llfuse context bug
	# this is such a hack
	echo "$shcmd" | grep 'sudo ' > /dev/null
	if [ $? -eq 0 ]; then
		echo "$shcmd" | grep 'sudo -u' > /dev/null
		if [ $? -eq 0 ]; then
			user="$(echo "$shcmd" | sed 's/.*sudo -u \([^ ]\+\).*/\1/')"
			sudo -u "$user" mknod x p 2>/dev/null
		else
			sudo mknod x p 2>/dev/null
		fi
	else
		mknod x p 2>/dev/null
	fi
	sh -c "$shcmd" 2>&1
	ex=$?

	if ! sudo kill -0 "$server" 2> /dev/null; then
		return 255
	fi
	if ! sudo kill -0 "$fuse" 2> /dev/null; then
		if [ -z "$_fuse" ]; then
			# Primary client died. Game over.
			return 255
		fi
	fi

	return $ex
}

fstats() {
	tests="$(echo "$tests+1" | bc -l)"

	local file="$1"; shift

	local o
	o=$(printf "${DOTS}: testing permissions on file %s\r" "$file")
	local lastlen=${#o}
	printf "%s" "$o"
	local stats
	local ex
	stats=$(try "stat -c '%A %U %G' '$file'")
	ex=$?
	if [ $ex -ne 0 ]; then
		if [ $ex -eq 255 ]; then
			printf "\n"
			cleanup 1
			exit 1
		fi
		printf "\n%s\n" "$stats"
		return 1
	fi

	local output=""
	while [ $# -ne 0 ]; do
		local f
		local v
		f=$(echo "$1" | awk -F= '{print $1}')
		v=$(echo "$1" | awk -F= '{print $2}')
		shift

		printf "%${lastlen}s\r" " " # clear previous message
		o=$(printf "${DOTS}: test %s of %s = %s\r" "$f" "$file" "$v")
		lastlen=${#o}
		printf "%s" "$o"

		local real_v=""
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
	tests="$(echo "$tests+1" | bc -l)"

	local name="$1"
	shift

	local output=""
	local lastlen=0
	while [ $# -ne 0 ]; do
		shcmd="$1"
		shift

		printf "%${lastlen}s\r" " " # clear previous message
		o=$(printf "${DOTS}: ensure failure of %s\r" "$shcmd")
		lastlen=${#o}
		printf "%s" "$o"

		output=$(try "$shcmd")
		local ex=$?
		if [ $ex -eq 0 ] || [ $ex -eq 255 ]; then
			printf "%${lastlen}s\r" " " # clear previous message
			printf "%s\n${FAIL}: could %s\n" "$output" "$name"
			if [ $ex -eq 255 ]; then
				cleanup 1
				exit 1
			fi
			return 1
		fi
	done

	printf "%${lastlen}s\r" " " # clear previous message
	printf "${PASS}: can't %s\n" "$name"
	passed="$(echo "$passed+1" | bc -l)"
	return 0
}

expect() {
	tests="$(echo "$tests+1" | bc -l)"

	local output=""
	local lastlen=0
	local cmds=""
	local ex=0
	while [ $# -ne 1 ]; do
		local shcmd="$1"
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
		ex=$?
		if [ $ex -ne 0 ]; then
			if [ $ex -eq 255 ]; then
				printf "\n"
				cleanup 1
				exit 1
			fi
			printf "\n%s\n" "$output"
			return 1
		fi
	done

	local patt="$1"
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
		passed="$(echo "$passed+1" | bc -l)"
		return 0
	else
		printf "\n%s\n" "$output"
		return 1
	fi
}

server_mem() {
	tests="$(echo "$tests+1" | bc -l)"

	local type="$1"
	local string="$2"
	o=$(printf "%s: ensure %s file data not in server memory\r" "$DOTS" "$type")
	local lastlen=${#o}
	printf "%s" "$o"
	sudo gcore $server 2>/dev/null >/dev/null
	grep -lia "$string" "core.$server" >/dev/null
	local ex=$?
	rm -f "core.$server"
	if [ $ex -eq 0 ]; then
		printf "%${lastlen}s\r${FAIL}: found $type data in server memory\n" " "
	else
		printf "%${lastlen}s\r${PASS}: $type data not in server memory\n" " "
		passed="$(echo "$passed+1" | bc -l)"
	fi
}

