#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 AOSP_ROOT OUT_ROOT GENERATION" >&2
  exit 2
fi

AOSP_ROOT="$1"
OUT_ROOT="$2"
GEN="$3"
PUBLIC_OUT_RESERVE_GB="${PUBLIC_OUT_RESERVE_GB:-48}"

# Public build fabric only. This script MUST NOT consume private GIO source,
# signing material, repository credentials, or any private payload.
# Never modify, mask, stop, restart, or otherwise interfere with the
# GitHub-hosted runner control/compute agent. Build preparation must remain
# entirely inside the ordinary job environment.
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup \
  /opt/hostedtoolcache/CodeQL /opt/hostedtoolcache/go /opt/hostedtoolcache/Python || true
sudo docker image prune -af >/dev/null 2>&1 || true
sudo rm -rf /var/lib/apt/lists/* || true

POLICY_RC_CREATED=0
if [ ! -e /usr/sbin/policy-rc.d ]; then
  printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null
  sudo chmod 0755 /usr/sbin/policy-rc.d
  POLICY_RC_CREATED=1
fi

sudo apt-get update -qq
packages=(
  bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs gnupg gperf
  imagemagick jq lib32readline-dev lib32z1-dev libelf-dev liblz4-tool libncurses-dev
  libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop openjdk-17-jdk
  pngcrush rsync schedtool squashfs-tools xsltproc zip unzip zlib1g-dev python3 python-is-python3
)
# nbd-client/nbdkit/dmsetup are only required for remote/on-demand packs.
# Installing nbd-client on GitHub's hosted Ubuntu image triggers update-initramfs;
# the localized path must not touch that stack because it can destabilize the
# hosted compute agent several minutes later while Soong is running.
if [ "${LOCALIZE_PUBLIC_PACKS:-1}" != "1" ]; then
  packages+=(dmsetup nbd-client nbdkit)
fi
missing=()
for pkg in "${packages[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get install -y -qq --no-install-recommends --no-upgrade "${missing[@]}"
fi

if [ "$POLICY_RC_CREATED" -eq 1 ]; then
  sudo rm -f /usr/sbin/policy-rc.d
fi

echo "HOSTED_COMPUTE_AGENT_UNTOUCHED=PASS"

if [ "${LOCALIZE_PUBLIC_PACKS:-1}" != "1" ]; then
  sudo modprobe nbd nbds_max=128 max_part=0
  sudo modprobe dm_mod
fi
sudo mkdir -p /mnt/gio-meta /mnt/gio-lower /mnt/gio-upper /mnt/gio-work /mnt/gio-local-packs "$AOSP_ROOT" "$OUT_ROOT"
sudo chown -R "$USER:$USER" /mnt/gio-meta /mnt/gio-lower /mnt/gio-upper /mnt/gio-work /mnt/gio-local-packs "$AOSP_ROOT" "$OUT_ROOT"

repos=(
  giovannifidel-collab/razzo-shard-0151
  giovannifidel-collab/razzo-shard-0021
  giovannifidel-collab/razzo-shard-0143
  giovannifidel-collab/razzo-shard-0063
  giovannifidel-collab/razzo-shard-0128
  giovannifidel-collab/razzo-shard-0212
  giovannifidel-collab/razzo-shard-0185
  giovannifidel-collab/razzo-shard-0209
  giovannifidel-collab/razzo-shard-0191
  giovannifidel-collab/razzo-shard-0215
  giovannifidel-collab/razzo-shard-0010
  giovannifidel-collab/razzo-shard-0198
  giovannifidel-collab/razzo-shard-0238
  giovannifidel-collab/razzo-shard-0208
  giovannifidel-collab/razzo-shard-0166
  giovannifidel-collab/razzo-shard-0290
)

# Release assets are read through the API endpoint with the ephemeral public
# workflow token. This avoids anonymous browser_download_url throttling/403s.
api_headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: gio-os-public-fabric')
asset_headers=(-H 'Accept: application/octet-stream' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: gio-os-public-fabric')
if [ -n "${GITHUB_TOKEN:-}" ]; then
  api_headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
  asset_headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
fi

download_asset() {
  local api_url="$1" out="$2" expected_digest="${3:-}"
  local tmp="${out}.part"
  rm -f "$tmp"
  curl -fL --retry 8 --retry-all-errors --connect-timeout 20 \
    "${asset_headers[@]}" "$api_url" -o "$tmp"
  if [ -n "$expected_digest" ] && [ "$expected_digest" != "null" ]; then
    local actual
    actual="$(sha256sum "$tmp" | awk '{print $1}')"
    test "$expected_digest" = "sha256:$actual" || {
      echo "ASSET_SHA_MISMATCH $(basename "$out")" >&2
      rm -f "$tmp"
      return 1
    }
  fi
  mv "$tmp" "$out"
}

nbd=0
lowers=()
localized=0
remote=0
reserve_bytes=$((PUBLIC_OUT_RESERVE_GB * 1024 * 1024 * 1024))

for i in $(seq 0 15); do
  id=$(printf '%02d' "$i")
  repo="${repos[$i]}"
  tag="gio-a14-lavender-srcpack-${GEN}-pack${id}"
  api="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  json="$(curl -fsSL --retry 8 --retry-all-errors --connect-timeout 20 "${api_headers[@]}" "$api")"
  meta="/mnt/gio-meta/${id}"
  mkdir -p "$meta"

  for asset in "pack-${i}-projects.json" "gio-a14-source-pack-${i}.chunks.sha256" "gio-a14-source-pack-${i}.sqfs.sha256"; do
    asset_api="$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .url' <<<"$json")"
    digest="$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | (.digest // "")' <<<"$json")"
    test -n "$asset_api" -a "$asset_api" != null
    download_asset "$asset_api" "$meta/$asset" "$digest"
  done

  pack_bytes=0
  while read -r expected recorded; do
    name="${recorded##*/}"
    size="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .size' <<<"$json")"
    test "$size" -gt 0
    pack_bytes=$((pack_bytes + size))
  done < "$meta/gio-a14-source-pack-${i}.chunks.sha256"

  avail_bytes="$(df --output=avail -B1 /mnt | tail -n1 | tr -d ' ')"
  localize=0
  if [ "${LOCALIZE_PUBLIC_PACKS:-1}" = "1" ] && [ $((avail_bytes - pack_bytes)) -ge "$reserve_bytes" ]; then
    localize=1
  fi

  mp="/mnt/gio-lower/${id}"
  mkdir -p "$mp"

  if [ "$localize" -eq 1 ]; then
    packfile="/mnt/gio-local-packs/gio-a14-source-pack-${i}.sqfs"
    : > "$packfile"
    chunk_index=0
    while read -r expected recorded; do
      name="${recorded##*/}"
      digest="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | (.digest // "")' <<<"$json")"
      test "$digest" = "sha256:$expected" || { echo "DIGEST_MISMATCH $repo $name" >&2; exit 1; }
      asset_api="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .url' <<<"$json")"
      size="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .size' <<<"$json")"
      test "$size" -gt 0
      chunk="/mnt/gio-local-packs/.pack-${id}-chunk-${chunk_index}"
      download_asset "$asset_api" "$chunk" "$digest"
      actual="$(sha256sum "$chunk" | awk '{print $1}')"
      test "$actual" = "$expected" || { echo "LOCAL_CHUNK_SHA_MISMATCH $repo $name" >&2; exit 1; }
      cat "$chunk" >> "$packfile"
      rm -f "$chunk"
      chunk_index=$((chunk_index + 1))
    done < "$meta/gio-a14-source-pack-${i}.chunks.sha256"
    expected_sqfs="$(awk 'NR==1 {print $1}' "$meta/gio-a14-source-pack-${i}.sqfs.sha256")"
    actual_sqfs="$(sha256sum "$packfile" | awk '{print $1}')"
    test "$actual_sqfs" = "$expected_sqfs" || { echo "LOCAL_SQFS_SHA_MISMATCH pack${id}" >&2; exit 1; }
    sudo mount -t squashfs -o loop,ro "$packfile" "$mp"
    localized=$((localized + 1))
    echo "LOCAL_PACK_${id}=MOUNTED bytes=${pack_bytes}"
  else
    devs=()
    starts=0
    table="$meta/dm.table"
    : > "$table"
    while read -r expected recorded; do
      name="${recorded##*/}"
      test -n "$name"
      digest="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | (.digest // "")' <<<"$json")"
      test "$digest" = "sha256:$expected" || { echo "DIGEST_MISMATCH $repo $name" >&2; exit 1; }
      asset_api="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .url' <<<"$json")"
      size="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .size' <<<"$json")"
      test "$size" -gt 0
      test $((size % 512)) -eq 0 || { echo "UNALIGNED_CHUNK $name $size" >&2; exit 1; }

      sock="/tmp/gio-public-nbd-${nbd}.sock"
      log="/tmp/gio-public-nbd-${nbd}.log"
      rm -f "$sock" "$log"
      nbd_args=(-r -U "$sock" --filter=retry curl url="$asset_api" retries=8 connections=1 \
        header='Accept: application/octet-stream' \
        header='X-GitHub-Api-Version: 2022-11-28' \
        header='User-Agent: gio-os-public-fabric')
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        nbd_args+=( header="Authorization: Bearer ${GITHUB_TOKEN}" )
      fi
      nice -n 12 nbdkit "${nbd_args[@]}" >"$log" 2>&1 &
      for waitn in $(seq 1 30); do test -S "$sock" && break; sleep 1; done
      test -S "$sock" || { cat "$log"; exit 1; }
      sudo nbd-client -unix "$sock" "/dev/nbd${nbd}" >/dev/null
      actual_size="$(sudo blockdev --getsize64 "/dev/nbd${nbd}")"
      test "$actual_size" = "$size" || { echo "NBD_SIZE_MISMATCH $name $actual_size $size" >&2; cat "$log"; exit 1; }
      sectors=$((size / 512))
      printf '%s %s linear /dev/nbd%s 0\n' "$starts" "$sectors" "$nbd" >> "$table"
      starts=$((starts + sectors))
      devs+=("/dev/nbd${nbd}")
      nbd=$((nbd + 1))
    done < "$meta/gio-a14-source-pack-${i}.chunks.sha256"

    test "${#devs[@]}" -gt 0
    if test "${#devs[@]}" -eq 1; then
      packdev="${devs[0]}"
    else
      sudo dmsetup create "gio-public-pack-${id}" < "$table"
      packdev="/dev/mapper/gio-public-pack-${id}"
    fi
    sudo mount -t squashfs -o ro "$packdev" "$mp"
    remote=$((remote + 1))
    echo "REMOTE_PACK_${id}=MOUNTED bytes=${pack_bytes}"
  fi
  lowers=("$mp" "${lowers[@]}")
