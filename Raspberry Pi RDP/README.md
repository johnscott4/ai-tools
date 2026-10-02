# Remote Desktop (RDP) on a headless Raspberry Pi

Gives a Pi imaged with `../Raspberry Pi Imaging/` a full desktop you open from
Windows with the built-in client (`mstsc /v:<host>.local`). Verified 2026-10-02
on a **Pi 5, Raspberry Pi OS Trixie Lite 64-bit (2026-09-15)**; the same recipe
has run on a Pi 4 (Trixie desktop) since 2026-08-30.

## Do it

```bash
# from Git Bash on Windows; LF endings matter
tr -d '\r' < setup_rdp.sh | ssh -i ~/.ssh/id_rsa user@host.local 'cat > setup_rdp.sh && bash setup_rdp.sh'
```

About 5 minutes on a Pi 5 (≈350 packages on Lite). It ends by printing that
port 3389 is listening.

## What it does, and why each part is needed

| Piece | Why |
|---|---|
| `rpd-x-core rpd-x-extras rpd-theme rpd-preferences rpd-wallpaper-trixie` | The Raspberry Pi desktop, **X11** flavour. The default Trixie desktop is Wayland (labwc); **xrdp cannot drive Wayland**. |
| `pixtrix-icons pixtrix-theme gtk2-engines-pixflat xsettingsd` + fonts, **with Recommends** | The desktop is configured for the PiXtrix theme, but these are only *Recommends*. Install with `--no-install-recommends` and Openbox logs "Unable to load the theme 'PiXtrix'", falls back to Clearlooks, and **every icon in the top-left panel and on the desktop renders wrong**. |
| `xrdp xorgxrdp` | RDP server + the Xorg backend it renders into. |
| `~/.xsession` → `XDG_SESSION_TYPE=x11`, `GDK_BACKEND=x11`, `exec startx-rpd` | The session xrdp launches for that user. Without it you get a black screen or an immediate disconnect. Per user: repeat for each account that should log in over RDP. |
| `adduser xrdp ssl-cert` | xrdp reads its TLS key from `/etc/ssl/private`. |
| polkit rule `49-packagekit-sudo.rules` | Otherwise **every RDP login** pops "Authentication is required to refresh the system repositories" from the panel updater. Scoped to PackageKit actions for the `sudo` group only. |

## Verify without touching anyone's screen

From WSL (Ubuntu), a headless RDP client logs in and screenshots the session:

```bash
sudo apt-get install -y freerdp3-x11 xvfb imagemagick
Xvfb :55 -screen 0 1280x800x24 & sleep 1
DISPLAY=:55 timeout 60 xfreerdp3 /v:<ip> /u:<user> /p:<password> /cert:ignore /size:1280x800 &
sleep 30; DISPLAY=:55 import -window root /mnt/c/Users/<you>/rdp.png
```

Look at the PNG. Expect the Pi desktop with the **raspberry menu, file-manager
and terminal icons top-left and Wi-Fi/Bluetooth/clock top-right**. Blank or
generic icons there = the PiXtrix theme is missing (see above). WSL in NAT mode
reaches the LAN by IP; `.local` names may not resolve inside WSL, so use the IP.

**Then end the test session** — otherwise the owner's first real login
*reattaches to it* (at the test client's 1280×800, resized on the fly):

```bash
ssh user@host 'sudo pkill -x lxsession; sudo pkill -x Xorg'
```

Also grep the session log for theme failures:
`grep -iE "unable to load the theme|not present in theme" ~/.cache/lxsession/rpd-x/run.log`
— expect nothing.

## Gotchas

- **"I reconnected and got a login screen."** That is xrdp's own login page,
  shown whenever the RDP client does not send credentials that work on *this*
  Pi. It is not a broken session: log in there and xrdp **reattaches the
  existing session** (sesman log: `++ reconnected session`). The usual cause
  is the client reusing credentials saved for a *different* Pi — on
  2026-10-02 `mstsc` sent user `joan` (from `logger.local`) to `logger2`,
  where no such user exists (`Can't get UID for user joan`). Fix on the
  Windows client, once per host:

  ```bat
  cmdkey /generic:TERMSRV/logger2.local /user:pi /pass:<password>
  ```

  or save a per-host `.rdp` file containing `full address:s:logger2.local`
  and `username:s:pi`, and tick "Remember me" on first connect. Diagnose with
  `sudo grep "Performing login" /var/log/xrdp.log` on the Pi: it names the
  user the client actually sent.

  **What the owner wants instead — and what was done:** make every Pi accept
  the one user the client already sends, so RDP goes straight to the desktop
  with no client change. Create that user on the new Pi with the *same
  password* by copying the hash from a Pi that already has it (the plaintext
  is never seen):

  ```bash
  ssh joan@logger.local 'sudo getent shadow joan | cut -d: -f2' |
    ssh pi@newpi.local 'read -r H; sudo useradd -m -s /bin/bash joan;
      printf "%s\n" "joan:$H" | sudo chpasswd -e;
      sudo usermod -aG adm,dialout,sudo,audio,video,plugdev,users,input,render,netdev,spi,i2c,gpio joan;
      echo "joan ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_joan-nopasswd;
      sudo install -o joan -g joan -m 775 ~/.xsession /home/joan/.xsession'
  ```

  Better still: **image new Pis with that username from the start**
  (`USERNAME` in `firstrun.sh`), then this never comes up.

- **Default password warning.** With user `pi` and its default password the
  desktop shows "SSH is enabled and the default password … has not been
  changed" on each login. Correct, not a fault: change the password (`passwd`).
- **One session per user.** If the user is already logged in on the Pi's own
  HDMI desktop, xrdp cannot start a second session for them; log out locally.
- **Killing a stuck session over SSH**: use `sudo pkill -x Xorg` /
  `pkill -x lxsession` (exact process name). **Never** `pkill -f xrdp` inside
  the same `ssh '…'` command: the pattern matches that SSH command itself and
  kills your own shell midway (it did, 2026-10-02).
- **Certificate prompt** in `mstsc` on first connect: xrdp uses a self-signed
  certificate; accept it once.
