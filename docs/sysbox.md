# `--sysbox`: isolating the nested Docker daemon

`--privileged` (`run.sh`'s default) is a blunt instrument: it disables essentially every
container security boundary Docker offers, not just the ones the nested `dockerd`
actually needs. A process that escapes the nested `dockerd` inside a `--privileged`
container has a well-trodden path to full root on the host.

`run.sh --sysbox` uses the [sysbox-runc](https://github.com/nestybox/sysbox) OCI runtime
instead. Sysbox gives the container real user-namespace isolation - root inside the
container maps to an unprivileged UID on the host - while still letting the nested
`dockerd` (and other things that normally demand `--privileged`, like systemd) run
unmodified. `run.sh` only *selects* the runtime (`--runtime=sysbox-runc`); it doesn't
install it, and refuses to start if `docker info` doesn't list `sysbox-runc`.

Combining it with `--allow-container` is harmless but pointless: that flag skips the
nested `dockerd`, so there's nothing left for sysbox to isolate.

## Installing sysbox on the host

One-time, per-host setup. Docker must be a native install (not the `docker` snap) with
systemd as the host's process manager.

### Ubuntu / Debian

Sysbox publishes an official `.deb`:

```sh
# Check https://github.com/nestybox/sysbox/releases for the current version/checksum first.
wget https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb
sha256sum sysbox-ce_0.7.1.linux_amd64.deb   # compare against the checksum on the release page

docker rm -f $(docker ps -aq)   # recommended: the installer may restart Docker
sudo apt-get install jq         # used by the installer
sudo apt-get install ./sysbox-ce_0.7.1.linux_amd64.deb

systemctl status sysbox         # confirm sysbox-mgr/sysbox-fs/sysbox-runc are up
```

The package registers `sysbox-runc` in `/etc/docker/daemon.json` and enables/starts the
`sysbox` systemd unit for you. Kernel >= 5.19 needs nothing extra; on older kernels the
installer may also need `shiftfs` - see sysbox's
[install guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md)
if it complains.

### Arch Linux

No official package (Arch isn't in sysbox's supported-distro list), but a community AUR
package tracks upstream releases:

```sh
yay -S sysbox-ce-bin   # or: paru -S sysbox-ce-bin
```

The AUR package only installs the binaries and systemd units; you still have to wire it
up to Docker yourself. Add the runtime to `/etc/docker/daemon.json` (merge with any
existing content rather than overwriting it), then restart both services:

```json
{
  "runtimes": {
    "sysbox-runc": {
      "path": "/usr/bin/sysbox-runc",
      "runtimeArgs": ["--no-kernel-check"]
    }
  }
}
```

```sh
sudo systemctl enable --now sysbox
sudo systemctl restart docker
```

`--no-kernel-check` is there because Arch's rolling kernel isn't one sysbox recognizes as
pre-validated - it behaves the same as the supported distros as long as the kernel is
reasonably recent (>= 5.19 needs no `shiftfs`). Since Arch isn't officially supported,
treat `--sysbox` there as best-effort: verify it with `run.sh --sysbox bash` before
relying on it.
