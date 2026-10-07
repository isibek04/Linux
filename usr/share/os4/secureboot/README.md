# os4 Secure Boot certificates

Public halves only. Nothing in this directory is secret; committing them is
what pins the trust root — a change to any of these files is a commit, the
same property the apt signing keys have.

| File | What it is | Where the private key lives |
|---|---|---|
| `ca.crt.pem` / `ca.crt.der` | The root CA, `CN=os4 Secure Boot CA 2026`, self-signed, 20 years. SHA-256 fingerprint `FA:B3:73:A4:DA:42:32:D7:F2:EF:DB:AD:52:4F:0B:AC:C2:95:8B:CA:D3:9B:3A:5E:38:92:BA:77:29:26:5E:43`. | PIV slot 9c of two YubiKeys (touch required per signature); age-encrypted backup in Proton Pass and iCloud. |
| `leaf.crt.pem` | The UKI signing certificate, `CN=os4 UKI signing 2026-10`, issued by the CA, expires 2027-10-07 — expiry is policy, not enforcement: UEFI/shim have no trusted clock and do not check it. | GitHub Actions repository secret `SB_LEAF_KEY`. |

Enrolling a machine, once, with physical presence — the DER ships in the
image at this path precisely so a deployed host has it on hand:

    mokutil --import /usr/share/os4/secureboot/ca.crt.der
    mokutil --trust-mok
    reboot    # MokManager asks the one-time password back and enrols

The second line is for the kernel, not for shim, and only the v4l2loopback
module needs it. Enrolling a certificate puts it in the kernel's `.platform`
keyring, which covers kexec images and not modules; module signatures are
checked against `.secondary_trusted_keys`, which the MOK certificates reach
only through `.machine`, and `.machine` is populated only when the
`MokListTrustedRT` variable `--trust-mok` sets is present. Skipping it costs
nothing at boot and leaves `modprobe v4l2loopback` failing with `Key was
rejected by service`. MokManager prompts for it separately during the same
reboot.

shim then trusts anything that chains to the CA, so UKIs are signed by the
leaf *with the chain embedded* — the `--addcert` is what lets shim walk from
the leaf up to the enrolled root:

    sbsign --key "${SB_LEAF_KEY}" --cert leaf.crt.pem --addcert ca.crt.pem ...

Rotating the leaf needs no machine ever touched again: issue a new
certificate from a YubiKey (or the Proton Pass backup), replace the GitHub
secret, commit the new certificate here. Rotation is not revocation, though —
a leaked leaf keeps booting what it signed until it is blacklisted per
machine (`mokutil` into MokListX) or the CA itself is replaced.
