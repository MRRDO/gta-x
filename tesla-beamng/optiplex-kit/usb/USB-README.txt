HOW THE USB IS SET UP (for the laptop session / Quentin)

Windows 10 installer USB, plus these additions (nothing on the USB is deleted or changed):
  \OptiPlexTools\                                   the tools folder (START-HERE.cmd, scripts\, installers\, car-mode\, beamng-settings\)
  \Find-Tools.cmd                                   for the Setup screen: Shift+F10, run it, it shows the README
  \sources\$OEM$\$1\OptiPlexTools\                  Windows Setup copies this to C:\OptiPlexTools during the install
  \sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd runs at the end of the install, so the folder opens at the first sign-in

What you will see when you boot the USB:
  1. The normal Windows 10 Setup. YOU choose the disk and what to delete: nothing here wipes a disk by itself.
  2. After the install and the first sign-in, File Explorer opens on C:\OptiPlexTools by itself.
  3. Double-click START-HERE.cmd.
If Windows is already installed and you boot the USB by accident, just close Setup: nothing has changed.
Back up anything you care about before installing Windows over an existing one.
