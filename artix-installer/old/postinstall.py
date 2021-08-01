#!/usr/bin/python3 -B
import contextlib
import os
import os.path
import re
import sys

from pathlib import Path
from subprocess import DEVNULL

import cfg
from cfg import (
    elogfd, info, warning, critical, title, writeto, readfrom, prompt, prompt_bool,
    run, run_out, run_log, get_run_args_list, get_run_args_str,
)


VIDEO_DRIVER = None
USERNAME = None

INSTALL_PROPRIETARY_GPU_DRIVERS = True

AUR_HELPER = 'yay'
assert AUR_HELPER in ('yay',)

DESKTOPENV = 'kde'
assert DESKTOPENV in (None, '', 'cinnamon', 'kde')  # 'deepin', 'enlightenment', 'gnome', 'lxqt', 'mate', 'xfce', 'budgie', 'awesome', 'fluxbox', 'i3-wm', 'i3-gaps', 'openbox', 'xmonad'

DISPLAYMAN = 'sddm'
assert DISPLAYMAN in (None, '', 'gdm', 'lightdm', 'sddm', 'slim', 'lxdm', 'lxdm-gtk3')

KDE = DESKTOPENV in ('kde', 'lxqt')


# Functions

def add_user_to_group(user, group):
    info(f'Adding user {user} to group {group}.')
    run_log(['groupadd', '-f', group])
    run_log(['gpasswd', '-a', user, group])

def add_line(line, file):
    if run(['grep', '-i', line, file], check=False, stdout=DEVNULL, stderr=DEVNULL).returncode != 0:
        writeto(file, line, 'a')


def is_package_installed(*args, **kwargs):
    return run(['pacman', '-Q', *args], check=False, stdout=DEVNULL, stderr=DEVNULL, **kwargs).returncode == 0

def package_install(*args, **kwargs):
    args = get_run_args_list(args)
    return run_log(['pacman', '-S', '--needed', '--noconfirm', *args], **kwargs)

def package_remove(*args, **kwargs):
    args = get_run_args_list(args)
    return run_log(['pacman', '-Rsncq', '--noconfirm', *args], **kwargs)

def aur_package_install(*args, **kwargs):
    assert AUR_HELPER
    user = kwargs.setdefault('user', USERNAME)
    del kwargs['user']
    args = get_run_args_list(args)
    return run_log('runuser', '-u', user, '--', AUR_HELPER, '-S', '--needed', '--noconfirm', *args, **kwargs)

def aur_build_packages(*args, **kwargs):
    user = kwargs.setdefault('user', USERNAME)
    del kwargs['user']
    args = get_run_args_str(args)
    PKGDIR = Path('/tmp/makepkg')
    mask = os.umask(0o000)
    PKGDIR.mkdir(mode=0o777, parents=True, exist_ok=True)
    os.umask(mask)

    return run_log('\n'.join([
        f'cd {PKGDIR}',
        f'for x in {args} ; do',
        '    curl -o "$x.tar.gz" "https://aur.archlinux.org/cgit/aur.git/snapshot/$x.tar.gz"',
        '    tar zxvf "$x.tar.gz"',
        '    rm "$x.tar.gz"',
        '    cd "$x"',
        '    makepkg -csi --noconfirm',
        '    cd ..',
        'done'
    ]), shell=True, executable=['runuser', '-u', user, '--'], **kwargs)

    sys.exit()



def configure_user():
    global USERNAME
    title('User - https://wiki.archlinux.org/index.php/Users_and_groups')

    while not USERNAME: USERNAME = prompt('Username')
    run_log(['useradd', '-m', '-g', 'users', '-G', 'wheel', '-s', '/bin/zsh', USERNAME])
    while run_log(['passwd', USERNAME], check=False).returncode != 0: pass
    run_log(['chown', '-R', f'{USERNAME}:users', f'/home/{USERNAME}'])

def install_aur_helper():
    if AUR_HELPER == 'yay':
        package_install('--asdeps', 'go')
        aur_build_packages('yay')

    else:
        critical(f'unknown AUR helper {AUR_HELPER}')


