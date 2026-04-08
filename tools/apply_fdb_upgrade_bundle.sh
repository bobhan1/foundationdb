#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
  apply_fdb_upgrade_bundle.sh --bundle /path/to/bundle.tar.gz --hosts host1,host2 [options]
  apply_fdb_upgrade_bundle.sh --bundle /path/to/bundle.tar.gz --hosts-file hosts.txt [options]

This script does not download from GitHub. It only uses a prebuilt bundle.
It assumes fdbmonitor is already deployed and running on each host, and that
the existing fdbmonitor is compatible with the new fdbserver.

Modes:
  default          prepare + activate
  --prepare-only   only distribute and unpack the bundle on all hosts
  --activate-only  only do switch symlink + "kill; kill all"

Options:
  --bundle PATH                Prebuilt bundle tar.gz. Required.
  --hosts HOST1,HOST2,...      Host list
  --hosts-file FILE            Host list file
  --ssh-user USER              Default: current user
  --ssh-port PORT              Default: 22
  --fdb-root PATH              Default: /mnt/disk1/foundationdb
  --pkg-root PATH              Default: /mnt/hdd01/tools/fdb/pkgs
  --cluster-file PATH          Default: <fdb-root>/conf/fdb.cluster
  --verify-timeout SEC         Default: 180
  --skip-cluster-verify        Skip final fdbcli status check
  --prepare-only               Only distribute and stage package files
  --activate-only              Assume files are already staged, only switch and run "kill; kill all"
  --yes                        Execute. Without this flag the script prints the plan and exits.
  -h, --help                   Show help
EOF
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

trim() {
	local value=$1
	value=${value#"${value%%[![:space:]]*}"}
	value=${value%"${value##*[![:space:]]}"}
	printf '%s' "$value"
}

BUNDLE=''
SSH_USER=${USER:-root}
SSH_PORT='22'
FDB_ROOT='/mnt/disk1/foundationdb'
PKG_ROOT='/mnt/hdd01/tools/fdb/pkgs'
VERIFY_TIMEOUT='180'
VERIFY_CLUSTER='1'
CONFIRM='0'
MODE='full'
HOSTS_CSV=''
HOSTS_FILE=''

while (($#)); do
	case "$1" in
		--bundle)
			shift
			BUNDLE=${1:?missing value for --bundle}
			;;
		--hosts)
			shift
			HOSTS_CSV=${1:?missing value for --hosts}
			;;
		--hosts-file)
			shift
			HOSTS_FILE=${1:?missing value for --hosts-file}
			;;
		--ssh-user)
			shift
			SSH_USER=${1:?missing value for --ssh-user}
			;;
		--ssh-port)
			shift
			SSH_PORT=${1:?missing value for --ssh-port}
			;;
		--fdb-root)
			shift
			FDB_ROOT=${1:?missing value for --fdb-root}
			;;
		--pkg-root)
			shift
			PKG_ROOT=${1:?missing value for --pkg-root}
			;;
		--cluster-file)
			shift
			CLUSTER_FILE=${1:?missing value for --cluster-file}
			;;
		--verify-timeout)
			shift
			VERIFY_TIMEOUT=${1:?missing value for --verify-timeout}
			;;
		--skip-cluster-verify)
			VERIFY_CLUSTER='0'
			;;
		--prepare-only)
			MODE='prepare'
			;;
		--activate-only)
			MODE='activate'
			;;
		--yes)
			CONFIRM='1'
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
	shift
done

[[ -n ${BUNDLE} ]] || die "--bundle is required"
[[ -f ${BUNDLE} ]] || die "bundle not found: ${BUNDLE}"

if [[ -z ${HOSTS_CSV} && -z ${HOSTS_FILE} ]]; then
	die "one of --hosts or --hosts-file is required"
fi
if [[ -n ${HOSTS_CSV} && -n ${HOSTS_FILE} ]]; then
	die "use only one of --hosts or --hosts-file"
