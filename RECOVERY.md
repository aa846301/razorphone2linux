# Known-working recovery baseline

The pre-7.1 WiFi and Helix state is preserved in two places:

- Git tag: `razer-wifi-helix-6.16-baseline-20260622`
- Flashable archive:
  `C:\repo\razorphone2linux-recovery\known-working-6.16-20260622`

The archive contains:

- `boot.img` — matching Linux `6.16.0-rc2-sdm845` boot image
- `rootfs-sparse.img` — Ubuntu rootfs with working WiFi and Helix
- `vbmeta_disabled.img` — matching verified-boot helper
- `efs-backup-19700120-022620.tar.gz` — modem/EFS safety backup
- `SHA256SUMS.txt` — integrity hashes
- `RESTORE.txt` — exact A/B restore command

Verify before restoring:

```powershell
cd C:\repo\razorphone2linux-recovery\known-working-6.16-20260622
Get-Content SHA256SUMS.txt
Get-FileHash -Algorithm SHA256 boot.img,rootfs-sparse.img,vbmeta_disabled.img,efs-backup-19700120-022620.tar.gz
```

Restore the tracked project state without touching the current branch:

```powershell
git switch --detach razer-wifi-helix-6.16-baseline-20260622
```

Factory and reference inputs removed from the working repository are archived
under:

`C:\repo\razorphone2linux-archive\reference-inputs-20260622`