def install_video_driver():
    global VIDEO_DRIVER
    assert is_package_installed('dmidecode')
    if not VIDEO_DRIVER:
        info('Detecting video chipset.')
        vga = run_out('lspci | grep VGA', shell=True).lower().splitlines()

        if run_out('dmidecode --type 1 | grep VirtualBox', shell=True, check=False):
            info('Detected Virtualbox.')
            VIDEO_DRIVER = 'virtualbox'

        elif run_out('dmidecode --type 1 | grep VMware', shell=True, check=False):
            info('Detected VMware.')
            VIDEO_DRIVER = 'vmware'

        elif any('nvidia' in x for x in vga) or os.path.isfile('/sys/kernel/debug/dri/0/vbios.rom'):
            if len(vga) == 2:
                info('Detected Bumblebee.')
                VIDEO_DRIVER = 'bumblebee'
            else:
                info('Detected Nvidia.')
                VIDEO_DRIVER = 'nvidia' if INSTALL_PROPRIETARY_GPU_DRIVERS else 'nouveau'

        elif any('advanced micro devices' in x for x in vga) or os.path.isfile('/sys/kernel/debug/dri/0/radeon_pm_info') or os.path.isfile('/sys/kernel/debug/dri/0/radeon_sa_info'):
            info('Detected AMD')
            VIDEO_DRIVER = 'amdgpu' if INSTALL_PROPRIETARY_GPU_DRIVERS else 'ati'

        elif any('intel corporation' in x for x in vga) or os.path.isfile('/sys/kernel/debug/dri/0/i915_capabilities'):
            info('Detected Intel.')
            VIDEO_DRIVER = 'intel'

        else:
            info('Detected Vesa.')
            VIDEO_DRIVER = 'vesa'

        if VIDEO_DRIVER in ('intel', 'vesa') and not prompt_bool(f'Confirm video driver: {VIDEO_DRIVER}', default=True):
            VIDEO_DRIVER = prompt('Type your video driver (e.g. sis, fbdev, modesetting)')
        info(f'Video driver is {VIDEO_DRIVER}.')


    def configure_module(module_name, *args):
        for module in args:
            has_module = run_out(f'cat /etc/modules-load.d/{module_name}.conf 2>&1 | grep {module}', shell=True, check=False)
            if not has_module:
                writeto(f'/etc/modules-load.d/{module_name}.conf', module, mode='a')
            run_log(['modprobe', module])

    if VIDEO_DRIVER == 'virtualbox':
        if int(run_out('lspci | grep "VMware SVGA" -c', shell=True)) > 0:
            package_install('xf86-video-vmware')
        package_install('virtualbox-guest-utils', 'mesa-libgl', ('virtualbox-guest-modules-arch' if cfg.LINUX_VERSION == 'linux' else 'virtualbox-guest-dkms'))
        configure_module('virtualbox-guest', 'vboxguest', 'vboxsf', 'vboxvideo')
        add_user_to_group(USERNAME, 'vboxsf')
        run_log(['systemctl', 'enable', 'vboxservice'])

    elif VIDEO_DRIVER == 'vmware':
        package_install('xf86-video-vmware', 'xf86-input-vmmouse')
        if cfg.LINUX_VERSION == 'linux':
            package_install('open-vm-tools')
        else:
            aur_package_install('open-vm-tools-dkms')
        # writeto('/etc/arch-release', readfrom('/proc/version'))
        run_log(['systemctl', 'enable', 'vmtoolsd'])

    elif VIDEO_DRIVER == 'bumblebee':
        package_install('xf86-video-intel', 'bumblebee', 'nvidia', 'lib32-nvidia-utils', 'lib32-virtualgl')
        add_user_to_group(USERNAME, 'bumblebee')

    elif VIDEO_DRIVER == 'nvidia':
        if cfg.LINUX_VERSION == 'linux':
            package_install('nvidia', 'nvidia-utils', 'libglvnd', 'nvidia-settings')
        else:
            package_install('nvidia-dkms', 'nvidia-utils', 'libglvnd', 'lib32-nvidia-utils')
            warning('Do not forget to use mkinitcpio every time you updated the nvidia driver!')
        # run_log(['nvidia-xconfig', '--add-argb-glx-visuals', '--allow-glx-with-composite', '--composite', '--render-accel', '-o', '/etc/X11/xorg.conf.d/20-nvidia.conf'])

    elif VIDEO_DRIVER == 'nouveau':
        package_install('xf86-video-nouveau', 'mesa-libgl', 'libvdpau-va-gl')

    elif VIDEO_DRIVER == 'ati':
        if os.path.isfile('/etc/X11/xorg.conf.d/20-radeon.conf'): os.remove('/etc/X11/xorg.conf.d/20-radeon.conf')
        if os.path.isfile('/etc/X11/xorg.conf'): os.remove('/etc/X11/xorg.conf')
        package_install('xf86-video-ati', 'mesa-libgl', 'mesa-vdpau', 'libvdpau-va-gl')
        configure_module('ati', 'radeon')

    elif VIDEO_DRIVER == 'amdgpu':
        if os.path.isfile('/etc/X11/xorg.conf.d/20-radeon.conf'): os.remove('/etc/X11/xorg.conf.d/20-radeon.conf')
        if os.path.isfile('/etc/X11/xorg.conf'): os.remove('/etc/X11/xorg.conf')
        package_install('xf86-video-amdgpu', 'vulkan-radeon', 'mesa-libgl', 'mesa-vdpau', 'libvdpau-va-gl')
        configure_module('ati', 'amdgpu', 'radeon')

    elif VIDEO_DRIVER == 'intel':
        package_install('xf86-video-intel', 'mesa-libgl', 'libvdpau-va-gl')

    else:
        package_install('xf86-video-vesa', 'mesa-libgl', 'libvdpau-va-gl')

    run_log(['mkinitcpio', '-P'])
    package_install('--asdeps', 'libva-vdpau-driver')
    if is_package_installed('mesa-libgl'): package_install('lib32-mesa-libgl')
    if is_package_installed('mesa-vdpau'): package_install('lib32-mesa-vdpau')
    if is_package_installed('libvdpau-va-gl'):
        add_line('export VDPAU_DRIVER=va_gl', '/etc/profile')

