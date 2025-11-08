#!/usr/bin/env bash
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

[[ -z "${ARC_PATH}" || ! -d "${ARC_PATH}/include" ]] && ARC_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

. "${ARC_PATH}/include/functions.sh"
. "${ARC_PATH}/include/addons.sh"
. "${ARC_PATH}/include/modules.sh"

set -o pipefail

# Read Model Data
PLATFORM="$(readConfigKey "platform" "${USER_CONFIG_FILE}")"
MODEL="$(readConfigKey "model" "${USER_CONFIG_FILE}")"
LKM="$(readConfigKey "lkm" "${USER_CONFIG_FILE}")"
LAYOUT="$(readConfigKey "layout" "${USER_CONFIG_FILE}")"
KEYMAP="$(readConfigKey "keymap" "${USER_CONFIG_FILE}")"
KERNEL="$(readConfigKey "kernel" "${USER_CONFIG_FILE}")"
RD_COMPRESSED="$(readConfigKey "rd-compressed" "${USER_CONFIG_FILE}")"
PRODUCTVER="$(readConfigKey "productver" "${USER_CONFIG_FILE}")"
BUILDNUM="$(readConfigKey "buildnum" "${USER_CONFIG_FILE}")"
SMALLNUM="$(readConfigKey "smallnum" "${USER_CONFIG_FILE}")"
ODP="$(readConfigKey "odp" "${USER_CONFIG_FILE}")"
DT="$(readConfigKey "dt" "${USER_CONFIG_FILE}")"

KVER="$(readConfigKey "platforms.${PLATFORM}.productvers.\"${PRODUCTVER}\".kver" "${P_FILE}")"
is_in_array "${PLATFORM}" "${KVER5L[@]}" && KVERP="${PRODUCTVER}-${KVER}" || KVERP="${KVER}"

if [ -z "${PLATFORM}" ] || [ -z "${MODEL}" ] || [ -z "${KVER}" ]; then
  echo "ERROR: Configuration for Model ${MODEL} and Version ${PRODUCTVER} not found." >"${LOG_FILE}"
  exit 1
fi

PAT_URL="$(readConfigKey "paturl" "${USER_CONFIG_FILE}")"
PAT_HASH="$(readConfigKey "pathash" "${USER_CONFIG_FILE}")"

[ "${PAT_URL:0:1}" = "#" ] && PAT_URL=""
[ "${PAT_HASH:0:1}" = "#" ] && PAT_HASH=""

# Sanity check
if [ ! -f "${ORI_RDGZ_FILE}" ]; then
  echo "ERROR: ${ORI_RDGZ_FILE} not found!" >"${LOG_FILE}"
  exit 1
fi

rm -rf "${RAMDISK_PATH}" # Force clean
mkdir -p "${RAMDISK_PATH}"
(cd "${RAMDISK_PATH}" && xz -dc <"${ORI_RDGZ_FILE}" | cpio -idm) >/dev/null 2>&1

. "${RAMDISK_PATH}/etc/VERSION"

if [ -n "${PRODUCTVER}" ] && [ -n "${BUILDNUM}" ] && [ -n "${SMALLNUM}" ] &&
  ([ ! "${PRODUCTVER}" = "${majorversion:-0}.${minorversion:-0}" ] || [ ! "${BUILDNUM}" = "${buildnumber:-0}" ] || [ ! "${SMALLNUM}" = "${smallfixnumber:-0}" ]); then
  OLDVER="${PRODUCTVER}(${BUILDNUM}$([[ ${SMALLNUM:-0} -ne 0 ]] && echo "u${SMALLNUM}"))"
  NEWVER="${majorversion}.${minorversion}(${buildnumber}$([[ ${smallfixnumber:-0} -ne 0 ]] && echo "u${smallfixnumber}"))"
  PAT_URL=""
  PAT_HASH=""
  echo -e ">> Version changed from ${OLDVER} to ${NEWVER}"
fi

# Update buildnumber
PRODUCTVER="${majorversion}.${minorversion}"
BUILDNUM="${buildnumber}"
SMALLNUM="${smallfixnumber}"
writeConfigKey "productver" "${PRODUCTVER}" "${USER_CONFIG_FILE}"
writeConfigKey "buildnum" "${BUILDNUM}" "${USER_CONFIG_FILE}"
writeConfigKey "smallnum" "${SMALLNUM}" "${USER_CONFIG_FILE}"

# Patches
PATCHES=(
  "ramdisk-etc-rc-*.patch"
  "ramdisk-init-script-*.patch"
  "ramdisk-post-init-script-*.patch"
)

