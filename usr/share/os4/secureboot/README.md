# os4 Secure Boot certificates

Public halves only. Nothing in this directory is secret; committing them is
what pins the trust root — a change to any of these files is a commit, the
same property the apt signing keys have.

| File | What it is | Where the private key lives |
|---|---|---|
| `ca.crt.pem` / `ca.crt.der` | The root CA, `CN=os4 Secure Boot CA 2026`, self-signed, 20 years. SHA-256 fingerprint `FA:B3:73:A4:DA:42:32:D7:F2:EF:DB:AD:52:4F:0B:AC:C2:95:8B:CA:D3:9B:3A:5E:38:92:BA:77:29:26:5E:43`. | PIV slot 9c of two YubiKeys (touch required per signature); age-encrypted backup in Proton Pass and iCloud. |
| `leaf.crt.pem` | The UKI signing certificate, `CN=os4 UKI signing 2026`, issued by the CA, expires 2027-09-29 — expiry is policy, not enforcement: UEFI/shim have no trusted clock and do not check it. | Forgejo repository secret. |

Enrolling a machine, once, with physical presence — the DER ships in the
image at this path precisely so a deployed host has it on hand:

    mokutil --import /usr/share/os4/secureboot/ca.crt.der
    reboot    # MokManager asks the one-time password back and enrols

shim then trusts anything that chains to the CA, so UKIs are signed by the
leaf *with the chain embedded* — the `--addcert` is what lets shim walk from
the leaf up to the enrolled root:

    sbsign --key "${SB_LEAF_KEY}" --cert leaf.crt.pem --addcert ca.crt.pem ...

Rotating the leaf needs no machine ever touched again: issue a new
certificate from a YubiKey (or the Proton Pass backup), replace the Forgejo
secret, commit the new certificate here. Rotation is not revocation, though —
a leaked leaf keeps booting what it signed until it is blacklisted per
machine (`mokutil` into MokListX) or the CA itself is replaced.
