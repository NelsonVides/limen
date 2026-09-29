defmodule Limen.Challenge do
  @moduledoc """
  The proof-of-work challenge, modelled on the [Anubis] proxy.

  When a policy decides `:challenge`, a browser navigating to the page gets a
  small interstitial instead. A script on it (served by Limen, no third-party
  assets, compatible with a strict [Content-Security-Policy][CSP]) searches, in Web
  Workers, for a nonce such that `SHA-256(token <> nonce)` starts with the
  requested number of zero bits, and posts it back. Each extra bit doubles
  the expected work; the default 16 bits take a fraction of a second on a
  phone, and cost a scraper the same for every client identity it uses.

  Everything is stateless on the server:

    * the challenge token (`Limen.Challenge.Token`) is [HMAC]-signed and bound
      to the client's prefix, JA4 fingerprint and user agent, with an expiry,
      the difficulty and a random salt;
    * verification checks the signature, the expiry, the binding and the
      leading zero bits: one HMAC and one SHA-256;
    * solved tokens go into a rotating Bloom filter (`Limen.Challenge.Replay`)
      so each can be used once;
    * success sets a pass cookie (`Limen.Challenge.Pass`), again HMAC-signed
      and bound to the same identity, which `Limen.Plug` verifies on the fast
      path without collecting any other signal.

  A pass stops working when the client's prefix, JA4 or user agent change,
  for example when a phone moves between networks; the client then solves a
  new challenge.

  ## Clients without JavaScript

  With `no_js: {:meta_refresh, seconds}` (the default), the page includes a
  `<noscript>` [meta refresh] to a wait endpoint that accepts the token once the
  given number of seconds have passed since it was issued. That costs
  automated clients time instead of CPU, and keeps the site usable with
  JavaScript disabled, including for some assistive technologies. With
  `no_js: :deny`, such clients are asked to enable JavaScript. To let
  specific clients through without any challenge, allow-list them in the
  policy (`Limen.Policy.Default` allows `list(:allow)`).

  ## Endpoints

  Limen serves, under the `:path` of the `:challenge` configuration
  (`/__limen` by default): `solver.js`, `worker.js` and `challenge.css`,
  `POST verify` for solutions and `GET wait` for the no-JavaScript path.

  [Anubis]: https://anubis.techaro.lol/
  [CSP]: https://www.w3.org/TR/CSP3/
  [HMAC]: https://www.rfc-editor.org/rfc/rfc2104
  [meta refresh]: https://html.spec.whatwg.org/multipage/semantics.html#attr-meta-http-equiv-refresh
  """

  use Limen.Boundary,
    type: :strict,
    deps:
      [Limen.Config, Limen.Context, Limen.HMAC, Limen.Instance, Limen.IP, Limen.Sketch] ++
        [EEx, Plug, Plug.Crypto],
    exports: [Assets, Page, Pass, Replay, Token]

  alias Limen.{Context, IP}

  @doc """
  The identity a token or pass is bound to, as the iodata its MAC covers.
  """
  @spec binding(Context.t()) :: iolist()
  def binding(%Context{prefix: prefix, ja4: ja4, user_agent: user_agent}) do
    [IP.prefix_to_binary(prefix), 0, ja4 || "", 0, user_agent || ""]
  end

  @doc false
  @spec mac(Limen.HMAC.key(), iodata()) :: binary()
  def mac(key, data), do: binary_part(Limen.HMAC.sha256(key, data), 0, 16)

  @doc false
  @spec keys(Limen.Instance.t(), :challenge | :pass | :socket) :: [Limen.HMAC.key(), ...]
  def keys(%Limen.Instance{config: %{keys: keys}}, purpose), do: Map.fetch!(keys, purpose)

  @doc """
  Validates a redirect target: a local path, never another origin.

      iex> Limen.Challenge.safe_return_to("/articles?page=2")
      "/articles?page=2"
      iex> Limen.Challenge.safe_return_to("//evil.example/")
      "/"
      iex> Limen.Challenge.safe_return_to("https://evil.example/")
      "/"
  """
  @spec safe_return_to(term()) :: String.t()
  def safe_return_to("/" <> rest = path) when byte_size(path) <= 2_048 do
    # Browsers treat a backslash like a slash, so "/\\host" is another origin.
    if String.starts_with?(rest, "/") or String.contains?(path, ["\\", "\r", "\n"]),
      do: "/",
      else: path
  end

  def safe_return_to(_other), do: "/"

  @doc """
  The path and query of the current request, as a redirect target.
  """
  @spec return_to(Plug.Conn.t()) :: String.t()
  def return_to(%Plug.Conn{request_path: path, query_string: ""}), do: safe_return_to(path)

  def return_to(%Plug.Conn{request_path: path, query_string: query}),
    do: safe_return_to(path <> "?" <> query)

  @doc """
  Whether a request is a navigation that can render the challenge page.
  """
  @spec navigation?(Plug.Conn.t()) :: boolean()
  def navigation?(%Plug.Conn{method: method} = conn) when method in ["GET", "HEAD"] do
    case Plug.Conn.get_req_header(conn, "accept") do
      [] -> true
      [accept | _rest] -> String.contains?(accept, ["text/html", "*/*"])
    end
  end

  def navigation?(_conn), do: false
end
