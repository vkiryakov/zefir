# Test keys of `security.jwt`

Every key in this directory is public and exists only for the tests of
`security.jwt`: never sign or verify anything real with it. `../keys.zig` embeds
each file and says what it holds.

The files were made in this directory with OpenSSL 3.6 and ssh-keygen, by
these commands:

```sh
# Ed25519: PKCS#8 and SPKI, in PEM and in DER.
openssl genpkey -algorithm ed25519 -out ed25519.pk8.pem
openssl pkey -in ed25519.pk8.pem -pubout -out ed25519.pub.pem
openssl pkey -in ed25519.pk8.pem -outform DER -out ed25519.pk8.der
openssl pkey -in ed25519.pk8.pem -pubout -outform DER -out ed25519.pub.der

# P-256: SEC1 (the PEM has the EC PARAMETERS block that ecparam writes
# first), PKCS#8, and SPKI with an uncompressed and a compressed point, in
# PEM and in DER.
openssl ecparam -name prime256v1 -genkey -out p256.sec1.pem
openssl pkcs8 -topk8 -nocrypt -in p256.sec1.pem -out p256.pk8.pem
openssl ec -in p256.sec1.pem -pubout -out p256.pub.pem
openssl ec -in p256.sec1.pem -pubout -conv_form compressed -out p256.pub.compressed.pem
openssl ec -in p256.sec1.pem -outform DER -out p256.sec1.der
openssl pkcs8 -topk8 -nocrypt -in p256.sec1.pem -outform DER -out p256.pk8.der
openssl ec -in p256.sec1.pem -pubout -outform DER -out p256.pub.der
openssl ec -in p256.sec1.pem -pubout -conv_form compressed -outform DER -out p256.pub.compressed.der

# P-384: the same.
openssl ecparam -name secp384r1 -genkey -out p384.sec1.pem
openssl pkcs8 -topk8 -nocrypt -in p384.sec1.pem -out p384.pk8.pem
openssl ec -in p384.sec1.pem -pubout -out p384.pub.pem
openssl ec -in p384.sec1.pem -pubout -conv_form compressed -out p384.pub.compressed.pem
openssl ec -in p384.sec1.pem -outform DER -out p384.sec1.der
openssl pkcs8 -topk8 -nocrypt -in p384.sec1.pem -outform DER -out p384.pk8.der
openssl ec -in p384.sec1.pem -pubout -outform DER -out p384.pub.der
openssl ec -in p384.sec1.pem -pubout -conv_form compressed -outform DER -out p384.pub.compressed.der

# Keys that security.jwt refuses with UnsupportedKey: RSA in every form.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out rsa.pk8.pem
openssl pkey -in rsa.pk8.pem -pubout -out rsa.pub.pem
openssl pkey -in rsa.pk8.pem -outform DER -out rsa.pk8.der
openssl pkey -in rsa.pk8.pem -pubout -outform DER -out rsa.pub.der
openssl rsa -in rsa.pk8.pem -traditional -out rsa.pkcs1.pem
openssl rsa -in rsa.pk8.pem -RSAPublicKey_out -out rsa.pkcs1.pub.pem

# P-521 and Ed448.
openssl ecparam -name secp521r1 -genkey -noout -out p521.sec1.pem
openssl pkcs8 -topk8 -nocrypt -in p521.sec1.pem -out p521.pk8.pem
openssl ec -in p521.sec1.pem -pubout -out p521.pub.pem
openssl genpkey -algorithm ed448 -out ed448.pk8.pem
openssl pkey -in ed448.pk8.pem -pubout -out ed448.pub.pem

# Encrypted keys: PKCS#8, and SEC1 with the Proc-Type header of OpenSSL.
openssl pkcs8 -topk8 -in ed25519.pk8.pem -passout pass:test -out ed25519.encrypted.pem
openssl ec -in p256.sec1.pem -aes128 -passout pass:test -out p256.sec1.encrypted.pem

# A certificate and an OpenSSH key.
openssl req -x509 -key p256.pk8.pem -subj /CN=test -days 1 -out p256.cert.pem
ssh-keygen -q -t ed25519 -N '' -C test -f openssh.key
rm openssh.key.pub
```