done

echo "SOURCE_PACK_LOCALIZED=${localized}"
echo "SOURCE_PACK_REMOTE=${remote}"

python3 - <<'PY'
import hashlib, json, pathlib
base=pathlib.Path('/mnt/gio-meta'); seen={}
for i in range(16):
    obj=json.loads((base/f'{i:02d}'/f'pack-{i}-projects.json').read_text())
    assert obj['schema']=='gio.os.public-source-pack.v1'
    assert obj['pack_id']==i and obj['pack_count']==16
    assert obj['public_inputs_only'] is True
    assert obj['private_gio_source_present'] is False
    assert obj['signing_keys_present'] is False
    for row in obj['projects']:
        path=row['path']; sha=row['sha']
        bucket=int.from_bytes(hashlib.sha256(path.encode()).digest()[:8],'big') % 16
        assert bucket==i,(path,i,bucket)
        assert path not in seen,path
        seen[path]=sha
pins={
  'device/xiaomi/lavender':'fd2a90e734a101fad046736970fa4dfb492d7d78',
  'kernel/xiaomi/lavender':'b7b27af5994f7afc11f69cfef194a8dc738842b4',
  'vendor/xiaomi/lavender':'483e3e7ca5828c54d8b4408b87ee14069a8d027b',
}
for path,sha in pins.items(): assert seen.get(path)==sha,(path,seen.get(path),sha)
assert len(seen)>1000,len(seen)
print('SOURCE_PACK_PROJECTS='+str(len(seen)))
print('SOURCE_PACK_PARTITION=PASS')
print('LAVENDER_PINS=PASS')
PY

lowerdir=$(IFS=:; echo "${lowers[*]}")
sudo mount -t overlay overlay -o "lowerdir=${lowerdir},upperdir=/mnt/gio-upper,workdir=/mnt/gio-work" "$AOSP_ROOT"
test -f "$AOSP_ROOT/build/envsetup.sh"
test -f "$AOSP_ROOT/device/xiaomi/lavender/lineage_lavender.mk"
test -d "$AOSP_ROOT/frameworks/base"
test ! -e "$AOSP_ROOT/vendor/gioos"

rm -rf "$AOSP_ROOT/out"
ln -s "$OUT_ROOT" "$AOSP_ROOT/out"

echo "PUBLIC_SOURCE_SETUP=PASS"
df -hT / /mnt
free -h
