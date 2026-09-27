# Demo root CA

`demo-root-ca.pem` is a self-signed **public** root certificate that stands in for the enterprise CA
bundle in the demo (D3 §6.3, DL-13). The company base images in `docker/base/` import it into the OS
trust store and into the JVM `cacerts`, exactly as they will import the real bundle.

| Property | Value |
|---|---|
| Subject / issuer | `CN=Demo Root CA` |
| Key | RSA 4096, SHA-256 signature |
| Validity | 2026-09-27 to 2036-09-24 (10 years) |
| Extensions | `basicConstraints=critical,CA:TRUE`, `keyUsage=critical,keyCertSign,cRLSign` |
| SHA-256 fingerprint | `5F:3C:85:36:6E:23:6A:98:D4:0C:63:17:68:80:2F:52:0C:97:BF:FD:37:10:DD:A8:28:11:DB:69:A1:C2:F0:AB` |
| Bundle version (image label `com.example.ca-bundle`) | `demo-2026-09` |

## No private key exists

The key was generated in a temporary directory outside the repository and destroyed straight after
the certificate was written. Nothing can ever be signed by this root, so trusting it grants nothing.
It only proves that the import mechanism works. **Never commit a private key here** (secret scanning
and review both check for it).

A consequence: no leaf certificate can be issued from this root. The TLS test service that D3 §8
mentions, which would present a leaf signed by the demo root, is therefore not part of the demo. If
it is wanted later, the test should create a throwaway CA for each run instead of reusing this one.

## Who consumes it

| Consumer | How |
|---|---|
| `docker/base/jre21/Dockerfile` | build context = this directory; every certificate in the file is imported into `/usr/local/share/ca-certificates/` (then `update-ca-certificates`) and into `$JAVA_HOME/lib/security/cacerts` (first certificate under the alias `demo-root-ca`); verified with `keytool -list` at build time |
| `docker/base/ci-build/Dockerfile` | the same steps, so Gradle, `curl`, `git` and the container CLIs in the build image trust it |
| `deephaven-server/docker/Dockerfile` | imports it into the upstream image's own JVM trust store (D3 §6.10); owned by the app workstream |

## Rotation (D3 §6.3, Figure 3)

1. Put the new root into this file **next to** the old one: the Dockerfiles import every certificate
   in the file, so both are trusted during the overlap window.
2. Bump `CA_BUNDLE_VERSION` (the `com.example.ca-bundle` label) in the `base-image.yml` build
   arguments, or in the Dockerfile defaults.
3. `base-image.yml` rebuilds `jre21` and `ci-build` with a new `<yyyymmdd>-<n>` tag. The bump PR moves
   every app `FROM` line to it, and the apps are rebuilt and released as a patch line.
4. Once every environment runs images labelled with the new bundle version, remove the old root and
   repeat the cycle once.

To regenerate a demo root (for example when this one nears expiry), keep the key out of the
repository and destroy it:

```bash
keydir=$(mktemp -d)
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "$keydir/demo-root-ca.key" -out test-infra/ca/demo-root-ca.pem \
  -subj "/CN=Demo Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"
shred -u "$keydir/demo-root-ca.key" && rmdir "$keydir"
openssl x509 -in test-infra/ca/demo-root-ca.pem -noout -subject -dates -fingerprint -sha256
```

In the enterprise, the bundle is not kept in git. `base-image.yml` downloads
`ca-bundle/<version>/<company>-ca-bundle.pem` from the JFrog generic repository into a directory and
passes that directory as the build context (see `docker/base/README.md`).