fi

CLUSTER_FILE=${CLUSTER_FILE:-${FDB_ROOT}/conf/fdb.cluster}

command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v scp >/dev/null 2>&1 || die "scp is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

declare -a HOSTS=()
if [[ -n ${HOSTS_CSV} ]]; then
	IFS=',' read -r -a raw_hosts <<< "${HOSTS_CSV}"
	for host in "${raw_hosts[@]}"; do
		host=$(trim "$host")
		[[ -n ${host} ]] && HOSTS+=("${host}")
	done
else
	while IFS= read -r line; do
		line=$(trim "${line%%#*}")
		[[ -n ${line} ]] && HOSTS+=("${line}")
	done < "${HOSTS_FILE}"
fi
((${#HOSTS[@]} > 0)) || die "no hosts provided"

SSH_OPTS=(
	-p "${SSH_PORT}"
	-o BatchMode=yes
	-o StrictHostKeyChecking=accept-new
	-o ConnectTimeout=10
)

manifest_tmp=$(mktemp)
trap 'rm -f "${manifest_tmp}"' EXIT
tar -xOf "${BUNDLE}" manifest.env > "${manifest_tmp}"
# shellcheck disable=SC1090
source "${manifest_tmp}"

[[ -n ${PRIMARY_VERSION:-} ]] || die "bundle manifest missing PRIMARY_VERSION"
[[ -n ${ARCH:-} ]] || die "bundle manifest missing ARCH"

bundle_basename=$(basename "${BUNDLE}")

REMOTE_SCRIPT=$(cat <<'EOF_REMOTE'
set -euo pipefail

phase=$1

log() {
	printf '[remote %s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

resolve_version() {
	RESOLVED_VERSION=${PRIMARY_VERSION}
}

assets() {
	printf '%s\n' "fdbserver.${ARCH}" "fdbcli.${ARCH}" "fdbbackup.${ARCH}"
}

verify_version_dir() {
	local version=$1
	local dir="${PKG_ROOT}/${version}"

	[[ -d ${dir} ]] || die "staged version dir missing: ${dir}"
	while IFS= read -r asset; do
		[[ -f ${dir}/${asset} ]] || die "missing ${dir}/${asset}"
		chmod 0755 "${dir}/${asset}"
	done < <(assets)
}

target_server_exe() {
	printf '%s' "${PKG_ROOT}/${PRIMARY_VERSION}/fdbserver.${ARCH}"
}

target_cli_exe() {
	printf '%s' "${PKG_ROOT}/${PRIMARY_VERSION}/fdbcli.${ARCH}"
}

current_server_exe() {
	local pid
	pid=$(pgrep -xo fdbserver || true)
	[[ -n ${pid} ]] || return 1
	readlink -f "/proc/${pid}/exe"
}

phase_unpack() {
	local incoming_dir="${PKG_ROOT}/.bundle-incoming"
	local work_dir="${incoming_dir}/extract.$$"
	local bundle_path="${incoming_dir}/${BUNDLE_BASENAME}"

	[[ -f ${bundle_path} ]] || die "bundle not found on host: ${bundle_path}"

	rm -rf "${work_dir}"
	mkdir -p "${work_dir}"
	tar -xzf "${bundle_path}" -C "${work_dir}"

	for version in "${PRIMARY_VERSION}"; do
		local src="${work_dir}/packages/${version}"
		local dst="${PKG_ROOT}/${version}"
		[[ -d ${src} ]] || die "bundle package missing: ${src}"
		mkdir -p "${dst}"
		cp -fp "${src}/"* "${dst}/"
		verify_version_dir "${version}"
	done

	rm -rf "${work_dir}"
	log "bundle unpacked"
}

phase_switch() {
	resolve_version
	verify_version_dir "${RESOLVED_VERSION}"

	ln -sfn "${PKG_ROOT}/${RESOLVED_VERSION}/fdbserver.${ARCH}" "${FDB_ROOT}/fdbserver"
	ln -sfn "${PKG_ROOT}/${RESOLVED_VERSION}/fdbbackup.${ARCH}" "${FDB_ROOT}/backup_agent"

	log "switched fdbserver and backup_agent symlinks to ${RESOLVED_VERSION}"
}

phase_switch_cli() {
	resolve_version
	verify_version_dir "${RESOLVED_VERSION}"

	ln -sfn "${PKG_ROOT}/${RESOLVED_VERSION}/fdbcli.${ARCH}" "${FDB_ROOT}/fdbcli"

	log "switched fdbcli symlink to ${RESOLVED_VERSION}"
}

phase_wait_server() {
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	local target
	target=$(target_server_exe)

	while ((SECONDS < deadline)); do
		local current
		current=$(current_server_exe || true)
		if [[ -n ${current} && ${current} == "${target}" ]]; then
			log "running fdbserver matches target ${target}"
			return 0
		fi
		sleep 2
	done

	local current
	current=$(current_server_exe || true)
	die "running fdbserver did not switch to ${target}; current=${current:-<none>}"
}

phase_verify_host() {
	resolve_version
	local running_server
	running_server=$(current_server_exe || true)
	log "resolved version: ${RESOLVED_VERSION}"
	log "fdbserver symlink target: $(readlink -f "${FDB_ROOT}/fdbserver")"
	log "running fdbserver exe: ${running_server:-<none>}"
	log "fdbcli symlink target: $(readlink -f "${FDB_ROOT}/fdbcli")"
	"${FDB_ROOT}/fdbserver" --version
	"${FDB_ROOT}/fdbcli" --version
}

case "${phase}" in
	unpack) phase_unpack ;;
	switch) phase_switch ;;
	switch-cli) phase_switch_cli ;;
	wait-server) phase_wait_server ;;
	verify-host) phase_verify_host ;;
	*) die "unknown phase: ${phase}" ;;
