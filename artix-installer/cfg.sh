# shellcheck shell=sh
olog() {
    printf '%s\n' "$*"
}
elog() {
    printf '%s\n' "$*" >&2
}
die() {
    elog "$*"
    exit 1
}

info() {
    elog "INFO: $*"
}
warning() {
    elog "WARNING: $*"
}
error() {
    elog "ERROR: $*"
}
critical() {
    die "CRITICAL: $*"
}

linesep="$(printf "%80s" '' | tr ' ' '#')"
title() {
    printf "\n$linesep\n# %s\n$linesep\n" '' >&2
}



run_interactive() {
    "$@" 1>/dev/tty 2>/dev/tty
}

setkeyvalue() {  # TODO unused, maybe remove ?
    [ $# -eq 3 ] || die "setkeyvalue: invalid number of arguments"
    if grep -q "^$2[[:space:]]*=" "$1" ; then
        sed -E -i "s/^#?[[:space:]]*($2[[:space:]]*=[[:space:]]*).*/\\1$3/" "$1"
    else
        printf '%s' "$2=$3" >> "$1"
    fi
}

hasstrs() {
    _str="$1"
    shift
    for _arg in "$@" ; do
        case "$_str" in
            *"$_arg"*) ;;
            *) return 1
        esac
    done
    unset _str
}
haswords() {
    _str="$1"
    shift
    for _arg in "$@" ; do
        case "$_str" in
            "$_arg") ;;
            "$_arg "*) ;;
            *" $_arg") ;;
            *" $_arg "*) ;;
            *) return 1
        esac
    done
    unset _str
}

configure_pacman() {
    sed -i -E '/^#\[lib32\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
    pacman-key --init
    pacman-key --populate artix
    pacman -Sy --noconfirm lib32-artix-archlinux-support artix-archlinux-support

    # shellcheck disable=SC2016
    grep '^\[universe\]'  /etc/pacman.conf || printf '\n%s\n%s\n' '[universe]'  'Server = https://universe.artixlinux.org/$arch' >> /etc/pacman.conf
    grep '^\[extra\]'     /etc/pacman.conf || printf '\n%s\n%s\n' '[extra]'     'Include = /etc/pacman.d/mirrorlist-arch'        >> /etc/pacman.conf
    grep '^\[community\]' /etc/pacman.conf || printf '\n%s\n%s\n' '[community]' 'Include = /etc/pacman.d/mirrorlist-arch'        >> /etc/pacman.conf
    grep '^\[multilib\]'  /etc/pacman.conf || printf '\n%s\n%s\n' '[multilib]'  'Include = /etc/pacman.d/mirrorlist-arch'        >> /etc/pacman.conf

    # TODO sort and enable closest mirrors

    pacman-key --populate archlinux
    pacman -Sy
}



export EDITOR=nano

keymap='us'
[ -n "$(find /usr/share/kbd/keymaps/ -name $keymap.map.gz -print -quit)" ] || critical "$keymap is not a valid keymap"

locales='en_US ro_RO ja_JP'
for _locale in $locales ; do
    grep -q "$_locale.UTF-8" /etc/locale.gen || critical "$_locale is not a valid locale"
done

timezone='Europe/Bucharest'
[ -f /usr/share/zoneinfo/posix/$timezone ] || critical "$timezone is not a valid timezone"

initsys='s6'
haswords 's6 66' $initsys || critical "$initsys is not a supported init system"


uefi=true
if [ $uefi = true ]; then
    # shellcheck disable=2034
    efimnt='/boot/efi'
fi
