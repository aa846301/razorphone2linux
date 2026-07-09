# In-repository kernel source

Put a local SDM845 Linux kernel source tree at:

```text
kernel-source/linux
```

When this directory exists, CI and local setup use it instead of fetching
`KERNEL_REPO` from the network.

For reproducible builds, prefer making `kernel-source/linux` a Git checkout at
the pinned `KERNEL_COMMIT` from `config/kernel-source.env`. A plain source
snapshot without `.git` also works, but the build cannot verify that it matches
the pinned commit.

For source snapshots, include this marker:

```text
kernel-source/linux/.razer-kernel-commit
```

Its contents must be the pinned kernel commit hash.

When a snapshot is committed from Windows, executable bits may be normalized.
The setup step restores execute permissions from:

```text
kernel-source/linux/.razer-executable-files
```

This manifest is generated from executable build helper files in the pinned
kernel snapshot.
