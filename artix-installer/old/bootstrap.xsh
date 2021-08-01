#!/usr/bin/xonsh
from .cfg import *


input(f'Make sure that the mounts in {rootmnt} are ok! The fstab file will be generated from them. Use Ctrl+C to abort, or press Enter to continue.')

time = input('Date and time (MMDDhhmmYYYY or empty for automatic sync): ').strip()
if time != '':
    assert ![date @(time)]
else
    assert ![ntpd -q -g]


assert ![basestrap @(rootmnt)
    base base-devel pacman-contrib @(initsys) cronie-@(initsys) chrony-@(initsys) dbus-@(initsys) elogind-@(initsys)
    linux-zen linux-zen-headers linux-lts linux-lts-headers linux-firmware

    e2fsprogs btrfs-progs xfsprogs reiserfsprogs jfsutils f2fs-tools nilfs-utils udftools exfat-utils dosfstools fatresize ntfs-3g
    parted gptfdisk efibootmgr cryptsetup-@(initsys) lvm2-@(initsys) dmraid mdadm-@(initsys) ndctl
    usbutils sysfsutils autofs-@(initsys) mtpfs cdrtools libisoburn

    bash-completion zsh zsh-completions zsh-autosuggestions
    nano nano-syntax-highlighting neovim
    less diffutils which wget man-db man-pages openssh-@(initsys)
    zip unzip unrar p7zip zstd lzop cpio

    inetutils iwd-@(initsys) iw wireless_tools dhcpcd-@(initsys) wpa_supplicant-@(initsys)
    amd-ucode intel-ucode dmidecode grub os-prober

    git python perl xonsh
]
# nftables s-nail texinfo

assert ![fstabgen -U @(rootmnt) >> @(rootmnt)/etc/fstab]
$[$EDITOR @(rootmnt)/etc/fstab]

assert ![mkdir -p @(rootmnt)/root/install]
assert ![cp -T @(rootmnt)/root/install @$(pwd)]
$[artix-chroot @(rootmnt) xnosh -c '/root/install/install.xsh']
assert ![cp -f -T @(rootmnt)/root/install @$(pwd)]