esac
EOF_REMOTE
)

run_remote_phase_parallel() {
	local phase=$1
	local failures=0
	local -a pids=()
	local -a hosts_for_pid=()

	for host in "${HOSTS[@]}"; do
		(
			ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
				env \
				FDB_ROOT="${FDB_ROOT}" \
				PKG_ROOT="${PKG_ROOT}" \
				BUNDLE_BASENAME="${bundle_basename}" \
				PRIMARY_VERSION="${PRIMARY_VERSION}" \
				ARCH="${ARCH}" \
				WAIT_TIMEOUT="${VERIFY_TIMEOUT}" \
				bash -s -- "${phase}" <<< "${REMOTE_SCRIPT}"
		) \
			> >(sed "s/^/[${host}] /") \
			2> >(sed "s/^/[${host}] /" >&2) &

		pids+=($!)
		hosts_for_pid+=("${host}")
	done

	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}"; then
			log "phase ${phase} failed on ${hosts_for_pid[$i]}"
			failures=$((failures + 1))
		fi
	done

	((failures == 0)) || die "phase ${phase} failed on ${failures} host(s)"
}

distribute_bundle() {
	local failures=0
	local -a pids=()
	local -a hosts_for_pid=()

	for host in "${HOSTS[@]}"; do
		(
			ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "mkdir -p '${PKG_ROOT}/.bundle-incoming'"
			scp -P "${SSH_PORT}" "${BUNDLE}" "${SSH_USER}@${host}:${PKG_ROOT}/.bundle-incoming/${bundle_basename}"
		) \
			> >(sed "s/^/[${host}] /") \
			2> >(sed "s/^/[${host}] /" >&2) &

		pids+=($!)
		hosts_for_pid+=("${host}")
	done

	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}"; then
			log "bundle distribute failed on ${hosts_for_pid[$i]}"
			failures=$((failures + 1))
		fi
	done

	((failures == 0)) || die "bundle distribute failed on ${failures} host(s)"
}

