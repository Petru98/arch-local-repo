#!/bin/sh
set -e
# FIXME remove set -x
set -x
scriptdir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
. "$scriptdir/cfg.sh"


################################################################
# config
################################################################
export UMASK=077
umask $UMASK

username=artix
grep -q $username /etc/passwd && critical "user $username already exists"
grep -q $username /etc/group && critical "group $username already exists"
makepkguser=makepkg
grep -q $username /etc/passwd && critical "user $makepkguser already exists"
grep -q $username /etc/group && critical "group $makepkguser already exists"

hostname=artix
# FIXME set to false by default
installbootloader=true

de=awesome
haswords 'awesome' $de || critical "$de is not a supported DE/WM"

aurhelper=paru

if [ $uefi = true ]; then
    mountpoint -q "$efimnt" || critical "$efimnt is not a mountpoint"
fi


################################################################
# util
################################################################
installpkg() {
    pacman -S --needed --noconfirm "$@"
}
removepkg() {
    pacman -R --noconfirm "$@"
}
querypkg() {
    pacman -Q "$@" > /dev/null 2>&1
}
addutog() {
    [ $# = 1 ] && set -- $username "$1"
    [ $# = 2 ] || die "addutog: invalid number of arguments $#"
    groupadd -f "$1"
    gpasswd -a "$2" "$1"
}

kernels=''
for _kernel in linux linux-lts linux-zen linux-hardened ; do
    querypkg $_kernel && kernels="$kernels $_kernel"
done
unset _kernel


################################################################
# basic configuration
################################################################
true && \
{
    ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
    hwclock --systohc --utc

    printf '%s\n' "KEYMAP=$keymap" > /etc/vconsole.conf
    printf '%s\n' "LANG=${locales%% *}.UTF-8" 'LC_COLLATE=C' > /etc/locale.conf
    sed -i -E "s/#(($(printf '%s' "$locales" | tr ' ' '|')).UTF-8)/\\1/" /etc/locale.gen
    locale-gen

    printf '%s' $hostname > /etc/hostname
    printf '%s\n' '127.0.0.1    localhost' '::1          localhost' >> /etc/hosts

    # TODO echo "fs.inotify.max_user_watches=204800" > /etc/sysctl.d/90-override.conf

    if grep -q '^umask ' /etc/profile ; then
        sed -i "s/^umask .*/umask $UMASK/" /etc/profile
    else
        printf '\n%s\n%s\n' '# Set our umask' "umask $UMASK" >> /etc/profile
    fi

    configure_pacman


    # bootloader
    if [ $installbootloader = true ]; then
        if querypkg grub ; then
            if [ $uefi = true ]; then
                grub-install --target=x86_64-efi --efi-directory="$efimnt" --bootloader-id=artix_grub --recheck
            else
                grub-install --target=i386-pc --recheck --debug "$(findmnt -n -o source /)"
            fi
            # TODO in /etc/default/grub set something like GRUB_DEFAULT="Advanced options for Artix Linux>Artix Linux, with Linux linux-zen"
            querypkg os-prober && os-prober
            grub-mkconfig -o /boot/grub/grub.cfg
        fi
    fi


    # FIXME while loop for passwd
    printf '[root]\n'
    passwd
    # chsh -s /bin/zsh

    mkdir -p /etc/skel/.compose-cache
    find /etc/skel/ -mindepth 1 -maxdepth 1 -exec chmod -R u=rwX,g=,o= '{}' \;
    chmod 751 /home

    groupadd -f wheel
    useradd -r -M -U -s /usr/bin/nologin $makepkguser

    useradd -m -U -s /bin/zsh -G wheel,users,video,optical,games,kvm,$makepkguser $username
    chmod 751 /home/$username
    printf '[%s]\n' $username
    passwd $username
    chown -R $username:$username /home/$username

    if querypkg sudo ; then
        sed -i '/^root\s.*/d' /etc/sudoers
        printf '\n%s\n%s\n%s\n' \
            'root ALL=(ALL) NOPASSWD: ALL' \
            '%wheel ALL=(ALL) ALL' \
            "$makepkguser ALL=(root:root) NOPASSWD: /usr/bin/pacman" \
            >> /etc/sudoers
    fi
    if querypkg doas ; then
        printf '%s\n' \
            'permit nopass root' \
            'permit nopass keepenv root as root' \
            'permit :wheel' \
            "permit nopass $makepkguser cmd /usr/bin/pacman" \
            > /etc/doas.conf
    fi
}



################################################################
# makepkg / AUR
################################################################
makepkg_tmpdir='/tmp/makepkg'

# The following two functions are old and unneeded

# makepkg_bindir="$makepkg_tmpdir/.bin"
# shellcheck disable=SC2120
# run_makepkg_root() {
#     makepkg_cmd='/usr/bin/makepkg'
#     [ -x "$makepkg_bindir/sudo" ] || {
#         mkdir -p "$makepkg_bindir"
#         printf '%s\n' '#!/bin/sh' 'env EUID=0 "$@"' > "$makepkg_bindir/sudo"
#         chmod +x "$makepkg_bindir/sudo"
#     }

#     # install dependencies
#     # Keep in mind that the PKGBUILD is still sourced, so commands outside any function are still executed (as root).
#     # But then again, running makepkg as yourself on an already installed system (like most people) is, more or less, just as bad.
#     env EUID="$(id -u $makepkguser)" PATH="$makepkg_bindir:$PATH" $makepkg_cmd -s --noextract --nobuild --nocheck --noarchive --noconfirm

#     # build (it should not need sudo)
#     chown -R $makepkguser:$makepkguser .
#     runuser -u $makepkguser -- $makepkg_cmd "$@"
#     chown -R root:root .

#     # install the package
#     # Same comments as the first call, except that the "package" function may be called (actually it seems to give a warning
#     # "WARNING: A package has already been built, installing existing package", but idk)
#     env EUID="$(id -u $makepkguser)" PATH="$makepkg_bindir:$PATH" $makepkg_cmd -i --repackage --noconfirm --needed
# }
# shellcheck disable=SC2120
# run_makepkg() {
#     makepkg_cmd='/usr/bin/makepkg'
#     [ -x "$makepkg_bindir/sudo" ] || {
#         mkdir -p "$makepkg_bindir"
#         cc "$scriptdir/sudo.c" -o "$makepkg_bindir/sudo"
#     }

#     chmod -R 777 .
#     chown -R $makepkguser:$makepkguser .
#     runuser -u $makepkguser -- env PATH="$makepkg_bindir:$PATH" $makepkg_cmd -si --noconfirm --needed "$@"
#     chown -R root:root .
# }

# shellcheck disable=SC2120
run_makepkg() {
    makepkg_cmd='/usr/bin/makepkg'
    chmod -R 777 .
    chown -R $makepkguser:$makepkguser .
    # TODO set custom makepkg.conf
    runuser -u $makepkguser -- $makepkg_cmd -si --noconfirm --needed "$@"
    chown -R root:root .
}

buildpkgs() (
    _workdir="$makepkg_tmpdir/.workdir"
    for _dir in "$@" ; do
        if [ -n "$_dir" ]; then
            mkdir -p "$_workdir"
            cp -rfT "$_dir" "$_workdir"
            cd "$_workdir"

            run_makepkg

            cd ..
            rm -rf "$_workdir"
        fi
    done
)
buildaurpkgs() (
    for _pkg in "$@" ; do
        if ! querypkg "$_pkg" ; then
            mkdir -p "$makepkg_tmpdir"
            cd "$makepkg_tmpdir"
            curl -o "$_pkg.tar.gz" "https://aur.archlinux.org/cgit/aur.git/snapshot/$_pkg.tar.gz"
            tar xzvf "$_pkg.tar.gz"
            rm -f "$_pkg.tar.gz"
            cd "$_pkg"

            run_makepkg

            cd ..
            rm -rf "$_pkg"
        fi
    done
)
# installaurpkgs() {
#     makepkg_homedir="$makepkg_tmpdir/.home"
#     mkdir -p "$makepkg_homedir"

#     chmod -R 777 "$makepkg_tmpdir"
#     chown -R $makepkguser:$makepkguser "$makepkg_tmpdir"
#     # TODO remove the read commands
#     read
#     # FIXME doesn't work, there is some form of permission issue apparently
#     # maybe use some sort of namespaces instead of setting HOME
#     runuser -u $makepkguser -- env HOME="$makepkg_homedir" $aurhelper -S --needed --noconfirm "$@"
#     chown -R root:root "$makepkg_tmpdir"

#     read
#     rm -rf "$makepkg_tmpdir"
# }
installaurpkgs() {
    # TODO set custom makepkg.conf
    runuser -u $username -- $aurhelper -S --needed --noconfirm "$@"
}

# shellcheck disable=SC2086
buildaurpkgs $aurhelper-bin doas
querypkg $aurhelper || die "AUR helper $aurhelper not installed"



################################################################
# video driver
################################################################
cfgmodule() {
    _module="$1"
    shift
    for _arg in "$@" ; do
        if ! grep -q "$_arg" "/etc/modules-load.d/$_module.conf" ; then
            printf '%s\n' "$_arg" >> "/etc/modules-load.d/$_module.conf"
            modprobe "$_arg"
        fi
    done
}
true && \
{
    {
        _vga=$(lspci | grep VGA | tr '[:upper:]' '[:lower:]')

        if dmidecode --type 1 | grep VirtualBox ; then
            driver='virtualbox'
        elif dmidecode --type 1 | grep VMware ; then
            driver='vmware'

        elif hasstrs "$_vga" 'nvidia' || [ -f /sys/kernel/debug/dri/0/vbios.rom ]; then
            if [ "$(printf '%s' "$_vga" | wc -l)" = 2 ]; then
                driver='bumblebee'
            else
                driver='nvidia'
                # or 'nouveau'
            fi

        elif hasstrs "$_vga" 'advanced micro devices' || [ -f /sys/kernel/debug/dri/0/radeon_pm_info ] || [ -f /sys/kernel/debug/dri/0/radeon_sa_info ]; then
            driver='amdgpu'
            # or 'ati'

        elif hasstrs "$_vga" 'intel corporation' || [ -f /sys/kernel/debug/dri/0/i915_capabilities ]; then
            driver='intel'
        else
            driver='vesa'
        fi

        unset _vga
        { [ $driver = intel ] || [ $driver = vesa ] ; } && warning "$driver GPU detected."
    }



    if [ $driver = virtualbox ]; then
        installpkg virtualbox-guest-utils mesa-libgl virtualbox-guest-dkms
        [ "$(lspci | grep 'VMware SVGA' -c)" -gt 0 ] && installpkg xf86-video-vmware

        cfgmodule virtualbox-guest vboxguest vboxsf vboxvideo
        addutog vboxsf

    elif [ $driver = vmware ]; then
        installpkg xf86-video-vmware xf86-input-vmmouse open-vm-tools

    elif [ $driver = bumblebee ] || [ $driver = nvidia ]; then
        _pkgs=''

        # bumblebee
        if [ $driver = bumblebee ]; then
            _pkgs='xf86-video-intel bumblebee primus_vk lib32-primus_vk'
            addutog bumblebee
        fi

        # driver
        for _kernel in $kernels ; do
            if [ "$_kernel" != linux ] && [ "$_kernel" != linux-lts ]; then
                warning 'Do not forget to use mkinitcpio every time you update the nvidia driver!'
                _pkgs="$_pkgs nvidia-dkms"
                break
            fi
        done
        unset _kernel
        if ! haswords "$_pkgs" nvidia-dkms ; then
            haswords "$kernels" linux     && _pkgs="$_pkgs nvidia"
            haswords "$kernels" linux-lts && _pkgs="$_pkgs nvidia-lts"
        fi

        # shellcheck disable=SC2086
        installpkg $_pkgs nvidia-settings nvtop vdpauinfo
        unset _pkgs

        installpkg --asdeps \
            nvidia-utils \
            opencl-nvidia \
            ocl-icd \
            vulkan-icd-loader \
            libva-vdpau-driver \
            libvdpau \
            lib32-nvidia-utils \
            lib32-opencl-nvidia \
            lib32-ocl-icd \
            lib32-vulkan-icd-loader \
            lib32-libva-vdpau-driver \
            lib32-libvdpau

    elif [ $driver = nouveau ]; then
        false
        # TODO
        # package_install('xf86-video-nouveau', 'mesa-libgl', 'libvdpau-va-gl')

    elif [ $driver = ati ]; then
        false
        # TODO
        # package_install radeontop
        # if os.path.isfile('/etc/X11/xorg.conf.d/20-radeon.conf'): os.remove('/etc/X11/xorg.conf.d/20-radeon.conf')
        # if os.path.isfile('/etc/X11/xorg.conf'): os.remove('/etc/X11/xorg.conf')
        # package_install('xf86-video-ati', 'mesa-libgl', 'mesa-vdpau', 'libvdpau-va-gl')
        # configure_module('ati', 'radeon')

    elif [ $driver = amdgpu ]; then
        false
        # TODO
        # package_install radeontop
        # if os.path.isfile('/etc/X11/xorg.conf.d/20-radeon.conf'): os.remove('/etc/X11/xorg.conf.d/20-radeon.conf')
        # if os.path.isfile('/etc/X11/xorg.conf'): os.remove('/etc/X11/xorg.conf')
        # package_install('xf86-video-amdgpu', 'vulkan-radeon', 'mesa-libgl', 'mesa-vdpau', 'libvdpau-va-gl')
        # configure_module('ati', 'amdgpu', 'radeon')

    elif [ $driver = intel ]; then
        installpkg xf86-video-intel mesa-libgl libvdpau-va-gl vulkan-intel lib32-vulkan-intel

    else
        installpkg xf86-video-vesa mesa-libgl libvdpau-va-gl vulkan-swrast lib32-vulkan-intel
    fi

    installpkg clinfo vulkan-tools libva-utils
    installpkg --asdeps libva lib32-libva
    if querypkg libvdpau-va-gl ; then
        printf '\n# libvdpau-va-gl\nexport VDPAU_DRIVER=va_gl\n' > /etc/profile
    fi
}



################################################################
# basic xorg environment
################################################################
true && \
{
    installpkg \
        xorg-server xorg-apps xorg-xinit xorg-fonts xdg-user-dirs xclip xdotool \
        alsa-firmware alsa-utils alsa-utils-$initsys alsa-tools alsa-plugins lib32-alsa-plugins \
        pipewire pipewire-pulse libpulse lib32-pipewire lib32-libpulse \
        gnu-free-fonts wqy-microhei \
        cups cups-$initsys cups-pdf cups-pk-helper gutenprint gsfonts foomatic-db-engine \
        sane sane-$initsys sane-airscan \
        bluez-cups bluez bluez-$initsys bluez-utils bluez-tools bluez-plugins bluez-hid2hci
    # hplip


    installaurpkgs \
        rtl8812au-dkms-git imagescan-plugin-networkscan


    installpkg --asdeps \
        glfw-x11 \
        pipewire-media-session gst-plugin-pipewire pipewire-alsa pipewire-jack pipewire-zeroconf lib32-pipewire-jack \
        cairo fontconfig freetype2 \
        cups-filters ghostscript foomatic-db foomatic-db-nonfree foomatic-db-ppds foomatic-db-nonfree-ppds foomatic-db-gutenprint-ppds ipp-usb
    # hplip: python-pillow python-reportlab wget xsane???
}



################################################################
# DE / WM
################################################################
# TODO start processes like https://wiki.artixlinux.org/Site/PipewireInsteadPulseaudio
configure_xinitrc() {
    sed -i "s/^exec .*/exec $*/" /etc/X11/xinit/xinitrc
}
true && \
{
    if [ $de = plasma ]; then
        installpkg \
            plasma-meta kde-accessibility-meta colord-kde gnome-color-manager ktouch kde-pim-meta \
            gwenview kcolorchooser kdegraphics-mobipocket kdegraphics-thumbnailers kgraphviewer kipi-plugins okular spectacle svgpart ffmpegthumbs kamoso kmix \
            kdeconnect sshfs kdenetwork-filesharing kio-extras zeroconf-ioslave dolphin dolphin-plugins kdiff3 ksystemlog \
            ark kate ktimer kcharselect kdialog kfind konsole krename okteta print-manager skanlite yakuake partitionmanager filelight \
            networkmanager networkmanager-openconnect networkmanager-openvpn networkmanager-pptp networkmanager-vpnc \
            sddm-$initsys sddm-kcm

        installpkg --asdeps packagekit-qt5 dnsmasq
        configure_xinitrc startkde
        sddm --example-config | sed 's/Current=/Current=breeze/; s/CursorTheme=/CursorTheme=breeze_cursors/; s/Numlock=none/Numlock=on/' > /etc/sddm.conf

    elif [ $de = awesome ]; then
        # TODO
        installpkg \
            awesome \
            kitty pcmanfm-qt notepadqq lxqt-archiver nomacs qpdfview \
            gparted gscan2pdf ksnip meld \
            arandr lxrandr \
            connman-$initsys
        # lxdm
        # TODO volume, brightness to ~/.config/awesome/rc.lua
        # TODO bluetooth gui, mouse/trackpad settings gui
        # TODO install themes (icons etc.)
        # TODO replace arandr and lxrandr

        installaurpkgs \
            cmst

        installpkg --asdeps \
            dex rlwrap vicious

        # chafa figlet horst pinfo texmacs tig e3 quilt vulscan
    fi
}



################################################################
# other packages
################################################################
true && \
{
    # TODO lsof strace
    installpkg \
        nnn dhex ncdu dfc htop iotop nethogs iftop diffoscope \
        pulsemixer \
        gocryptfs bubblewrap \
        jdk11-openjdk cmake ninja npm \
        flake8 shellcheck namcap valgrind \
        newsboat \
        ffmpeg youtube-dl \
        ascii diff-so-fancy \
    \
        "$(querypkg pipewire && printf '%s' easyeffects)" \
        system-config-printer sane-frontends xsane-gimp scantailor-advanced \
        psensor pacmanlogviewer \
        keepassxc torbrowser-launcher wireshark-qt \
        code iaito qcachegrind \
        hexchat qbittorrent \
        libreoffice-fresh pdfarranger \
        vlc speedcrunch \
        obs-studio gimp gmic gimp-plugin-gmic zart guvcview-qt \
        discord steam asciiportal
    # do we need python-pylint on top of flake8?
    # mc doublecmd-qt5
    # rtorrent irssi/weechat
    # calcurse


    installpkg --asdeps \
        tk torsocks python-pycryptodome \
        imagemagick libheif libraw librsvg libwebp libwmf openexr openjpeg2 pango
    # obs-studio: v4l2loopback-dkms


    installaurpkgs \
        imhex
    # imhex uses glfw-x11 or glfw-wayland
    # TODO add hourglass back once this is fixed: https://github.com/sgpthomas/hourglass/issues/52
    # relevant: https://github.com/sgpthomas/hourglass/blob/3d2c1c7f22ee9e8675bc028be0cd707868b00807/src/Widgets/TimerTimeWidget.vala#L177
    # zsh-syntax-highlighting-git
    # libqcow
}
    # TODO remove sudo before installing doas-sudo
    # TODO local pkgbuilds
    # buildpkgs \
    #     "$(querypkg nvidia-dkms && printf '%s' "$scriptdir/../nvidia-dkms-extra")" \
    #     "$(querypkg doas        && printf '%s' "$scriptdir/../doas-sudo")"
# TODO maybe add dash as sh (watch out for https://gitea.artixlinux.org/artixlinux/community/src/branch/master/artix-archlinux-support/x86_64/community/arch-repos-hook.script)



################################################################
# cleanup
################################################################
querypkg doas && removepkg -n sudo
while pacman -Qtdq | removepkg -n - ; do : ; done

packages="$(pacman -Qq | tr '\n' ' ')"
[ -n "$packages" ] || critical 'could not query installed packages'
isinstalled() {
    haswords "$packages" "$@"
}



################################################################
# other configuration
################################################################
true && {
    isinstalled wireshark-cli && usermod -aG wireshark $username
}



################################################################
# services
################################################################
services=''
addsv() {
    services="$services $*"
}
rmsv() {
    for _arg in "$@" ; do
        case "$services" in
            "$_arg") services='' ;;
            "$_arg "*) services="${services#$_arg }" ;;
            *" $_arg") services="${services% $_arg}" ;;
            *" $_arg "*) services="${services%% $_arg *} ${services#* $_arg }" ;;
        esac
    done
}


