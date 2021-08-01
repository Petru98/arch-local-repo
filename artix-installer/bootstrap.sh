#!/bin/sh
set -e
scriptdir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
. "$scriptdir/cfg.sh"

[ $# = 1 ] || die "usage: ./bootstrap.sh ROOTDIR"
rootmnt="$1"


# alternatively: date MMDDhhmmYYYY
ntpd -q -g
configure_pacman

basestrap "$rootmnt" \
    base base-devel pacman-contrib doas \
    "$([ $initsys = s6 ] && printf s6-base || printf '%s' $initsys)" \
    cronie-$initsys chrony-$initsys dbus-$initsys elogind-$initsys \
    linux-zen linux-zen-headers linux-lts linux-lts-headers linux-firmware \
\
    e2fsprogs btrfs-progs xfsprogs reiserfsprogs jfsutils f2fs-tools nilfs-utils udftools exfat-utils dosfstools fatresize ntfs-3g \
    parted gptfdisk efibootmgr cryptsetup-$initsys lvm2-$initsys dmraid mdadm-$initsys ndctl \
    usbutils sysfsutils mtpfs cdrtools libisoburn \
\
    bash-completion zsh zsh-completions zsh-autosuggestions \
    nano nano-syntax-highlighting neovim \
    less diffutils which wget man-db man-pages openssh-$initsys \
    zip unzip unrar p7zip zstd lzop cpio \
\
    inetutils iwd-$initsys iw wireless_tools dhcpcd-$initsys wpa_supplicant-$initsys \
    amd-ucode intel-ucode dmidecode grub os-prober \
\
    git python perl ruby

# TODO maybe nftables s-nail texinfo

pacman --root "$rootmnt" -Q $EDITOR >/dev/null 2>&1 || critical "$EDITOR must be added to basestrap"
fstabgen -U "$rootmnt" >> "$rootmnt/etc/fstab"
run_interactive $EDITOR "$rootmnt/etc/fstab"