for PE in "${PATCHES[@]}"; do
  RET=2
  MATCHED=0
  for PF in ${PATCH_PATH}/${PE}; do
    [ ! -e "${PF}" ] && continue
    MATCHED=1
    (cd "${RAMDISK_PATH}" && busybox patch -p1 -i "${PF}") >>"${LOG_FILE}" 2>&1
    RET=$?
    [ ${RET} -eq 0 ] && break
  done
  [ ${RET} -ne 0 ] && exit 1
done

# for DSM 7.3
sed -i 's#/usr/syno/sbin/broadcom_update.sh#/usr/syno/sbin/broadcom_update.sh.arc#g' "${RAMDISK_PATH}/linuxrc.syno.impl"
# LKM
gzip -dc "${LKMS_PATH}/rp-${PLATFORM}-${KVERP}-${LKM}.ko.gz" >"${RAMDISK_PATH}/usr/lib/modules/rp.ko" 2>"${LOG_FILE}" || exit 1
if [ "${KVER:0:1}" -lt 5 ]; then
  # Copying fake modprobe
  cp -f "${PATCH_PATH}/iosched-trampoline.sh" "${RAMDISK_PATH}/usr/sbin/modprobe"
else
  # for issues/313
  sed -i 's#/dev/console#/var/log/lrc#g' "${RAMDISK_PATH}/usr/bin/busybox"
  sed -i '/^echo "START/a \\nmknod -m 0666 /dev/console c 1 3' "${RAMDISK_PATH}/linuxrc.syno"
fi
if [ "${PLATFORM}" = "broadwellntbap" ]; then
  sed -i 's/IsUCOrXA="yes"/XIsUCOrXA="yes"/g; s/IsUCOrXA=yes/XIsUCOrXA=yes/g' "${RAMDISK_PATH}/usr/syno/share/environments.sh"
fi

# Addons
declare -A ADDONS
declare -A MODULES
declare -A SYNOINFO

mkdir -p "${RAMDISK_PATH}/addons"
echo "Create addons.sh" >>"${LOG_FILE}"
{
  echo "#!/bin/sh"
  echo 'echo "addons.sh called with params ${@}"'
  echo "export LOADERLABEL=\"ARC\""
  echo "export LOADERVERSION=\"${ARC_VERSION}\""
  echo "export LOADERBUILD=\"${ARC_BUILD}\""
  echo "export PLATFORM=\"${PLATFORM}\""
  echo "export MODEL=\"${MODEL}\""
  echo "export PRODUCTVERL=\"${PRODUCTVERL}\""
  echo "export MLINK=\"${PAT_URL}\""
  echo "export MCHECKSUM=\"${PAT_HASH}\""
  echo "export LAYOUT=\"${LAYOUT:-qwerty}\""
  echo "export KEYMAP=\"${KEYMAP:-en}\""
} >"${RAMDISK_PATH}/addons/addons.sh"
chmod +x "${RAMDISK_PATH}/addons/addons.sh"

SYSADDONS=("revert" "misc" "eudev" "disks" "localrss" "notify" "mountloader")
[[ "${KVER:0:1}" == "5" ]] && SYSADDONS=("redpill" "${SYSADDONS[@]}")

for ADDON in "${SYSADDONS[@]}"; do
  ADDONS["${ADDON}"]=""
done

while IFS=': ' read -r KEY VALUE; do
  [ -n "${KEY}" ] && ADDONS["${KEY}"]="${VALUE}"
done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")

for ADDON in "${!ADDONS[@]}"; do
  if [ "${ADDON}" = "disks" ]; then
    [ -f "${USER_UP_PATH}/model.dts" ] && cp -f "${USER_UP_PATH}/model.dts" "${RAMDISK_PATH}/addons/model.dts"
    [ -f "${USER_UP_PATH}/${MODEL}.dts" ] && cp -f "${USER_UP_PATH}/${MODEL}.dts" "${RAMDISK_PATH}/addons/model.dts"
  elif [ "${ADDON}" = "notification" ]; then
    WEBHOOKNOTIFY="$(readConfigKey "arc.webhooknotify" "${USER_CONFIG_FILE}")"
    [ "${WEBHOOKNOTIFY}" = "true" ] && WEBHOOK="$(readConfigKey "arc.webhook" "${USER_CONFIG_FILE}")"
    DISCORDNOTIFY="$(readConfigKey "arc.discordnotify" "${USER_CONFIG_FILE}")"
    [ "${DISCORDNOTIFY}" = "true" ] && DISCORDUSERID="$(readConfigKey "arc.userid" "${USER_CONFIG_FILE}")"
    PARAMS="${WEBHOOK:-false} ${DISCORDUSERID:-false}"
  else
    PARAMS="${ADDONS[${ADDON}]}"
  fi

  if installAddon "${ADDON}" "${PLATFORM}" "${KVERP}"; then
    echo "/addons/${ADDON}.sh \${1} ${PARAMS}" >>"${RAMDISK_PATH}/addons/addons.sh" 2>>"${LOG_FILE}" || exit 1
  else
    echo "Addon ${ADDON} not found"
  fi
