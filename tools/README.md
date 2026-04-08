# FoundationDB Upgrade Bundle Scripts

This directory contains two scripts for upgrading a FoundationDB cluster using a prebuilt bundle instead of downloading from GitHub on every database host.

## Files

- [build_fdb_upgrade_bundle.sh](/data/data9/baohan/projects/foundationdb/tools/build_fdb_upgrade_bundle.sh)
  Builds a release bundle on a machine with good internet access.
- [apply_fdb_upgrade_bundle.sh](/data/data9/baohan/projects/foundationdb/tools/apply_fdb_upgrade_bundle.sh)
  Distributes a prebuilt bundle to cluster hosts and activates the upgrade.

## What The Bundle Contains

The bundle currently includes only:

- `fdbserver.<arch>`
- `fdbcli.<arch>`
- `fdbbackup.<arch>`

It does not include `fdbmonitor`.

This workflow assumes:

- `fdbmonitor` is already installed and running on every host
- the existing `fdbmonitor` is compatible with the target `fdbserver`
- `foundationdb.conf` uses the symlink path in `command = ...`, for example:

```ini
[fdbserver]
command = /mnt/hdd01/foundationdb/fdbserver

[backup_agent]
command = /mnt/hdd01/foundationdb/backup_agent
```

If `command=` points to a version-pinned binary path instead of the symlink path, switching the symlink will not upgrade the running process.

## Script 1: Build The Bundle

Use `build_fdb_upgrade_bundle.sh` on a machine that can access GitHub Releases.

### Purpose

- Download release binaries from GitHub
- Save them under a local work directory
- Pack them into a single `tar.gz`

### Parameters

- `--version VERSION`
  Required. The target FoundationDB version, for example `7.3.69`.
- `--arch ARCH`
  Optional. `x86_64` or `aarch64`. Default: `x86_64`.
- `--curl-bin PATH`
  Optional. Curl binary to use. Use this if the default `curl` in your environment is broken.
- `--release-base URL`
  Optional. GitHub release base URL.
- `--work-dir PATH`
  Optional. Temporary working directory.
- `--output PATH`
  Optional. Output bundle path.

### Example

```bash
cd /data/data9/baohan/projects/foundationdb

tools/build_fdb_upgrade_bundle.sh \
  --version 7.3.69 \
  --curl-bin /usr/bin/curl \
  --output /tmp/fdb-upgrade-bundle-7.3.69.tar.gz
```

### Result

This produces:

- `/tmp/fdb-upgrade-bundle-7.3.69.tar.gz`
- `/tmp/fdb-upgrade-bundle-7.3.69.tar.gz.sha256`

## Script 2: Apply The Bundle

Use `apply_fdb_upgrade_bundle.sh` on an operator machine that can SSH to all cluster hosts.

### Purpose

- Copy the bundle to all hosts
- Unpack it under the package directory
- Switch symlinks for `fdbserver` and `backup_agent`
- Use the currently running version's `fdbcli` to issue `kill; kill all`
- Wait until all hosts are actually running the target `fdbserver`
- Switch the `fdbcli` symlink only after the server version change is confirmed

### Why `fdbcli` Is Switched Last

Minor FoundationDB versions are not guaranteed to be protocol-compatible.

If the cluster is still running the old `fdbserver` version and you switch `fdbcli` first, you may lose the ability to connect to the cluster with the symlinked CLI.

To avoid that, the script:

- discovers the version of the currently running `fdbserver`
- uses the matching `fdbcli` binary from that same version directory for `kill; kill all`
- waits until the target `fdbserver` is actually running
- only then switches the `fdbcli` symlink

### Parameters

- `--bundle PATH`
  Required. Path to the local bundle tarball.
- `--hosts HOST1,HOST2,...`
  Host list as a comma-separated string.
- `--hosts-file FILE`
  Alternative to `--hosts`. One host per line.
- `--ssh-user USER`
  SSH user. Default: current user.
- `--ssh-port PORT`
  SSH port. Default: `22`.
- `--fdb-root PATH`
  Root directory containing symlinks such as `fdbserver`, `fdbcli`, `backup_agent`.
- `--pkg-root PATH`
  Package root containing versioned directories, for example `/mnt/hdd01/tools/fdb/pkgs`.
- `--cluster-file PATH`
  Cluster file path.
- `--verify-timeout SEC`
  Timeout for waiting for the target `fdbserver` to come up and for final cluster verification.
