#! /bin/bash -x

shutdown_on_exit() {
	echo "[!] Script exited. Shutting down in two minutes."
	shutdown +2
}

trap shutdown_on_exit EXIT
set -e
set -o pipefail

# amazon-linux-extras install -y epel
yum install -y wget p7zip pv

# Discover the root device and exclude it from data disks
echo "[*] Disk layout:"
lsblk -o NAME,TYPE,SIZE,MOUNTPOINT

ROOT_PART=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null || true)

if [[ -z "$ROOT_DISK" ]]; then
  echo "[!] Could not determine root disk; aborting to avoid formatting the wrong device."
  lsblk -o NAME,TYPE,MOUNTPOINT
  exit 1
fi

# Find NVMe "disk" devices that are NOT the root disk
mapfile -t DATA_DISKS < <(
  lsblk -ndo NAME,TYPE | awk -v root="$ROOT_DISK" '
    $2=="disk" && $1 ~ /^nvme/ && $1 != root { print "/dev/"$1 }
  '
)

if [[ ${#DATA_DISKS[@]} -eq 0 ]]; then
  echo "[!] No non-root NVMe data disks found; cannot continue."
  exit 1
fi

RAW_DEV="${DATA_DISKS[0]}"
COMP_DEV="${DATA_DISKS[1]:-}"

echo "[*] Using $RAW_DEV for raw data"
[[ -n "$COMP_DEV" ]] && echo "[*] Using $COMP_DEV for compressed data"

mkfs.ext4 "$RAW_DEV"

if [[ -n "$COMP_DEV" ]]; then
  mkfs.ext4 "$COMP_DEV"

  mkdir -p /npk/raw /npk/compressed
  mount "$RAW_DEV" /npk/raw
  mount "$COMP_DEV" /npk/compressed
else
  mkdir -p /npk
  mount "$RAW_DEV" /npk
  mkdir -p /npk/raw /npk/compressed
fi

export TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
export AWS_DEFAULT_REGION=`wget "--header=X-aws-ec2-metadata-token: $TOKEN" -qO- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//'`
export AWS_DEFAULT_OUTPUT=json

export TARGETFILE={{targetfile}}
export TARGETFILETYPE={{targetfiletype}}
if [[ `echo $TARGETFILE | grep s3: | wc -l` -gt 0 ]]; then
	aws s3 cp $TARGETFILE /npk/raw/rawfile
else
	wget $targetfile -O /npk/raw/rawfile
fi

ls -alh /npk/raw/rawfile
FILENAME=`echo ${TARGETFILE##*/} | cut -d"?" -f1`
EXTENSION="${FILENAME##*.}"
EXTENSION="${EXTENSION,,}"
BASENAME="${FILENAME%.*}"

if [[ "$EXTENSION" == "7z" ]]; then
	echo "[+] 7z input - streaming via 7zz for line count, preserving original archive."
	read FILELINES SIZE < <(7zz x -so /npk/raw/rawfile 2>/dev/null | wc -lc)
	OUTKEY="$TARGETFILETYPE/$FILENAME"
	UPLOAD_SRC=/npk/raw/rawfile
elif [[ "$EXTENSION" == "gz" ]]; then
	echo "[+] gzip input - streaming via gunzip for line count, preserving original archive."
	read FILELINES SIZE < <(gzip -dc /npk/raw/rawfile | wc -lc)
	OUTKEY="$TARGETFILETYPE/$FILENAME"
	UPLOAD_SRC=/npk/raw/rawfile
else
	echo "[+] Text input - counting lines and compressing with gzip."
	read FILELINES SIZE < <(wc -lc < /npk/raw/rawfile)
	echo "[*] Compressing with gzip"
	pv -nte /npk/raw/rawfile | gzip -c > /npk/compressed/$BASENAME.gz
	OUTKEY="$TARGETFILETYPE/$BASENAME.gz"
	UPLOAD_SRC=/npk/compressed/$BASENAME.gz
fi

echo "$FILENAME has $FILELINES lines and $SIZE bytes (uncompressed). Uploading as $OUTKEY."

aws s3 cp "$UPLOAD_SRC" "s3://{{dictionarybucket}}/$OUTKEY" --metadata type=$TARGETFILETYPE,lines=$FILELINES,size=$SIZE

if [[ `echo $TARGETFILE | grep s3: | wc -l` -gt 0 ]]; then
	aws s3 rm $TARGETFILE
fi