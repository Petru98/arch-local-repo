#!/usr/bin/xonsh
import os
import re
import sys

from .cfg import *
from collections.abc import Iterable


username = 'someuser'
hostname = 'artix'
installbootloader = False

de = 'awesome'
assert de in ('awesome',)

aurhelpers = ['pikaur', 'paru']
aurhelperdeps = {
    'yay'   : ['go'],
    'pikaur': ['pyalpm', 'git', 'python-commonmark', 'asp'],
    'paru'  : ['git', 'cargo', 'bat', 'asp']
}
assert all(x in aurhelperdeps for x in aurhelpers)



def installpkg(args):
    assert ![pacman -S --needed --noconfirm @(filterargs(args))]
def ispkginstalled(args):
    return ![pacman -Q @(filterargs(args)) a> /dev/null]

kernels = list(filter(ispkginstalled, ['linux', 'linux-lts', 'linux-zen', 'linux-hardened']))
services = []



assert ![groupadd -f wheel]

assert ![ln -sf /usr/share/zoneinfo/@(timezone) /etc/localtime]
assert ![hwclock --systohc --utc]

assert ![echo f'KEYMAP={keymap}' > /etc/vconsole.conf]
assert ![echo f'LANG={locales[0]}.UTF-8\nLC_COLLATE=C' > /etc/locale.conf]
assert ![sed -i -E fr's/#(({"|".join(locales)}).UTF-8)/\1/' /etc/locale.gen]
assert ![locale-gen]

assert ![echo -n @(hostname) > /etc/hostname]
assert ![echo '127.0.0.1    localhost\n::1          localhost' >> /etc/hosts]

assert ![passwd]
assert ![chsh -s /bin/sh]

assert ![chmod 751 /home]
assert ![mkdir -f /etc/skel/.compose-cache]
assert ![chmod -R u=rwX,g=rX,o=X /etc/skel]
assert ![chmod 751 /etc/skel]

if username and not ![grep @(username) /etc/passwd]:
    assert ![useradd -m -s /bin/zsh -g @(username) -G users,wheel,audio,video,bluetooth,floppy,cdrom,optical,kvm,libvirt,xbuilder @(username)]
    assert ![passwd @(username)]
    assert ![chown -R @(username):users /home/@(username)]

if installbootloader:
    if ispkginstalled('grub'):
        if uefi:
            assert ![grub-install --target=x86_64-efi --efi-directory=@(efimnt) --bootloader-id=artix_grub --recheck]
        else:
            assert ![grub-install --target=i386-pc --recheck --debug @$(findmnt -n -o source @(rootmnt))]

        if ispkginstalled('os-prober'):
            assert ![os-prober]
        assert ![grub-mkconfig -o /boot/grub/grub.cfg]



def buildaurpkg(args):
    args = list(filter(None, args)) if isinstance(args, Iterable) and not isinstance(args, str) else [args]
    pkgdir = p'/tmp/makepkg'
    if not pkgdir.is_dir():
        mask = os.umask(0o000)
        pkgdir.mkdir(mode=0o777, parents=True, exist_ok=True)
        os.umask(mask)

    template = '\n'.join([
        f'cd {pkgdir} &&',
        'curl -o "{}.tar.gz" "https://aur.archlinux.org/cgit/aur.git/snapshot/{}.tar.gz" &&',
        'tar xzvf "{}.tar.gz" &&',
        'rm -f "{}.tar.gz" &&',
        'cd "{}" &&',
        'makepkg -csi --noconfirm &&',
        'cd .. &&',
        f'rm -fr {pkgdir}'])

    for pkg in args:
        assert ![runuser --shell /bin/sh @(username) -c template.format(pkg)]
buildaurpkg(aurhelpers)


def installpkgaur(args):
    assert ![runuser -u @(username) -- @(aurhelpers[0]) -S --needed --noconfirm @(filterargs(args))]

def addutog(group, user=username):
    assert ![groupadd -f @(group)]
    assert ![gpasswd -a @(user) @(group)]



