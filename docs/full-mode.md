# Full mode: step by step

This page is handy to open on a phone, since the Mac will be shut down for a while.

Full mode lets yabai manage spaces: instant switching, creating spaces on the fly, moving windows
between them, and transparency. It requires partially disabling macOS's System Integrity Protection
(SIP) once, which can only be done from Recovery.

Run in a terminal:

```bash
rice sa
```

It checks what is already done and tells you what to do next. The same steps are listed below.

## Apple Silicon (M1, M2, M3, M4…)

1.  menu → **Shut Down**. Wait for the screen to go dark.
2. Press and **hold** the power button (the Touch ID button) until
   "Loading startup options" appears. Release it.
3. Choose **Options** → **Continue**. If asked, select your user and enter the password.
4. In the menu bar at the top: **Utilities → Terminal**.
5. Enter this command and press Enter:

   ```
   csrutil enable --without fs --without debug --without nvram
   ```

   It asks for confirmation (`y`), a username and a password; this is expected.
6. Enter the second command:

   ```
   nvram boot-args=-arm64e_preview_abi
   ```

   If it returns an error, that is fine: the installer sets it after the reboot.
7.  menu → **Restart**.

After you log in, **Terminal opens on its own** and finishes the setup: it asks for your macOS
password (to write the sudoers entry) and, if step 6 failed, for one more reboot.

## Intel

1.  menu → **Restart**, then immediately hold **⌘ + R** until the Apple logo appears.
2. **Utilities → Terminal**.
3. Command:

   ```
   csrutil disable --with kext --with dtrace --with nvram --with basesystem
   ```

4.  menu → **Restart**. Terminal opens on its own.

## Verifying

```bash
rice doctor
```

The last line should read "full mode (scripting addition)".

## Reverting

`rice uninstall` removes the scripting addition, the sudoers entry and the boot-arg. SIP is
re-enabled from Recovery (steps 1–4 above) with:

```
csrutil enable
```

## Troubleshooting

- **Space switching stopped working after a macOS update.** yabai has not caught up with the new
  version yet. Run `rice update` to rebuild yabai. If that does not help, wait for a fork update;
  basic features keep working in the meantime.
- **Terminal did not open after the reboot.** Run `rice sa` manually.
- **`csrutil` says authorization is required.** Select an administrator user and enter their password.
