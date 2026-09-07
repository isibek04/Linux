# The UDS tunnel's missing intermediate

`GEANT-TLS-RSA-1.pem` is the public intermediate CA certificate
`CN=GEANT TLS RSA 1, O=Hellenic Academic and Research Institutions CA, C=GR`,
issued by `HARICA TLS RSA Root CA 2021`, valid 2025-01-03 to 2039-12-31,
SHA-256 fingerprint
`5B:67:8D:C4:40:95:A5:28:95:B6:3B:31:F2:72:27:F4:B3:6C:3E:34:74:91:BF:2B:FA:69:18:37:A5:FB:8C:79`.
Nothing here is secret, and nothing here is a new trust root: the HARICA root
that signed it is already in `ca-certificates`, which is how `build/udsclient.sh`
checks this file at build time (`openssl verify` against the system store).

It exists because the university's UDS tunnel server, `udstunel.mondragon.edu`
port 11443, serves its leaf certificate without the intermediate that signed
it. The broker on `uds.mondragon.edu:443` sends the full chain; the tunnel
does not. Browsers and Windows fetch a missing intermediate from the leaf's
AIA URL on the fly, so the omission is invisible everywhere except a Python
`ssl` client, which does not — and the UDS client is one, so every RDP session
died at the tunnel handshake with `CERTIFICATE_VERIFY_FAILED: unable to get
local issuer certificate`.

The client reads `CERTIFICATE_BUNDLE_PATH` and adds whatever that file holds
to the default trust store, for both its REST calls to the broker and the
tunnel socket. `build/udsclient.sh` points the `.desktop` file's `Exec` line
at this file, so the fix is scoped to the UDS client rather than added to the
system store. It is a workaround for the university's misconfiguration; if the
tunnel ever serves its chain, the file becomes redundant and harmless.

Fetched from the leaf's own AIA pointer, `http://crt.harica.gr/HARICA-GEANT-TLS-R1.cer`,
and converted with `openssl x509 -inform DER -outform PEM`. HTTP is fine for
that: what authenticates the file is its signature by the root, not the wire.