cluster_kill_all() {
	local host=${HOSTS[0]}
	local current_cli
	current_cli=$(
		ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
			env ARCH="${ARCH}" \
			bash -s <<'EOF_DISCOVER'
set -euo pipefail
pid=$(pgrep -xo fdbserver || true)
[[ -n ${pid} ]] || { echo "no running fdbserver found" >&2; exit 1; }
server_exe=$(readlink -f "/proc/${pid}/exe")
cli_exe="$(dirname "${server_exe}")/fdbcli.${ARCH}"
[[ -x ${cli_exe} ]] || { echo "matching fdbcli not found: ${cli_exe}" >&2; exit 1; }
printf '%s\n' "${cli_exe}"
EOF_DISCOVER
	)

	log "issuing cluster-wide 'kill; kill all' from ${host} using ${current_cli}"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
		env CURRENT_FDBCLI="${current_cli}" CLUSTER_FILE="${CLUSTER_FILE}" \
		bash -s <<'EOF_KILL'
set -euo pipefail
"${CURRENT_FDBCLI}" -C "${CLUSTER_FILE}" --exec "kill; kill all"
EOF_KILL
}

verify_cluster() {
	local host=${HOSTS[0]}
	local deadline=$((SECONDS + VERIFY_TIMEOUT))
	local target_cli="${PKG_ROOT}/${PRIMARY_VERSION}/fdbcli.${ARCH}"

	log "verifying cluster health from ${host} using ${target_cli}"
	while ((SECONDS < deadline)); do
		if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
			env TARGET_FDBCLI="${target_cli}" CLUSTER_FILE="${CLUSTER_FILE}" \
			bash -s <<'EOF_VERIFY'
set -euo pipefail
"${TARGET_FDBCLI}" -C "${CLUSTER_FILE}" --exec "status minimal"
EOF_VERIFY
		then
			return 0
		fi
		sleep 5
	done

	return 1
}

cat <<EOF
Upgrade plan
  Hosts             : ${HOSTS[*]}
  Bundle            : ${BUNDLE}
  Primary version   : ${PRIMARY_VERSION}
  Arch              : ${ARCH}
  Mode              : ${MODE}
  SSH user          : ${SSH_USER}
  SSH port          : ${SSH_PORT}
  FDB root          : ${FDB_ROOT}
  Package root      : ${PKG_ROOT}
  Cluster file      : ${CLUSTER_FILE}
  Verify timeout    : ${VERIFY_TIMEOUT}s
  Cluster verify    : ${VERIFY_CLUSTER}

Prepare actions
  1. Copy bundle to every host
  2. Unpack under package root

Activate actions
  1. Switch fdbserver and backup_agent symlinks to the staged version
  2. Use the currently running version's fdbcli to run "kill; kill all" against the old cluster
  3. Wait until every host is running the target fdbserver version
  4. Switch fdbcli symlink to the staged version
  5. Verify versions and cluster health
EOF

if [[ ${CONFIRM} != '1' ]]; then
	echo
	echo "Dry run only. Re-run with --yes to execute."
	exit 0
fi

if [[ ${MODE} == 'full' || ${MODE} == 'prepare' ]]; then
	distribute_bundle
	run_remote_phase_parallel unpack
fi

if [[ ${MODE} == 'full' || ${MODE} == 'activate' ]]; then
	run_remote_phase_parallel switch
	cluster_kill_all
	run_remote_phase_parallel wait-server
	run_remote_phase_parallel switch-cli
	run_remote_phase_parallel verify-host

	if [[ ${VERIFY_CLUSTER} == '1' ]]; then
		verify_cluster || die "cluster verification did not succeed within ${VERIFY_TIMEOUT}s"
		log "cluster verification succeeded"
	else
		log "cluster verification skipped"
	fi
fi

log "operation completed"