def install_xorg():
    title('Xorg - https://wiki.archlinux.org/index.php/Xorg')
    package_install('xorg-server', 'xorg-apps', 'xorg-xinit', 'xorg-xkill', 'xorg-xinput', 'xf86-input-libinput', 'mesa')
    run_log(['modprobe', 'uinput'])

def install_alsa():
    title('Alsa - https://wiki.archlinux.org/index.php/Alsa')
    package_install('alsa-utils', 'alsa-plugins', 'lib32-alsa-plugins')

def install_pulseaudio():
    title('Pulseaudio - https://wiki.archlinux.org/index.php/Pulseaudio')
    package_install('pulseaudio', 'pulseaudio-alsa', 'lib32-libpulse')

def install_fonts():
    title('Font configuration - https://wiki.archlinux.org/index.php/Font_Configuration')
    package_install('--asdeps', 'cairo', 'fontconfig', 'freetype2')
    title('Fonts - https://wiki.archlinux.org/index.php/Fonts')
    package_install('gnu-free-fonts', 'wqy-microhei', 'ttf-roboto', 'ttf-roboto-mono', 'ttf-dejavu', 'ttf-liberation')

def install_cups():
    title('Cups - https://wiki.archlinux.org/index.php/Cups')
    package_install('cups', 'cups-pdf')
    package_install('gutenprint', 'ghostscript', 'gsfonts', 'foomatic-db', 'foomatic-db-engine', 'foomatic-db-nonfree', 'foomatic-db-ppds', 'foomatic-db-nonfree-ppds', 'foomatic-db-gutenprint-ppds')
    run_log(['systemctl', 'enable', 'org.cups.cupsd.service'])


