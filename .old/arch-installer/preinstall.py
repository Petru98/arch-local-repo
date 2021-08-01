#!/usr/bin/python3 -B
import os
from subprocess import DEVNULL

import cfg
from cfg import (
    SCRIPTDIR,
    info, warning, critical, title, pause,
    run_log, run_out, run_editor, get_run_args_list, get_run_args_str,
    get_dev_path, get_part_disk
)


BOOT_DISK = None

MIRRORLIST_ARGS = ['--sort', 'score', '-c', 'Romania']  # see 'man reflector'
MIRRORLIST_MANUAL_EDIT = True
MKINITCPIO_MANUAL_EDIT = False
FSTAB_MANUAL_EDIT = True

KEYMAP = 'us'
assert KEYMAP in run_out(['localectl', 'list-keymaps'])

LOCALES = ('en_US', 'ro_RO', 'ja_JP')
assert all(x in run_out('cat /etc/locale.gen | grep UTF-8 | sed \'/@/d\' | awk \'{print $1}\' | sed \'s/\\..*$//\' | sed \'s/#//g\' | uniq', shell=True) for x in LOCALES)

TIMEZONE = 'Europe/Bucharest'
assert TIMEZONE in run_out(['timedatectl', 'list-timezones'])

# EFI is used only when UEFI is detected
# The mounting target paths and the swap file paths are relative to ROOT_MOUNTPOINT (e.g. /efi will actually be converted to ROOT_MOUNTPOINT/efi)
ROOT_MOUNTPOINT = '/mnt'
EFI_MOUNTPOINT = '/efi'

# e.g. '/dev/sda1'
ROOT_PARTITION = '/dev/vda2'

# e.g. '/dev/sda1'
EFI_PARTITION = '/dev/vda1'

# e.g. ('/dev/sda1', '/dev/sda2')
SWAP_PARTITIONS = ()

# 0: swap file path, 1: size (string with dd suffix; can be None; equal to RAM size by default)
# e.g. (('/usr/share/swapfile1', None), ('/var/swapfile2', '16G'), ('/path/to/swap', '16386680kB'))
SWAP_FILES = ()

# e.g. (('/dev/sda1', '/mnt'), ('/dev/sdb2', '/mydata'))
OTHER_PARTITIONS = ()


# Functions

def arch_chroot(*args, **kwargs):
    if len(args) == 0:
        return run_log(['arch-chroot', ROOT_MOUNTPOINT], **kwargs)
    else:
        args = get_run_args_str(args)
        return run_log(['arch-chroot', ROOT_MOUNTPOINT, '/bin/bash', '-c', args], **kwargs)

def arch_pacstrap(*args, **kwargs):
    args = get_run_args_list(args)
    return run_log(['pacstrap', ROOT_MOUNTPOINT, *args], **kwargs)

def is_package_installed(*args, **kwargs):
    kwargs.setdefault('check', False)
    return arch_chroot(['pacman', '-Q', *args], stdout=DEVNULL, stderr=DEVNULL, **kwargs).returncode == 0



def configure_partition_scheme():
    info('Partitioning - https://wiki.archlinux.org/index.php/Partitioning')
    info('Formating - https://wiki.archlinux.org/index.php/File_Systems')
    info('Please partition and format the disk(s). Partitioners: parted, cgdisk, cfdisk, gdisk, fdisk etc.')
    info(f'Make sure that the partition table is {"GPT and that you have an EFI partition" if cfg.UEFI else "MBR and that you set the boot flag"}.')
    pause()
    run_log(['modprobe', 'dm-mod'])
    run_log(['vgscan'], stdout=DEVNULL, stderr=DEVNULL)
    run_log(['vgchange', '-ay'], stdout=DEVNULL, stderr=DEVNULL)


