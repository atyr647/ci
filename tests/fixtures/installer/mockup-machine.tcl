version 1
machine {
    efi 1  secureboot 0  ram 34359738368  laptop 0  battery {}
    cpu {vendor amd model "AMD Ryzen 7 7800X3D"}
    net {online 1 kind wifi name Hearth}
    timezone Europe/London
    locale en_US.UTF-8  keymap us
}
disks {
    {dev /dev/nvme0n1  model "Samsung 990 PRO"  size 1000618097152  bus nvme
     removable 0  install_media 0  table gpt
     parts {
        {dev /dev/nvme0n1p1 start 1048576 size 1000000000 fs vfat label {} type esp used 31457280 os {}}
        {dev /dev/nvme0n1p2 start 1001048576 size 16000000 fs {} label {} type msr used 0 os {}}
        {dev /dev/nvme0n1p3 start 1017048576 size 520000000000 fs ntfs label {} type data used 412000000000
         os {name "Windows 11" kind windows}
         resize {min 440000000000 max 959600000000 safe 1 why {}}}
     }
     free {{start 521017048576 size 479600000000}}
     os {{name "Windows 11" kind windows part /dev/nvme0n1p3}}
     alongside {possible 1 part /dev/nvme0n1p3 esp /dev/nvme0n1p1 boot esp why {}}}
    {dev /dev/sda  model "WD Blue"  size 2000398934016  bus sata
     removable 0  install_media 0  table gpt
     parts {
        {dev /dev/sda1 start 1048576 size 2000397000000 fs ext4 label Games type data used 1300000000000 os {}}
     }
     free {}
     os {}}
    {dev /dev/sdb  model "Ribbon live USB"  size 32010928128  bus usb
     removable 1  install_media 1  table gpt  parts {}  free {}  os {}}
}
drivers {
    {id gpu0 category Graphics device "NVIDIA GeForce RTX 4070" ids {10de:2786}
     driver "NVIDIA, proprietary (latest)" status install
     choices {{latest "Latest"} {580 "580 series"} {470 "470 series"} {nouveau "Nouveau"}} default latest}
    {id wifi0 category Wi-Fi device "Broadcom BCM4360" ids {14e4:43a0} driver broadcom-wl status install choices {} default {}}
    {id cpu0 category Processor device "AMD Ryzen 7 7800X3D" ids {} driver "AMD microcode updates" status install choices {} default {}}
    {id audio0 category Audio device "Intel Smart Sound" ids {8086:51c8} driver "Sound Open Firmware" status install choices {} default {}}
    {id pad0 category Controller device "Xbox Wireless Controller" ids {045e:0b13} driver xpadneo status install choices {} default {}}
    {id fp0 category "Fingerprint reader" device "Goodix 27c6:538d" ids {27c6:538d} driver fprintd status install choices {} default {}}
    {id bt0 category Bluetooth device "Intel AX210" ids {8087:0032} driver "in the kernel" status builtin choices {} default {}}
}