def installvideodriver():
    driver = None
    vga = $(lspci | grep VGA).lower().splitlines()

    if ![dmidecode --type 1 | grep VirtualBox]:
        driver = 'virtualbox'
    elif ![dmidecode --type 1 | grep VMware]:
        driver = 'vmware'

    elif any('nvidia' in x for x in vga) or p'/sys/kernel/debug/dri/0/vbios.rom'.is_file():
        if len(vga) == 2:
            driver = 'bumblebee'
        else:
            driver = 'nvidia'  # 'nouveau'

    elif any('advanced micro devices' in x for x in vga) or p'/sys/kernel/debug/dri/0/radeon_pm_info'.is_file() or p'/sys/kernel/debug/dri/0/radeon_sa_info'.is_file():
        driver = 'amdgpu'  # 'ati'

    elif any('intel corporation' in x for x in vga) or p'/sys/kernel/debug/dri/0/i915_capabilities'.is_file():
        driver = 'intel'
    else:
        driver = 'vesa'

    if driver in ('intel', 'vesa') and input(f'Confirm video driver {driver} (Y/n) ').strip().lower() not in ('', 'y'):
        driver = input('Type your video driver (e.g. sis, fbdev, modesetting): ')


    def cfgmodule(module, args):
        for arg in args:
            if not ![cat /etc/modules-load.d/@(module).conf e>o | grep @(arg)]:
                assert ![echo @(arg) >> /etc/modules-load.d/@(module).conf]
                assert ![modprobe @(arg)]


    if driver == 'virtualbox':
        installpkg([
            'xf86-video-vmware' if int($(lspci | grep "VMware SVGA" -c)) > 0 else None,
            'virtualbox-guest-utils',
            'mesa-libgl',
            'virtualbox-guest-dkms'
        ])
        cfgmodule('virtualbox-guest', ['vboxguest', 'vboxsf', 'vboxvideo'])
        addutog('vboxsf')
        enablesv('vboxservice')

    elif driver == 'vmware':
        installpkg([
            'xf86-video-vmware',
            'xf86-input-vmmouse',
            'open-vm-tools' if 'linux' in kernels else None
        ])
        if 'linux' not in kernels:
            installpkgaur('open-vm-tools-dkms')
        enablesv('vmtoolsd')

    elif driver in ('bumblebee', 'nvidia'):
        extra = [
            'xf86-video-intel',
            'bumblebee',
            'primus_vk',
            'lib32-primus_vk'
        ] if driver == 'bumblebee' else []

        installpkg(extra + [
            'nvidia' if 'linux' in kernels,
            'nvidia-lts' if 'linux-lts' in kernels,
            'nvidia-dkms' if list(filter(lambda k: k not in ('linux', 'linux-lts'), kernels)),
            'nvidia-settings',
            'nvtop',
            'vdpauinfo',
        ])
        installpkg(['--asdeps',
            'nvidia-utils',
            'opencl-nvidia',
            'ocl-icd',
            'vulkan-icd-loader',
            'libva-vdpau-driver',
            'libvdpau',
            'lib32-nvidia-utils',
            'lib32-opencl-nvidia',
            'lib32-ocl-icd',
            'lib32-vulkan-icd-loader',
            'lib32-libva-vdpau-driver',
            'lib32-libvdpau',
        ])

        # if ispkginstalled('nvidia-dkms'):
        #     warning('Do not forget to use mkinitcpio every time you updated the nvidia driver!')
        if driver == 'bumblebee':
            addutog('bumblebee')
        # else
        # Creates problems and solves none
        #     assert ![nvidia-xconfig --add-argb-glx-visuals --allow-glx-with-composite --composite --render-accel -o /etc/X11/xorg.conf.d/20-nvidia.conf]

    elif driver == 'nouveau':
        pass
        # TODO
        # package_install('xf86-video-nouveau', 'mesa-libgl', 'libvdpau-va-gl')

    elif driver == 'ati':
        pass
        # TODO
        # if os.path.isfile('/etc/X11/xorg.conf.d/20-radeon.conf'): os.remove('/etc/X11/xorg.conf.d/20-radeon.conf')
        # if os.path.isfile('/etc/X11/xorg.conf'): os.remove('/etc/X11/xorg.conf')
        # package_install('xf86-video-ati', 'mesa-libgl', 'mesa-vdpau', 'libvdpau-va-gl')
        # configure_module('ati', 'radeon')

    elif driver == 'amdgpu':
        pass
        # TODO
        # if os.path.isfile('/etc/X11/xorg.conf.d/20-radeon.conf'): os.remove('/etc/X11/xorg.conf.d/20-radeon.conf')
        # if os.path.isfile('/etc/X11/xorg.conf'): os.remove('/etc/X11/xorg.conf')
        # package_install('xf86-video-amdgpu', 'vulkan-radeon', 'mesa-libgl', 'mesa-vdpau', 'libvdpau-va-gl')
        # configure_module('ati', 'amdgpu', 'radeon')

    elif driver == 'intel':
        pass
        # TODO
        installpkg(['xf86-video-intel', 'mesa-libgl', 'libvdpau-va-gl'])

    else:
        pass
        # TODO
        installpkg(['xf86-video-vesa', 'mesa-libgl', 'libvdpau-va-gl'])

    installpkg(['clinfo', 'vulkan-tools', 'libva-utils'])
    installpkg(['--asdeps', 'libva', 'lib32-libva'])
    if ispkginstalled('libvdpau-va-gl'):
        assert ![echo "\n# libvdpau-va-gl\nexport VDPAU_DRIVER=va_gl" o> /etc/profile]
installvideodriver()