def mount_partitions():
    warning('Please double check and make sure that the partitions are set propely!')
    pause()

    def mount(src, dst):
        run_log(['fsck', '-p', src])
        os.makedirs(dst, mode=0o755, exist_ok=True)
        run_log(['mount', src, dst])

    def set_boot_disk(partition):
        global BOOT_DISK
        assert not partition.startswith('/dev/mapper/')
        BOOT_DISK = get_part_disk(partition)

    # root
    partition = get_dev_path(ROOT_PARTITION)
    mount(partition, ROOT_MOUNTPOINT)
    if not cfg.UEFI:
        set_boot_disk(partition)

    # swap
    for partition in SWAP_PARTITIONS:
        partition = get_dev_path(partition)
        run_log(['mkswap', partition])
        run_log(['swapon', partition])

    for file, size in SWAP_FILES:
        file = f'{ROOT_MOUNTPOINT}/{file}'
        if size is None:
            size, suffix = run_out('grep MemTotal /proc/meminfo | awk \'{print $2" "$3}\'', shell=True).split()
        else:
            suffix = next(i for i in range(len(size)) if not size[i].isdigit())
            size, suffix = size[:suffix], size[suffix:]

        # https://wiki.archlinux.org/index.php/Swap#Manually
        run_log(['dd', 'if=/dev/zero', f'of="{file}"', f'bs=1{suffix}', f'count={size}', 'status=progress'])
        os.chmod(file, 0o600)
        run_log(['mkswap', file])
        run_log(['swapon', file])

    # efi
    if cfg.UEFI:
        partition = get_dev_path(EFI_PARTITION)
        if partition.startswith('/dev/mapper/'):
            critical('EFI partition should not be on LVM.')
        mount(partition, f'{ROOT_MOUNTPOINT}/{EFI_MOUNTPOINT}')

    # other
    for partition, mountpoint in OTHER_PARTITIONS:
        partition = get_dev_path(partition)
        mount(partition, f'{ROOT_MOUNTPOINT}/{mountpoint}')
        if not cfg.UEFI and (mountpoint == '/boot' or mountpoint.startswith('/boot/')):
            set_boot_disk(partition)


def configure_mirrorlist():
    title('Mirror list - https://wiki.archlinux.org/index.php/Mirrors')
    info('Updating mirror list.')

    import Reflector
    Reflector.main(['--cache-timeout', '0', '--save', '/etc/pacman.d/mirrorlist'] + MIRRORLIST_ARGS)

    if MIRRORLIST_MANUAL_EDIT:
        run_editor('/etc/pacman.d/mirrorlist')


def install_base_system():
    title('Base system')
    run_log(['pacman', '-Sy', '--noconfirm', '--needed', 'archlinux-keyring'])
    arch_pacstrap(
        cfg.LINUX_VERSION, f'{cfg.LINUX_VERSION}-headers', 'linux-firmware', 'base', 'base-devel', 'pacman-contrib', 'reflector',
        'bash-completion', 'zsh', 'zsh-completions', 'zsh-autosuggestions',
        'cryptsetup', 'device-mapper', 'dhcpcd', 'diffutils', 'e2fsprogs', 'inetutils', 'iwd', 'jfsutils',
        'less', 'logrotate', 'lvm2', 'man-db', 'man-pages', 'mdadm', 'nano',
        'python', 'perl', 'reiserfsprogs', 's-nail', 'sysfsutils', 'texinfo', 'usbutils', 'vim', 'which', 'xfsprogs',
        'iw', 'wireless_tools', 'wpa_supplicant', 'nftables', 'iptables-nft',

        'parted', 'btrfs-progs', 'f2fs-tools', 'gptfdisk', 'ntfs-3g', 'efibootmgr', 'dosfstools', 'exfat-utils', 'autofs', 'mtpfs', 'cdrtools', 'libisoburn',
        'zip', 'unzip', 'unrar', 'p7zip', 'zstd', 'lzop', 'cpio',
        'openssh', 'wget', 'sudo',
        'amd-ucode', 'intel-ucode', 'grub', 'os-prober', 'dmidecode',
    )

    run_log(['cp', '-fr', '-t', ROOT_MOUNTPOINT, *(f'{SCRIPTDIR}/root/{x}' for x in os.listdir(f'{SCRIPTDIR}/root') if x != 'home')])
    run_log(['cp', '-n', '/etc/zsh/zshrc', f'{ROOT_MOUNTPOINT}/etc/zsh/zshrc'])

    arch_chroot('\n'.join([
        'groupadd wheel',
        'systemctl enable paccache.timer',
        'systemctl enable nftables.service'
    ]))

    if not os.path.isdir(f'{ROOT_MOUNTPOINT}/etc/pacman.d/gnupg'):
        arch_chroot('\n'.join([
            'pacman -S --asdeps --noconfirm --needed haveged',
            'haveged -w 1024',
            'pacman-key --init',
            'pacman-key --populate archlinux',
            'pkill haveged',
        ]))

    arch_chroot('pacman -Sy')


