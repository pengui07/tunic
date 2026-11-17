# Tunic

Install Linux over or alongside an existing Windows install, straight from Windows,
without requiring to boot from external media like a flash drive or making BIOS configuration changes.

![Alt text](https://i.imgur.com/VOhRiGh.png) <!-- primary form -->
![Alt text](https://i.imgur.com/YNNt4HZ.png) <!-- dual boot form -->
![Alt text](https://i.imgur.com/9P8auhO.png) <!-- progress -->

### What Tunic Does

* Validates your system meets Tunic requirements (Windows 10/11 64-bit, UEFI/GPT).
* Asks setup questions at the beginning.
* Offers full disk overwrite, dual boot alongside Windows, or custom/advanced install.
* If dual boot, shrinks the `C:` volume to make space for Linux (suspending BitLocker for 1 reboot if enabled).
* Provides tools to assist with freeing up space for Linux.
* Disables Windows fast start.
* **Fedora 45 & Local ISOs**: Drop any Fedora 45 (Workstation Live, KDE Plasma Desktop Live, Server/Netinstall) or Ubuntu/Linux Mint `.iso` into the project folder, `iso/`, or `Downloads/`, or drag-and-drop / browse for it in the UI.
* Stages Fedora ISOs onto a temporary FAT32 partition (`TUNIC_BOOT`) and installs Fedora's own signed `BOOTX64.EFI` (`shimx64.efi`) + `grubx64.efi` from the ISO for UEFI Secure Boot compatibility on Windows 11.
* Calculates Linux equivalent values for your Windows locale and user account (used for Ubuntu/Mint preseed and Fedora Server/Netinstall Kickstart; Fedora Live ISOs use Fedora's interactive setup).
* Reboots into the Linux installer without needing a USB flash drive or BIOS changes.

See the [TODO](doc/TODO.md) for ideas for future versions.

### Requirements

* Windows 10 or Windows 11, 64 bit
* Single drive hosting the C: volume (GPT / UEFI)
* At least 4 GB RAM (6 GB+ recommended for Load-to-RAM mode)
* At least 15 GB of free disk space (20 GB+ for Fedora Live dual boot)
* Administrator user permissions
* AC Wall Power

### Fedora 45 Drop-In Quick Start (Windows 11)

1. Drop your Fedora 45 `.iso` (for example `Fedora-Workstation-Live-x86_64-45-1.4.iso`) into `iso/`, the Tunic folder, or your `Downloads` folder (or use **Browse ISO...** / drag-and-drop onto the window).
2. Double-click `run-tunic.bat` (or run `.\tunic.ps1` from an Administrator PowerShell prompt).
3. Choose **Install Linux alongside Windows (Dual Boot)** (recommended) or **Erase entire disk / Custom**, verify your Fedora ISO is selected, accept the disclaimer, and click **Continue**.
4. Tunic shrinks `C:` (if needed), creates a temporary FAT32 `TUNIC_BOOT` partition, extracts the Fedora ISO there, installs Fedora's signed UEFI Secure Boot shim + GRUB config, adds a `Tunic Fedora Installer` boot entry, and reboots into Fedora 45.
5. After Fedora installation completes, you can run `.\tunic.ps1 uninstall` (or click **Cleanup / Uninstall**) from Windows to remove the temporary `TUNIC_BOOT` partition and Tunic boot entry.

### Limitations

* Tunic supports Fedora ISOs (Live and Server/Netinstall) as well as Ubuntu and Linux Mint ISOs.
* Error handling needs improvement.
* Due to the nature of what Tunic does, it may show up as a false positive on some malware scans.

### More information

See the [doc](doc) directory for more information.

## Getting Started

### Preparation

* Backup your data!

Before you start, make sure to backup up an image of your entire disk(s).
Tunic does not assist with full disk backup.
Read disclaimer for more information.

No, really.  Backup your data.

* Close all other running applications.

### Usage

1. Download and run the
[latest executable file](https://github.com/mikeslattery/tunic/releases/latest/download/tunic.exe)
from releases.
1. Answer questions.
1. Let it run.  It may take a long time.
1. Enjoy your new Linux OS!

If you were able to install Linux with Tunic, please
add a comment to [Success Stories](https://github.com/mikeslattery/tunic/issues/12),
or send a message [to the author](https://www.reddit.com/message/compose/?to=funbike).

See the [FAQ](doc/faq.md) if you need further help.

## Legal Stuff

### License

Copyright (c) 2020 Michael Slattery.  See commit history for list of other authors.

Distributed under the [GNU General Public License, version 3](https://www.gnu.org/licenses/gpl-3.0.html).

### Disclaimer

This software could inadvertantly and permanently destroy all data, leave a computer unbootable,
or otherwise leave a computer in an undesirable state.
This software comes as-is with absolutely no warranty.
Read sections [15, 16, and 17](https://www.gnu.org/licenses/gpl-3.0.html#section15)
of the GNU GPL version 3 license for more information.