installpkg([
    'xorg-server', 'xorg-apps', 'xorg-xinit', 'xorg-fonts', 'xdg-user-dirs', 'xclip', 'xdotool',
    'alsa-firmware', 'alsa-utils', 'alsa-tools', 'alsa-plugins', 'lib32-alsa-plugins',
    'pulseaudio', 'pulsemixer', 'lib32-libpulse',
    'gnu-free-fonts', 'wqy-microhei',
    'cups', 'cups-pdf', 'cups-pk-helper', 'bluez-cups', 'gutenprint', 'gsfonts', 'foomatic-db-engine', 'system-config-printer',
    'bluez', 'bluez-utils', 'bluez-tools', 'bluez-cups', 'bluez-plugins', 'bluez-hid2hci',
])
installpkg(['--asdeps',
    'pulseaudio-alsa', 'pulseaudio-bluetooth', 'pulseaudio-jack', 'pulseaudio-zeroconf',
    'cairo', 'fontconfig', 'freetype2',
    'cups-filters', 'ghostscript', 'foomatic-db', 'foomatic-db-nonfree', 'foomatic-db-ppds', 'foomatic-db-nonfree-ppds', 'foomatic-db-gutenprint-ppds',
])


def installde():
    def configure_xinitrc(args):
        assert ![sed -i f's/^exec .*/exec {" ".join(args)}/' /etc/X11/xinit/xinitrc]

    if de == 'plasma':
        installpkg([
            'plasma-meta', 'kde-accessibility-meta', 'colord-kde', 'gnome-color-manager', 'ktouch', 'kde-pim-meta',
            'gwenview', 'kcolorchooser', 'kdegraphics-mobipocket', 'kdegraphics-thumbnailers', 'kgraphviewer', 'kipi-plugins', 'okular', 'spectacle', 'svgpart', 'ffmpegthumbs', 'kamoso', 'kmix',
            'kdeconnect', 'sshfs', 'kdenetwork-filesharing', 'kio-extras', 'zeroconf-ioslave', 'dolphin', 'dolphin-plugins', 'kdiff3', 'ksystemlog',
            'ark', 'kate', 'kcalc', 'ktimer', 'kcharselect', 'kdialog', 'kfind', 'konsole', 'krename', 'okteta', 'print-manager', 'skanlite', 'yakuake', 'partitionmanager', 'filelight',
            'networkmanager', 'networkmanager-openconnect', 'networkmanager-openvpn', 'networkmanager-pptp', 'networkmanager-vpnc',
        ])
        installpkg(['--asdeps', 'packagekit-qt5', 'dnsmasq'])
        enablesv('NetworkManager')
        configure_xinitrc('startkde')

        installpkg([f'sddm-{initsys}', 'sddm-kcm'])
        enablesv('sddm')
        s = $(sddm --example-config)
        s = re.sub(r'Current=', 'Current=breeze', s, flags=re.MULTILINE)
        s = re.sub(r'CursorTheme=', 'CursorTheme=breeze_cursors', s, flags=re.MULTILINE)
        s = re.sub(r'Numlock=none', 'Numlock=on', s, flags=re.MULTILINE)
        assert ![echo @(s) > /etc/sddm.conf)

    elif de == 'awesome':
        installpkg([
            'awesome',
            'kitty', # nomacs/geeqie/phototonic qpdfview/llpp flameshot guvcview-qt/zart???
            # nnn/mc/pcmanfm-qt/pcmanfm/doublecmd-qt5/doublecmd-gtk2/tuxcmd diffuse/meld colordiff
            # lxqt-archiver/xarchiver notepadqq/featherpad/xed/beaver/scite speedcrunch xsane/gscan2pdf scantailor-advanced??? gparted ncdu/gdmap
            f'connman-{initsys}', 'cmst',
            # fox sane-frontends???
        ])
        installpkg(['--asdeps',
            'dex', 'rlwrap', 'vicious',
            'imagemagick', 'libheif', 'libraw', 'librsvg', 'libwebp', 'libwmf', 'openexr', 'openjpeg2', 'pango', # xsane-gimp???
        ])
        enablesv('connman')

        installpkg('lxdm')
        enablesv('lxdm')

        # imhex

    # enablesv('accounts-daemon')
installde()


installpkg([
    'jdk11-openjdk', 'cmake', 'ninja', 'npm',  # 'mono',
    'code', 'python-pylint', 'flake8', 'shellcheck', 'namcap',
    'valgrind', 'qcachegrind',
    # 'radare2-cutter',

    'gocryptfs', 'keepassxc', 'torbrowser-launcher', 'firetools',

    'ffmpeg', 'youtube-dl', 'gimp', 'vlc',
    # hexchat transmission-qt
    'psensor', 'pacmanlogviewer',

    'libreoffice-fresh',
    'steam', 'discord', 'obs-studio',
])
installpkg(['--asdeps',
    'tk', 'torsocks', 'python-pycryptodome',
])

installpkgaur([
    'rtl8812au-dkms-git', 'imagescan-plugin-networkscan',
    'zsh-syntax-highlighting-git', 'wipefreespace', # woeusb
])



ispkginstalled('cronie') and enablesv('crond') # ???
ispkginstalled('chrony') and enablesv('chrony')


assert ![pacman -Qdtq | pacman -Rsn --noconfirm -]