- `--skip-cluster-verify`
  Skip the final `status minimal` check.
- `--prepare-only`
  Only distribute and unpack the bundle.
- `--activate-only`
  Only activate an already staged bundle.
- `--yes`
  Actually execute. Without this flag, the script prints the plan and exits.

## Recommended Workflow

### Step 1: Build The Bundle

```bash
tools/build_fdb_upgrade_bundle.sh \
  --version 7.3.69 \
  --curl-bin /usr/bin/curl \
  --output /tmp/fdb-upgrade-bundle-7.3.69.tar.gz
```

### Step 2: Stage The Bundle On All Hosts

This copies and unpacks the bundle, but does not restart anything.

```bash
tools/apply_fdb_upgrade_bundle.sh \
  --bundle /tmp/fdb-upgrade-bundle-7.3.69.tar.gz \
  --hosts 172.20.56.149,172.20.56.150,172.20.56.151,172.20.56.153,172.20.56.157 \
  --ssh-user root \
  --fdb-root /mnt/hdd01/foundationdb \
  --pkg-root /mnt/hdd01/tools/fdb/pkgs \
  --cluster-file /mnt/hdd01/foundationdb/conf/fdb.cluster \
  --prepare-only \
  --yes
```

### Step 3: Activate The Upgrade

This changes symlinks and restarts the cluster using `kill; kill all`.

```bash
tools/apply_fdb_upgrade_bundle.sh \
  --bundle /tmp/fdb-upgrade-bundle-7.3.69.tar.gz \
  --hosts 172.20.56.149,172.20.56.150,172.20.56.151,172.20.56.153,172.20.56.157 \
  --ssh-user root \
  --fdb-root /mnt/hdd01/foundationdb \
  --pkg-root /mnt/hdd01/tools/fdb/pkgs \
  --cluster-file /mnt/hdd01/foundationdb/conf/fdb.cluster \
  --activate-only \
  --yes
```

## What `--activate-only` Actually Does

1. Switch `fdbserver` and `backup_agent` symlinks to the target version.
2. On the first host, inspect the currently running `fdbserver` process.
3. Build the matching `fdbcli` path from the running server version directory.
4. Run:

```bash
fdbcli --exec "kill; kill all"
```

5. Wait until every host's running `fdbserver` executable matches the target version.
6. Switch the `fdbcli` symlink to the target version.
7. Run final verification.

## Verification Tips

### Check What The Symlink Points To

```bash
readlink -f /mnt/hdd01/foundationdb/fdbserver
readlink -f /mnt/hdd01/foundationdb/fdbcli
```

### Check What Is Actually Running

```bash
pgrep -af fdbserver
readlink -f /proc/$(pgrep -xo fdbserver)/exe
```

The `/proc/<pid>/exe` path is authoritative for the running binary version.

### Check Cluster Status

```bash
/mnt/hdd01/tools/fdb/pkgs/7.3.69/fdbcli.x86_64 \
  -C /mnt/hdd01/foundationdb/conf/fdb.cluster \
  --exec "status details"
```

## Common Failure Modes

### 1. Symlink Changed But Running Process Stayed Old

Cause:

- `kill; kill all` did not complete
- or `fdbmonitor` restarted the old binary because `command=` in config does not point to the symlink path

Check:

```bash
readlink -f /proc/$(pgrep -xo fdbserver)/exe
```

### 2. New `fdbcli` Cannot Connect

Cause:

- cluster is still on the old server version
- but the `fdbcli` symlink has already been switched to the new version

Recovery:

- use the old version's `fdbcli` by absolute path
- finish the restart

Example:

```bash
/mnt/hdd01/tools/fdb/pkgs/7.1.38/fdbcli.x86_64 \
  -C /mnt/hdd01/foundationdb/conf/fdb.cluster \
  --exec "kill; kill all"
```

### 3. `kill all` Fails With "You must run the kill command before running kill all"

Cause:

- this is how `fdbcli` works

The script already handles this by running:

```bash
kill; kill all
```

## Notes

- `apply_fdb_upgrade_bundle.sh --activate-only` still requires `--bundle`, but only to read the bundle manifest on the local machine. It does not need the bundle path to exist on remote hosts.
- The script does not restart or upgrade `fdbmonitor`.
- The script does not include `libfdb_c.so`. If you also want to upgrade client libraries for applications, extend the bundle separately.