def install_desktop_environment():
    def configure_xinitrc(*args):
        args = get_run_args_str(args)
        run_log(['sed', '-i', f's/^exec .*/exec {args}/', '/etc/X11/xinit/xinitrc'])

    if DESKTOPENV == 'cinnamon':
        info('https://wiki.archlinux.org/index.php/Cinnamon')
        package_install(
            'cinnamon', 'nemo-fileroller', 'nemo-preview',
            'gedit', 'ghex', 'eog', 'evolution', 'seahorse', 'gnome-screenshot', 'gnome-terminal', 'gnome-control-center', 'gnome-system-monitor', 'gnome-power-manager', 'gnome-clocks', 'gnome-calculator', 'gnome-disk-utility', 'gparted', 'simple-scan', 'gucharmap', 'gnome-font-viewer',
            'network-manager-applet', 'materia-gtk-theme', 'redshift',
        )
        package_install('--asdeps', 'gedit-plugins', 'blueberry', 'gnome-keyring', 'gpart')

        run_log(['systemctl', 'enable', '--user', '--global', 'redshift-gtk.service'])
        # https://bbs.archlinux.org/viewtopic.php?id=185123
        aur_package_install('mintlocale')
        configure_xinitrc('cinnamon-session')

    elif DESKTOPENV == 'kde':
        info('https://wiki.archlinux.org/index.php/KDE')
        package_install(
            'plasma-meta', 'kde-accessibility-meta', 'colord-kde', 'gnome-color-manager', 'ktouch', 'kde-pim-meta',
            'gwenview', 'kcolorchooser', 'kdegraphics-mobipocket', 'kdegraphics-thumbnailers', 'kgraphviewer', 'kipi-plugins', 'okular', 'spectacle', 'svgpart', 'ffmpegthumbs', 'kamoso', 'kmix',
            'kdeconnect', 'sshfs', 'kdenetwork-filesharing', 'kio-extras', 'zeroconf-ioslave', 'dolphin', 'dolphin-plugins', 'kdiff3', 'ksystemlog',
            'ark', 'kate', 'kcalc', 'ktimer', 'kcharselect', 'kdialog', 'kfind', 'konsole', 'krename', 'okteta', 'print-manager', 'skanlite', 'yakuake', 'partitionmanager', 'filelight',
        )
        package_install('--asdeps', 'packagekit-qt5')

        configure_xinitrc('startkde')

    elif DESKTOPENV:
        critical(f'unknown desktop environment {DESKTOPENV}')


    if DISPLAYMAN == 'gdm':
        package_install('gdm')
        run_log(['systemctl', 'enable', 'gdm'])

    elif DISPLAYMAN == 'lightdm':
        package_install('lightdm', *(('lightdm-gtk-greeter-settings',) if not KDE else ()))
        run_log(['systemctl', 'enable', 'lightdm'])

    if DISPLAYMAN == 'sddm':
        package_install('sddm', 'sddm-kcm')
        run_log(['systemctl', 'enable', 'sddm'])
        s = run_out(['sddm', '--example-config'])
        s = re.sub(r'Current=', 'Current=breeze', s, flags=re.MULTILINE)
        s = re.sub(r'CursorTheme=', 'CursorTheme=breeze_cursors', s, flags=re.MULTILINE)
        s = re.sub(r'Numlock=none', 'Numlock=on', s, flags=re.MULTILINE)
        writeto('/etc/sddm.conf', s)

    if DISPLAYMAN == 'slim':
        package_install('slim')
        run_log(['systemctl', 'enable', 'slim'])

    if DISPLAYMAN == 'lxdm':
        package_install('lxdm')
        run_log(['systemctl', 'enable', 'lxdm'])

    if DISPLAYMAN == 'lxdm-gtk3':
        package_install('lxdm-gtk3')
        run_log(['systemctl', 'enable', 'lxdm'])


    if not DISPLAYMAN and DESKTOPENV:
        warning(f'You probably want to add the following to /home/{USERNAME}/.profile')
        elogfd.write('[ -z "$DISPLAY" ] && [ $(tty) == /dev/tty1 ] && exec startx\n')
        if not KDE:
            warning('You probably want to add the following to /etc/pam.d/login')
            elogfd.write('auth       optional     pam_gnome_keyring.so\n')
            elogfd.write('session    optional     pam_gnome_keyring.so auto_start\n')


    if KDE:
        package_install('transmission-qt')
    else:
        package_install(
            'transmission-gtk', 'pavucontrol',
            'gvfs', 'gvfs-afc', 'gvfs-mtp', 'gvfs-goa', 'gvfs-google', 'gvfs-nfs', 'gvfs-smb', 'gvfs-nfs'
        )

    package_install(
        'gvfs-mtp', 'xdg-user-dirs', 'dconf-editor', 'archlinux-wallpaper',
        'vlc', 'hexchat', 'espeak-ng-espeak', 'speech-dispatcher',
    )
    package_install('--asdeps', 'system-config-printer', 'transmission-cli')

    # speed up application startup
    os.makedirs(f'{os.environ["HOME"]}/.compose-cache', exist_ok=True)
    os.makedirs(f'/home/{USERNAME}/.compose-cache', exist_ok=True)

    # D-Bus interface for user account query and manipulation
    run_log(['systemctl', 'enable', 'accounts-daemon'])

    # https://unix.stackexchange.com/questions/13751/kernel-inotify-watch-limit-reached
    add_line('fs.inotify.max_user_watches = 524288', '/etc/sysctl.d/99-sysctl.conf')

def install_networkmanager():
    title('NetworkManager - https://wiki.archlinux.org/index.php/Networkmanager')
    package_install('networkmanager', 'networkmanager-openconnect', 'networkmanager-openvpn', 'networkmanager-pptp', 'networkmanager-vpnc')
    package_install('--asdeps', 'dnsmasq')

    # writeto('/etc/NetworkManager/conf.d/dns.conf', '[main]\ndns=dnsmasq')
    # writeto('/etc/NetworkManager/conf.d/dhcp-client.conf', '[main]\ndhcp=dhclient')
    run_log(['systemctl', 'enable', 'NetworkManager.service'])

def install_bluetooth():
    title('Bluetooth - https://wiki.archlinux.org/index.php/Bluetooth')
    package_install('bluez', 'bluez-utils')
    run_log(['systemctl', 'enable', 'bluetooth.service'])
    run_log(['systemctl', 'restart', 'bluetooth.service'])