def configure_fstab():
    info('Configuring fstab.')
    with open(f'{ROOT_MOUNTPOINT}/etc/fstab', 'a') as fd:
        run_log(['genfstab', '-U', ROOT_MOUNTPOINT], stdout=fd)
    if FSTAB_MANUAL_EDIT:
        run_editor(f'{ROOT_MOUNTPOINT}/etc/fstab')


def configure_timedate():
    info('Configuring date & time.')
    arch_chroot('\n'.join([
        f'ln -sf /usr/share/zoneinfo/{TIMEZONE} /etc/localtime',
        'hwclock --systohc --utc',
        'systemctl enable systemd-timesyncd.service',
    ]))

def configure_locale():
    info('Configuring locale.')
    arch_chroot('\n'.join([
        f'echo "KEYMAP={KEYMAP}" > /etc/vconsole.conf',
        f'echo "LANG={LOCALES[0]}.UTF-8" > /etc/locale.conf',
        f'sed -i -E \'s/#(({"|".join(LOCALES)}).UTF-8)/\\1/\' /etc/locale.gen',
        'locale-gen',
    ]))

def configure_mkinitcpio():
    if MKINITCPIO_MANUAL_EDIT:
        run_editor(f'{ROOT_MOUNTPOINT}/etc/mkinitcpio.conf')
    arch_chroot('mkinitcpio -P')

def configure_root_user():
    info('Configuring the root user.')
    arch_chroot('\n'.join([
        'passwd',
        'chsh -s /bin/zsh',
    ]))


def install_bootloader():
    if cfg.BOOTLOADER == 'grub':
        assert is_package_installed('grub', 'os-prober')
        info('Installing bootloader.')
        if cfg.UEFI:
            arch_chroot(f'grub-install --target=x86_64-efi --efi-directory={EFI_MOUNTPOINT} --bootloader-id=arch_grub --recheck')
        else:
            arch_chroot(f'grub-install --target=i386-pc --recheck --debug {BOOT_DISK}')
        arch_chroot('grub-mkconfig -o /boot/grub/grub.cfg')

    else:
        if is_package_installed('amd-ucode') or is_package_installed('intel-ucode'):
            warning('Could not enable microcode updates. You must do it manually. (https://wiki.archlinux.org/index.php/Microcode)')



run_log(['loadkeys', KEYMAP])
run_log(['timedatectl', 'set-ntp', 'true'])
run_log(['cp', '-rf', '-T', f'{SCRIPTDIR}/root/etc', '/etc'])

configure_partition_scheme()
mount_partitions()
configure_mirrorlist()
install_base_system()
configure_fstab()
configure_timedate()
configure_locale()
configure_mkinitcpio()
configure_root_user()
install_bootloader()

info('Copying installation scripts to root home directory.')
run_log(['cp', '-rf', '-t', f'{ROOT_MOUNTPOINT}/root', SCRIPTDIR])

info('Unmounting partitions. Please reboot the system without the live CD, then run the second script.')
run_log(['umount', '-R', ROOT_MOUNTPOINT])
