#!/bin/bash


# helper functions
errcho() { echo $@ 1>&2; }

usage() {
  cat 1>&2 << EOF
Usage: [CONFIG=backup.cfg] $(basename "$0") [<ACTION>]

ACTION:
  The default action is "backup", which will run the backup right away.

  The "backup-job" action is meant to be used from inside a crontab and
  will run a backup not more often than configured in JOB_INTERVAL in
  your configuration file.

  The "gen-crontab" action will print a line suitable to be added to a
  file in /etc/cron.d and exit. Use like so:

    CONFIG=/etc/borgwrapper.d "$0" > /etc/cron.d/borgwrapper

  The generated entry may also be added to a user-specific crontab
  file, in which case you simply need to remove the username field.

CONFIGURATION FILE:
  Pass the configuration file in the CONFIG variable.
  If you specify a directory for CONFIG, each file inside that directory
  and any of it's subdirectories ending in .cfg will be processed in
  sequence. The default config file is "backup.cfg" in the current
  working directory.
EOF
  exit 1
}


# check for existence of config file
if [ -z "$CONFIG" ]; then
  CONFIG=backup.cfg
fi
CONFIG="$(realpath "$CONFIG")"
if [ ! -e "$CONFIG" ]; then
  errcho "ERROR: config file $CONFIG doesn't exist"
  usage
fi


# handle gen-crontab action without reading config file to prevent
# walking into directories
action="$1"
if [ "$action" == "gen-crontab" ]; then
  script="$(realpath "$0")"
  echo "*/15 * * * *    $USER    [ -x \"$script\" ] && CONFIG=\"$CONFIG\" \"$script\" backup-job > /dev/null"
  exit 0
fi


# handle config directories
if [ -d "$CONFIG" ]; then
  while read cfgfile; do
    [ -z "$cfgfile" ] && continue
    CONFIG="$cfgfile" exec "$0" "$@"
  done <<< `find "$CONFIG" -type f -name \*.cfg`
  exit
fi


# switch to config file's location and read the file
#cd "$(dirname "$CONFIG")"
. "$CONFIG"


# parse action
case "$action" in
  "backup" | "")
    ;;
  "backup-job")
    if [ -z "$JOB_INTERVAL" ]; then
      errcho "ERROR: JOB_INTERVAL not configured."
      exit 1
    fi
    now="$(date +%s)"
    tsfile="$CONFIG.last_job"
    if [ -e "$tsfile" ]; then
      modinterval=$(("$now" - "$(cat "$tsfile")"))
      if [ "$modinterval" -lt "$JOB_INTERVAL" ]; then
        echo "No backup needed, JOB_INTERVAL hasn't passed since last run."
        exit 0
      fi
    fi
    ;;
  *)
    usage
    ;;
esac


# rewrite some config variables

# ensure snapshot name has only one path component
BTRFS_SNAPNAME="$(basename "$BTRFS_SNAPNAME")"

# build paths for later use
exclude_file="$CONFIG.exclude"
passphrase_file="$CONFIG.passphrase"

# Try to generate an unique hash from the location of the config file
# to build paths for temporary files.
hash md5sum && read cfgsum <<< "$(md5sum <<< "$CONFIG" | cut -c-16)"
if [ -n "$cfgsum" ]; then
  pidfile="$(realpath "/tmp/borgwrapper.$cfgsum.pid")"
  mountdir="$(realpath "/tmp/borgwrapper.$cfgsum.mnt")"
else
  pidfile="$CONFIG.pid"
  mountdir="$CONFIG.mnt"
fi

if [ -e "$passphrase_file" ] && [ "$(stat -c %a "$passphrase_file")" -gt 660 ]; then
  errcho "WARNING: $passphrase_file is world-readable, doing chmod 660."
  chmod 660 "$passphrase_file"
fi

if [ -e "$exclude_file" ]; then
  BORG_CREATE_OPTS="$BORG_CREATE_OPTS --exclude-from ${exclude_file}"
fi


# create lock for this config
hash flock
if [ "$?" -ne 0 ]; then
  errcho "ERROR: borgwrapper requires the flock(1) command."
  exit 1
fi
exec {fd}>>"$pidfile"
flock -n "$fd"
if [ "$?" != "0" ]; then
  if [ "$action" == "backup-job" ]; then
    echo "$pidfile is still locked, not running backup job."
    if [ -n "$modinterval" ] && [ "$modinterval" -ge "$JOB_INTERVAL" ]; then
      errcho "WARNING: Last successful job ran more than $JOB_INTERVAL seconds before."
      exit 1
    fi
    exit 0
  else
    errcho "ERROR: $pidfile is still locked, is there another job running?"
    exit 1
  fi
fi
pid=$$
echo $pid >"$pidfile"


# create and mount snapshots of btrfs subvolumes
mkdir -p "$mountdir"
chmod 700 "$mountdir"
cd "$mountdir"

snaplocs=()
mountnames=()
for src in "${BTRFS_SOURCES[@]}"; do
  snaploc="$src/$BTRFS_SNAPNAME"

  mountname="$(basename "$src")"
  if [ "$mountname" == "/" ]; then
    mountname=root
  fi

  if [ -d "$snaploc" ]; then
    btrfs subvolume delete "$snaploc"
  fi

  btrfs subvolume snapshot -r "$src" "$snaploc" && \
  snaplocs+=("$snaploc") && \
  mkdir -p "$mountname" && \
  mount --bind "$snaploc" "$mountname" && \
  mountnames+=("$mountname")
done


# create backup
paths=()
paths+=("${SOURCES[@]}")
paths+=("${mountnames[@]}")

if [ ${#paths[@]} -gt 0 ]; then
  archname="$(date +%Y-%m-%d_%H:%M:%S)"

  export BORG_REPO
  export BORG_PASSPHRASE="$(cat "$passphrase_file" /dev/null)"
  borg create $BORG_CREATE_OPTS "::$archname" "${paths[@]}"
  rc=$?
  unset BORG_PASSPHRASE
fi


# umount and delete btrfs snapshots
for mountname in "${mountnames[@]}"; do
  umount -f "$mountname" && [ "$(ls -A "$mountname")" ] || rm -rf "$mountname"
done
cd ..
[ "$(ls -A "$mountdir")" ] || rm -rf "$mountdir"

[ ${#snaplocs[@]} -gt 0 ] && btrfs subvolume delete "${snaplocs[@]}"


if [ "$rc" -ne 0 ]; then
  errcho "ERROR: Backup failed."
else
  # prune old backups
  if [ -n "$BORG_PRUNE_OPTS" ]; then
    export BORG_PASSPHRASE="$(cat "$passphrase_file" /dev/null)"
    borg prune $BORG_PRUNE_OPTS ::
    unset BORG_PASSPHRASE
  fi

  # update timestamp
  [ "$action" == "backup-job" ] && echo "$now" > "$tsfile"
fi


# clean up
rm -f "$pidfile"


exit $rc