def install_rtl8812au():
    title('rtl8812au - https://wiki.archlinux.org/index.php/Wireless_network_configuration#rtl88xxau')
    aur_package_install('rtl8812au-dkms-git')

def install_epson_imagescan():
    title('Imagescan - https://wiki.archlinux.org/index.php/SANE/Scanner-specific_problems#Epson')
    aur_package_install('imagescan-plugin-networkscan')
    warning('You need to configure imagescan by appending your Epson scanner configuration to /etc/utsushi/utsushi.conf')
    info('Template:')
    elogfd.write('[devices]\nmyscanner.udi    = esci:networkscan://192.168.100.24:1865\nmyscanner.vendor = Epson\nmyscanner.model  = L3160\n\n')


def install_wine():
    title('Wine - https://wiki.archlinux.org/index.php/Wine')
    info('Installing wine and setup_dxvk.')
    package_install('wine-staging', 'wine-nine', 'winetricks')
    package_install('--asdeps', 'dosbox', 'vkd3d', 'lib32-vkd3d', 'openal', 'lib32-openal', 'lib32-mpg123')
    aur_package_install('dxvk-bin', 'wine-mono-bin', 'wine-gecko-bin')
    warning('You will have to run "setup_dxvk install --with-d3d10 --symlink" to install dxvk in WINEPREFIX.')

def install_virt_manager():
    title('Virt Manager - https://wiki.archlinux.org/index.php/Libvirt')
    package_install('virt-manager', 'edk2-ovmf', 'qemu-guest-agent', 'spice-vdagent')
    package_install('--asdeps', 'qemu', 'dnsmasq', 'qemu-arch-extra', 'libvirt-storage-gluster', 'libvirt-storage-iscsi-direct', 'libvirt-storage-rbd', 'qemu-block-gluster', 'qemu-block-iscsi', 'qemu-block-rbd', *(['ebtables'] if not is_package_installed('ebtables') else []))

def install_docker():
    title('Docker - https://wiki.archlinux.org/index.php/Docker')
    package_install('docker')
    add_user_to_group(USERNAME, 'docker')

def install_virtualbox():
    title('Virtualbox - https://wiki.archlinux.org/index.php/VirtualBox')
    package_install('--asdeps', 'virtualbox-guest-iso', ('virtualbox-host-modules-arch' if cfg.LINUX_VERSION == 'linux' else 'virtualbox-host-dkms'))
    aur_package_install('virtualbox-ext-oracle')
    package_install('virtualbox')



configure_user()

with contextlib.ExitStack() as stack:
    writeto('/etc/sudoers.d/tmp', f'{USERNAME}  ALL=(ALL) NOPASSWD: ALL\n')
    stack.callback(lambda: os.remove('/etc/sudoers.d/tmp'))

    install_aur_helper()
    install_video_driver()
    install_xorg()
    install_alsa()
    install_pulseaudio()
    install_fonts()
    install_cups()

    install_desktop_environment()
    install_networkmanager()
    install_bluetooth()

    install_rtl8812au()
    install_epson_imagescan()

    install_wine()
    install_virt_manager()
    # install_docker()
    # install_virtualbox()

    # devel
    package_install(
        'git', 'jdk11-openjdk', 'cmake', 'ninja', 'npm',  # 'mono',
        'code', 'python-pylint', 'flake8', 'shellcheck', 'namcap',
        'valgrind', ('kcachegrind' if KDE else 'qcachegrind'),
        # 'radare2-cutter',
    )
    package_install('--asdeps', 'tk')

    # misc
    package_install(
        'gocryptfs', 'ffmpeg', 'obs-studio', 'firefox',
        'keepassxc', 'libreoffice-fresh', 'pacmanlogviewer', 'psensor',
        'steam', 'discord', 'gameconqueror',
        'torbrowser-launcher', 'firetools',
        # gimp, # firefox-ublock-origin, firefox-dark-reader, firefox-decentraleyes, firefox-extension-https-everywhere, firefox-extension-privacybadger, firefox-noscript, firefox-umatrix,
    )
    package_install('--asdeps', 'wl-clipboard', 'xclip', 'torsocks')

    # aur
    aur_package_install('zsh-syntax-highlighting-git', 'wipefreespace', 'downline-bin')  # woeusb
    package_install('--asdeps', 'youtube-dl', 'python-pycryptodome')


info('Configuring dconf.')
run_log(['dconf', 'update'])

info('Cleaning orphan packages.')
run_log('pacman -Qdtq | pacman -Rsn --noconfirm -', shell=True, check=False)

info('Installation complete. Please reboot.')
