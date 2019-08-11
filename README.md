# Kali linux for ESPRESSObin
A Kali Linux build for Marvell ESPRESSObin, using the armbian kernel and firmware as base. 

## Prerequisites
* ESPRESSObin
* MicroSD card (at least 4Gb)

## Installation
This build requires the latest u-boot, the same used in armbian. For more detail and obtain the latest u-boot, please [visit the armbian page](https://www.armbian.com/espressobin/).

Installed the right version of u-boot, [download the compressed Kali image](https://github.com/MrSuicideParrot/espressobin-kali/releases/latest).

You now need to flash the image on a MicroSD card, you need at least a 4Gb one. 

To flash on the MicroSD card you could use [etcher](https://www.balena.io/etcher/) or simply the `dd` command.
### With dd:
```
# unxz kali-linux-espressobin.img.xz
# dd bs=4M if=kali-linux-espressobin.img of=/dev/mmcblk0 status=progress conv=fsync
```

And now it's all done, you simple need to insert the MicroSD card on your ESPRESSObin and don't be naughtier.

## Quick start
You could use ssh or the serial console to connect to the board. 

The default username is `root` and the default password is `toor`. 

If you want to connect to the board by ssh, you need to use the *wan* interface because is the only interface configured to request an IP from a  dhcp server. 
> The wan interface is the one nearest the USB 3.0 port (blue usb port).

## Features
* Automatic resize of root file system
* Docker support

## Limitations

Great parts of the limitations of this board is the Topaz Networking Switch. The driver offloads the packets for the physical switch if you enable a bridge between two ports. Because of this, you are unable to intercept packets.  

I also try to bypass this situation creating a bridge for each interface and connected them with a veth, but I didn't succeed either.

### Notes:
* This image was only tested on ESPRESSObin v7, but in teory it should work in other versions.