isinstalled cronie && addsv cronie
isinstalled chrony && addsv chronyd
isinstalled acpid  && addsv acpid
isinstalled dbus   && addsv dbus
isinstalled elogin && addsv elogind
isinstalled bluez  && addsv bluetoothd
isinstalled cups   && addsv cupsd
isinstalled sane   && addsv saned
# isinstalled alsa-utils && addsv alsa

# network
if isinstalled connman ; then
    addsv connmand
elif isinstalled networkmanager ; then
    addsv NetworkManager
else
    isinstalled dhcpcd && addsv dhcpcd
    if isinstalled wpa_supplicant ; then
        addsv wpa_supplicant
    elif isinstalled iwd ; then
        addsv iwd
    fi
fi

# TODO check if packages and services are available on artix
# isinstalled virtualbox-guest-utils && addsv vboxservice
# isinstalled open-vm-tools          && addsv vmtoolsd

# XXX alsa-utils

# display manager
isinstalled lxdm && addsv lxdm
isinstalled sddm && addsv sddm

# TODO add the rest of services



case "$initsys" in
s6)
    # shellcheck disable=SC2086
    s6-rc-bundle-update -c /etc/s6/rc/compiled add default $services ;;
66)
    66-tree -n boot
    66-enable -t boot boot@system
    run_interactive 66-env -t boot -e $EDITOR boot@system
    66-enable -t boot -F boot@system
    66-tree -ncE default
    # shellcheck disable=SC2086
    66-enable -t default $services
    ;;
*)
    die "chroot.sh: $initsys init system was not matched" ;;
esac
