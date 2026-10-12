module prtvpn/daemon

go 1.21

require (
	golang.org/x/sys v0.18.0
	golang.zx2c4.com/wireguard v0.0.0-20210905140043-2ef39d47540c
)

require (
	github.com/andybalholm/brotli v1.0.6 // indirect
	github.com/cloudflare/circl v1.3.7 // indirect
	github.com/klauspost/compress v1.17.4 // indirect
	github.com/refraction-networking/utls v1.6.6 // indirect
	golang.org/x/crypto v0.21.0 // indirect
	golang.org/x/net v0.23.0 // indirect
)

replace golang.zx2c4.com/wireguard => github.com/ProtonVPN/wireguard-go v0.0.0-20241011082357-7f0629f3a49f
