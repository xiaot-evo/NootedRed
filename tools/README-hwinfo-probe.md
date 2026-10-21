# HW-info probe

> Research tool retained from the archived `research/igpu-hwinfo-logic` branch; it is not part of the
> kext build.

`hwinfo_probe.c` opens the `IOAccelerator` user client (connection type 5) and calls selector `0x100`
to fetch the same 0x204-byte hardware-info blob that `_amdUbm_HWL_Init` consumes.

```sh
cc -O2 -o /tmp/hwinfo_probe tools/hwinfo_probe.c -framework IOKit -framework CoreFoundation
/tmp/hwinfo_probe
```

On a Renoir system this produced:

```text
+0x08 = 1 (chip revision/branch)
+0x20 = 8 (active CUs)
+0x88 = 1 (seCount)
+0x90 = 1 (shCount)
+0xa0 = 0x24000042 (GB_ADDR_CONFIG)
```

The blob is written to `/tmp/ubm_kernel_blob.bin` when the call succeeds. This is diagnostic only; it
does not patch anything.