done

# Modules
while IFS=': ' read -r KEY VALUE; do
  [ -n "${KEY}" ] && MODULES["${KEY}"]="${VALUE}"
done < <(readConfigMap "modules" "${USER_CONFIG_FILE}")

installModules "${PLATFORM}" "${KVERP}" "${!MODULES[@]}" || exit 1

if [ -f "${USER_UP_PATH}/modulelist" ]; then
  cp -f "${USER_UP_PATH}/modulelist" "${RAMDISK_PATH}/addons/modulelist"
else
  cp -f "${ARC_PATH}/include/modulelist" "${RAMDISK_PATH}/addons/modulelist"
fi

# Synoinfo
while IFS=': ' read -r KEY VALUE; do
  [ -n "${KEY}" ] && SYNOINFO["${KEY}"]="${VALUE}"
done < <(readConfigMap "synoinfo" "${USER_CONFIG_FILE}")

echo -n "" >"${RAMDISK_PATH}/addons/synoinfo.conf"
for KEY in "${!SYNOINFO[@]}"; do
  echo "Set synoinfo ${KEY}" >>"${LOG_FILE}"
  echo "${KEY}=\"${SYNOINFO[${KEY}]}\"" >>"${RAMDISK_PATH}/addons/synoinfo.conf"
  _set_conf_kv "${RAMDISK_PATH}/etc/synoinfo.conf" "${KEY}" "${SYNOINFO[${KEY}]}" || exit 1
  _set_conf_kv "${RAMDISK_PATH}/etc.defaults/synoinfo.conf" "${KEY}" "${SYNOINFO[${KEY}]}" || exit 1
done
if [ ! -x "${RAMDISK_PATH}/usr/bin/get_key_value" ]; then
  printf '#!/bin/sh\n%s\n_get_conf_kv "$@"' "$(declare -f _get_conf_kv)" >"${RAMDISK_PATH}/usr/bin/get_key_value"
  chmod +x "${RAMDISK_PATH}/usr/bin/get_key_value"
fi
if [ ! -x "${RAMDISK_PATH}/usr/bin/set_key_value" ]; then
  printf '#!/bin/sh\n%s\n_set_conf_kv "$@"' "$(declare -f _set_conf_kv)" >"${RAMDISK_PATH}/usr/bin/set_key_value"
  chmod +x "${RAMDISK_PATH}/usr/bin/set_key_value"
fi

# backup current loader configs
mkdir -p "${RAMDISK_PATH}/usr/arc"
{
  echo "LOADERLABEL=\"ARC\""
  echo "LOADERVERSION=\"${ARC_VERSION}\""
  echo "LOADERBUILD=\"${ARC_BUILD}\""
} >"${RAMDISK_PATH}/usr/arc/VERSION"
BACKUP_PATH="${RAMDISK_PATH}/usr/arc/backup"
rm -rf "${BACKUP_PATH}"
if [ -f "${USER_GRUB_CONFIG}" ] && [ -f "${USER_CONFIG_FILE}" ] && [ -f "${ORI_ZIMAGE_FILE}" ] && [ -f "${ORI_RDGZ_FILE}" ]; then
  if [ -d "${PART1_PATH}" ]; then
    mkdir -p "${BACKUP_PATH}/p1"
    cp -rf "${PART1_PATH}/." "${BACKUP_PATH}/p1/"
  fi
  if [ -d "${PART2_PATH}" ]; then
    mkdir -p "${BACKUP_PATH}/p2"
    cp -rf "${PART2_PATH}/." "${BACKUP_PATH}/p2/"
  fi
fi

# Network card configuration file
for N in $(seq 0 7); do
  echo -e "DEVICE=eth${N}\nONBOOT=yes\nBOOTPROTO=dhcp\nIPV6INIT=no\nIPV6_ACCEPT_RA=0" >"${RAMDISK_PATH}/etc/sysconfig/network-scripts/ifcfg-eth${N}"
done

# Reassembly ramdisk
rm -f "${MOD_RDGZ_FILE}"
if [ "${RD_COMPRESSED}" = "true" ]; then
  (cd "${RAMDISK_PATH}" && find . 2>/dev/null | cpio -o -H newc -R root:root | xz -9 --format=lzma >"${MOD_RDGZ_FILE}") >>"${LOG_FILE}" 2>&1 || exit 1
else
  (cd "${RAMDISK_PATH}" && find . 2>/dev/null | cpio -o -H newc -R root:root >"${MOD_RDGZ_FILE}") >>"${LOG_FILE}" 2>&1 || exit 1
fi

sync

# Clean
rm -rf "${RAMDISK_PATH}"