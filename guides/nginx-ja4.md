# JA4 behind nginx

[JA4] fingerprints the TLS [ClientHello], the first message of a TLS
handshake: which TLS version, ciphers, extensions and [ALPN] protocols (such
as HTTP/2) a client offers. HTTP libraries, headless browsers and real
browsers produce different fingerprints, and changing it takes more than
changing a header. A scraper sending Chrome's user agent from Python's TLS
stack keeps Python's JA4.

The application never sees the ClientHello: the TLS terminator in front of it
does. Limen therefore expects the terminator to compute the fingerprint and
pass it in a request header, `x-ja4` by default.

## What the terminator must do

1. Compute the JA4 fingerprint of each connection. Stock nginx does not; you
   need nginx built with a JA4 module, such as FoxIO's [ja4-nginx-module],
   which patches nginx to capture the ClientHello and exposes the fingerprint
   as `$http_ssl_ja4`. Other terminators have their own plugins; HAProxy and
   Envoy setups work the same way.
2. Send it upstream in a header, **overwriting** anything the client sent.
3. Send the client address in [`X-Forwarded-For`][X-Forwarded-For]
   (appending) and the scheme in `X-Forwarded-Proto`.

With nginx and FoxIO's module (other modules name the variable differently):

```nginx
location / {
    proxy_pass http://phoenix;

    # Overwrite, never append: the client must not be able to choose it.
    proxy_set_header X-JA4 $http_ssl_ja4;

    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Host $host;

    # LiveView and channels.
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

## What Limen must know

```elixir
config :my_app, Limen,
  trusted_proxies: ["10.0.0.5"],  # the nginx hosts
  client_ip_header: "x-forwarded-for",
  ja4_header: "x-ja4"
```

Limen only reads the JA4 header when the connection comes from a trusted
proxy. From anyone else it is ignored and the decision's evidence records
`ja4: :untrusted_peer`, so a client connecting directly cannot claim a
fingerprint. Malformed values are ignored too (`ja4: :malformed`).

Only well-formed JA4 fingerprints are accepted, such as
`t13d1516h2_8daaf6152771_02713d6af862`. Raw or original-order variants are
not.

## Check it works

Request a page through nginx and look at the decision:

```elixir
Limen.decision(conn).identity.ja4
```

or in the explanation of any sampled decision, whose identity lines include
`ja4: t13d...`. The LiveDashboard page lists the fingerprints with the most
clients (prefixes) in the current minute.

## Using fingerprints

JA4 is part of the client identity: challenge tokens, pass cookies and socket
tokens are bound to it, so a pass solved in a browser cannot be replayed from
a script. In policies, `signal(:ja4)` works with lists and limits:

```elixir
deny :known_bad_ja4, when: signal(:ja4) in list(:bad_ja4), ban: 3_600
limit :per_fingerprint, key: :ja4, rate: 200, per: :second, burst: 400
score :fingerprint_burst, 30, when: rate(:ja4, per: :second) > 100
```

Popular browsers share fingerprints across millions of users, so treat a
fingerprint on its own as a weak signal and a known-bad fingerprint as a
strong one. Keep `:bad_ja4` current with `Limen.Lists.put/3` from a periodic
job; Limen does not ship a list.

## Licensing

JA4 (the TLS client fingerprint) is [BSD-3-Clause][JA4 license] licensed.
Other methods of the JA4+ family, and FoxIO's nginx module, are published
under the more restrictive [FoxIO License]; check its current terms before
using any of them. Limen only consumes JA4.

[JA4]: https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md
[ClientHello]: https://www.rfc-editor.org/rfc/rfc8446#section-4.1.2
[ALPN]: https://www.rfc-editor.org/rfc/rfc7301
[ja4-nginx-module]: https://github.com/FoxIO-LLC/ja4-nginx-module
[X-Forwarded-For]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For
[JA4 license]: https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE-JA4
[FoxIO License]: https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE
